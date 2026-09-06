'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { encodeMux, MAX_MUX_FRAME_BYTES } = require('../src/mux')
const { Worklet } = require('../src/worklet')

test('oversized mux frame before identity drops only that peer', async () => {
  const a = new Worklet({ backend: 'loopback' })
  const b = new Worklet({ backend: 'loopback' })
  const c = new Worklet({ backend: 'loopback' })
  const secret = Buffer.alloc(32, 5)
  await a.start({ peerId: 'A', discoverySecret: secret })
  await b.start({ peerId: 'B', discoverySecret: secret })
  await c.start({ peerId: 'C', discoverySecret: secret })
  await a.connect({ port: b._loop.port })
  await c.connect({ port: b._loop.port })
  for (const id of c._peers.keys()) await c.authorize(id)
  for (const id of b._peers.keys()) {
    if (String(id).includes('C') || b._peers.get(id).logicalPeerId === 'C') {
      await b.authorize(id)
    }
  }
  const attacker = Array.from(b._peers.values()).find((p) => p.logicalPeerId === 'A' || p.alias)
  const header = Buffer.alloc(7)
  header.writeUInt8(1, 0)
  header.writeUInt8(1, 1)
  header.writeUInt32BE(0xffffffff, 3)
  attacker.socket.write(header)
  await new Promise((r) => setTimeout(r, 40))
  assert.equal(attacker.closed, true)
  assert.equal(b._started, true)
  const cPeer = Array.from(c._peers.keys())[0]
  const got = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('survivor timeout')), 2000)
    const prev = c._emit
    c._emit = (name, payload) => {
      prev(name, payload)
      if (name === 'frame' && payload.body && payload.body.type === 'harness-echo-reply') {
        clearTimeout(timer)
        resolve(payload.body.text)
      }
    }
  })
  // C may not be fully authorized against B depending on alias. Authorize remaining.
  for (const id of b._peers.keys()) {
    const rec = b._peers.get(id)
    if (rec && !rec.closed && rec.authState !== 'authenticated') {
      try { await b.authorize(id) } catch {}
    }
  }
  if (c._peers.get(cPeer) && c._peers.get(cPeer).authState !== 'authenticated') {
    await c.authorize(cPeer)
  }
  await c.send(cPeer, 'message', { type: 'harness-echo', id: 's', text: 'still-here' })
  assert.equal(await got, 'still-here')
  await a.stop()
  await b.stop()
  await c.stop()
})

test('frame exactly at mux limit after authorize is accepted', async () => {
  const a = new Worklet({ backend: 'loopback' })
  const b = new Worklet({ backend: 'loopback' })
  await a.start({ peerId: 'A', discoverySecret: Buffer.alloc(32, 1) })
  await b.start({ peerId: 'B', discoverySecret: Buffer.alloc(32, 1) })
  await a.connect({ port: b._loop.port })
  for (const w of [a, b]) {
    for (const id of w._peers.keys()) await w.authorize(id)
  }
  const body = { type: 'wireHello', pad: 'x'.repeat(1024) }
  const peerId = Array.from(a._peers.keys())[0]
  const framed = encodeMux('control', Buffer.from(JSON.stringify(body)))
  assert.ok(framed.length - 7 < MAX_MUX_FRAME_BYTES)
  await a.send(peerId, 'control', body)
  await new Promise((r) => setTimeout(r, 30))
  assert.equal(b._started, true)
  await a.stop()
  await b.stop()
})

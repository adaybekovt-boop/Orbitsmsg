'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { encodeMux } = require('../src/mux')
const { Worklet } = require('../src/worklet')

async function startPair(opts = {}) {
  const a = new Worklet({ backend: 'loopback', allowHarnessFiles: opts.allowHarnessFiles })
  const b = new Worklet({ backend: 'loopback', allowHarnessFiles: opts.allowHarnessFiles })
  const secret = Buffer.alloc(32, 4)
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-auth-'))
  await a.start({ peerId: 'ALICE', discoverySecret: secret, storageDir: path.join(base, 'a') })
  await b.start({ peerId: 'BOB', discoverySecret: secret, storageDir: path.join(base, 'b') })
  await a.connect({ port: b._loop.port })
  return { a, b, base }
}

test('application frames before authorize close the attacker only', async () => {
  const { a, b } = await startPair()
  const events = []
  const prev = b._emit
  b._emit = (name, payload) => {
    events.push(name)
    prev(name, payload)
  }
  const victim = Array.from(b._peers.values())[0]
  victim.socket.write(encodeMux('message', Buffer.from(JSON.stringify({
    type: 'harness-echo',
    id: 'x',
    text: 'nope',
  }))))
  await new Promise((r) => setTimeout(r, 50))
  assert.ok(!events.includes('connected'))
  assert.ok(!events.includes('frame'))
  assert.equal(victim.closed, true)
  assert.equal(a._started, true)
  assert.equal(b._started, true)
  await a.stop()
  await b.stop()
})

test('unknown pre-auth frame type closes the connection', async () => {
  const { a, b } = await startPair()
  const victim = Array.from(b._peers.values())[0]
  victim.socket.write(encodeMux('call', Buffer.from(JSON.stringify({ type: 'offer' }))))
  await new Promise((r) => setTimeout(r, 50))
  assert.equal(victim.closed, true)
  await a.stop()
  await b.stop()
})

test('file offer before authorize does not create incoming files', async () => {
  const { a, b, base } = await startPair({ allowHarnessFiles: true })
  const incoming = path.join(base, 'b', 'orbits-incoming')
  const victim = Array.from(b._peers.values())[0]
  victim.socket.write(encodeMux('attachment', Buffer.from(JSON.stringify({
    type: 'harness-file-start',
    id: 'safeid',
    name: 'x.bin',
    size: 4,
  }))))
  await new Promise((r) => setTimeout(r, 50))
  assert.equal(fs.existsSync(incoming), false)
  assert.equal(victim.closed, true)
  await a.stop()
  await b.stop()
})

test('authorize enables echo and connected', async () => {
  const { a, b } = await startPair()
  const peerId = Array.from(a._peers.keys())[0]
  for (const id of a._peers.keys()) await a.authorize(id)
  for (const id of b._peers.keys()) await b.authorize(id)
  assert.ok(a.events.some((e) => e.name === 'connected'))
  assert.ok(b.events.some((e) => e.name === 'connected'))
  const got = new Promise((resolve) => {
    const prev = a._emit
    a._emit = (name, payload) => {
      prev(name, payload)
      if (name === 'frame' && payload.body && payload.body.type === 'harness-echo-reply') {
        resolve(payload.body.text)
      }
    }
  })
  await a.send(peerId, 'message', { type: 'harness-echo', id: '1', text: 'ok' })
  assert.equal(await got, 'ok')
  await a.stop()
  await b.stop()
})

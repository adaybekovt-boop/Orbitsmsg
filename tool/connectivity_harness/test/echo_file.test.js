'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { Worklet } = require('../src/worklet')

async function pair() {
  const a = new Worklet({ backend: 'loopback' })
  const b = new Worklet({ backend: 'loopback' })
  const secret = Buffer.alloc(32, 9)
  await a.start({ peerId: 'A', discoverySecret: secret })
  await b.start({ peerId: 'B', discoverySecret: secret })
  await a.publish({ deviceId: 'a' })
  await b.publish({ deviceId: 'b' })
  await a.connect({ port: b._loop.port })
  const peerId = Array.from(a._peers.keys())[0]
  return { a, b, peerId }
}

test('text echo over loopback', async () => {
  const { a, b, peerId } = await pair()
  const got = new Promise((resolve) => {
    const prev = a._emit
    a._emit = (name, payload) => {
      prev(name, payload)
      if (name === 'frame' && payload.body && payload.body.type === 'harness-echo-reply') {
        resolve(payload.body.text)
      }
    }
  })
  await a.send(peerId, 'message', { type: 'harness-echo', id: '1', text: 'ping' })
  assert.equal(await got, 'ping')
  await a.stop()
  await b.stop()
})

test('opaque wire-v4 frame is not interpreted', async () => {
  const { a, b, peerId } = await pair()
  const got = new Promise((resolve) => {
    const prev = b._emit
    b._emit = (name, payload) => {
      prev(name, payload)
      if (name === 'frame' && payload.channel === 'control') resolve(payload.body)
    }
  })
  await a.send(peerId, 'control', { type: 'wireHello', v: 4, pub: 'x', idPub: 'y', sig: 'z' })
  const body = await got
  assert.equal(body.v, 4)
  assert.equal(body.type, 'wireHello')
  await a.stop()
  await b.stop()
})

test('file stream from a path', async () => {
  const { a, b, peerId } = await pair()
  const src = path.join(os.tmpdir(), 'orbits-harness-file.bin')
  fs.writeFileSync(src, Buffer.alloc(20 * 1024, 7))
  const chunks = []
  const prev = b._emit
  const done = new Promise((resolve) => {
    b._emit = (name, payload) => {
      prev(name, payload)
      if (name === 'frame' && payload.channel === 'attachment') {
        chunks.push(payload.body)
        if (payload.body.type === 'harness-file-end') resolve()
      }
    }
  })
  await a.sendFile(peerId, { path: src, fileName: 'orbits-harness-file.bin' })
  await done
  assert.ok(chunks.some((c) => c.type === 'harness-file-start'))
  assert.ok(chunks.some((c) => c.type === 'harness-file-chunk'))
  await a.stop()
  await b.stop()
})

test('suspend blocks send', async () => {
  const { a, b, peerId } = await pair()
  await a.suspend()
  await assert.rejects(() => a.send(peerId, 'message', { type: 'harness-echo', id: 'n', text: 'x' }))
  await a.resume()
  await a.send(peerId, 'message', { type: 'harness-echo', id: 'y', text: 'ok' })
  await a.stop()
  await b.stop()
})

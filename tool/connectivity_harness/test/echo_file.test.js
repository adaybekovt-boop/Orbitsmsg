'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { createHash } = require('node:crypto')
const { Worklet, hashPath, FILE_CHUNK } = require('../src/worklet')

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
  const start = chunks.find((c) => c.type === 'harness-file-start')
  assert.ok(start)
  assert.ok(chunks.some((c) => c.type === 'harness-file-chunk'))
  const expected = hashPath(src)
  assert.equal(start.sha256, expected.digest)
  assert.equal(start.size, expected.size)
  const hashed = createHash('sha256').update(fs.readFileSync(src)).digest('hex')
  assert.equal(expected.digest, hashed)
  await a.stop()
  await b.stop()
})

test('sendFile rejects bytes and streams from a resume offset', async () => {
  const { a, b, peerId } = await pair()
  await assert.rejects(
    () => a.sendFile(peerId, { path: '/tmp/x', bytes: Buffer.from('no') }),
    /path, not bytes/,
  )
  await assert.rejects(() => a.sendFile(peerId, {}), /needs a path/)

  const src = path.join(os.tmpdir(), 'orbits-harness-resume.bin')
  fs.writeFileSync(src, Buffer.alloc(FILE_CHUNK + 1024, 9))
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
  await a.sendFile(peerId, { path: src, resumeOffset: FILE_CHUNK })
  await done
  const start = chunks.find((c) => c.type === 'harness-file-start')
  assert.ok(start)
  assert.equal(start.size, FILE_CHUNK + 1024)
  const piece = chunks.find((c) => c.type === 'harness-file-chunk')
  assert.equal(piece.offset, FILE_CHUNK)
  assert.ok(!chunks.some((c) => c.type === 'harness-file-chunk' && c.offset === 0))
  await a.stop()
  await b.stop()
})

test('sendFile interrupt then resume writes a complete hashed file', async () => {
  const { a, b, peerId } = await pair()
  const src = path.join(os.tmpdir(), 'orbits-harness-survive.bin')
  const payload = Buffer.alloc(FILE_CHUNK + 4096, 11)
  fs.writeFileSync(src, payload)
  const expected = hashPath(src)
  a.fileSendBudget = FILE_CHUNK
  await assert.rejects(
    () => a.sendFile(peerId, { path: src, fileName: 'survive.bin' }),
    /file-send interrupted/,
  )
  a.fileSendBudget = null
  const done = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('no harness-file-received')), 5000)
    const prev = b._emit
    b._emit = (name, payload) => {
      prev(name, payload)
      if (name === 'frame' && payload.body && payload.body.type === 'harness-file-received') {
        clearTimeout(timer)
        resolve(payload.body)
      }
    }
  })
  await a.sendFile(peerId, { path: src, fileName: 'survive.bin' })
  const received = await done
  assert.equal(received.sha256, expected.digest)
  assert.equal(received.size, expected.size)
  const onDisk = fs.readFileSync(received.path)
  assert.equal(onDisk.equals(payload), true)
  await a.stop()
  await b.stop()
})

test('sendFile attach-chunk streams ciphertext from a path', async () => {
  const { a, b, peerId } = await pair()
  const src = path.join(os.tmpdir(), 'orbits-attach-chunk.bin')
  const ct = Buffer.alloc(FILE_CHUNK + 100, 5)
  fs.writeFileSync(src, ct)
  const frames = []
  const prev = b._emit
  const done = new Promise((resolve) => {
    b._emit = (name, payload) => {
      prev(name, payload)
      if (name === 'frame' && payload.channel === 'attachment') {
        frames.push(payload.body)
        if (payload.body && payload.body.type === 'attach-chunk-path') resolve()
      }
    }
  })
  await a.sendFile(peerId, { path: src, protocol: 'attach-chunk', fileId: 'chat-1' })
  await done
  assert.ok(!frames.some((c) => c && c.type === 'harness-file-start'))
  assert.ok(!frames.some((c) => c && c.b64))
  assert.ok(!frames.some((c) => c && c.type === 'attach-chunk'))
  const pathFrame = frames.find((c) => c && c.type === 'attach-chunk-path')
  assert.ok(pathFrame)
  assert.equal(pathFrame.fileId, 'chat-1')
  assert.ok(pathFrame.path)
  assert.ok(!String(pathFrame.path).includes('://'))
  const deadline = Date.now() + 2000
  while (Date.now() < deadline) {
    if (fs.existsSync(pathFrame.path) && fs.statSync(pathFrame.path).size === ct.length) break
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  const onDisk = fs.readFileSync(pathFrame.path)
  assert.equal(onDisk.equals(ct), true)
  await a.stop()
  await b.stop()
})

test('sendFile attach-chunk rejects fileKey, bytes, remote paths, and missing fileId', async () => {
  const { a, b, peerId } = await pair()
  const src = path.join(os.tmpdir(), 'orbits-attach-chunk-reject.bin')
  fs.writeFileSync(src, Buffer.alloc(32, 3))
  await assert.rejects(
    () => a.sendFile(peerId, { path: src, bytes: Buffer.from('no') }),
    /path, not bytes/,
  )
  await assert.rejects(
    () => a.sendFile(peerId, { path: src, protocol: 'attach-chunk', fileId: 'x', fileKey: 'nope' }),
    /fileKey/,
  )
  await assert.rejects(
    () => a.sendFile(peerId, { path: 'https://evil.example/x', protocol: 'attach-chunk', fileId: 'x' }),
    /remote path/,
  )
  await assert.rejects(
    () => a.sendFile(peerId, { path: src, protocol: 'attach-chunk' }),
    /fileId/,
  )
  await a.stop()
  await b.stop()
})

test('inbound attach-chunk drops nested fileKey and does not write cipher', async () => {
  const { a, b, peerId } = await pair()
  const attCtPrefix = 'orbits-att-ct-'
  const before = new Set(fs.readdirSync(os.tmpdir()).filter((n) => n.startsWith(attCtPrefix)))
  const frames = []
  const prev = b._emit
  const echoed = new Promise((resolve) => {
    b._emit = (name, payload) => {
      prev(name, payload)
      if (name === 'frame' && payload.channel === 'attachment') {
        frames.push(payload.body)
      }
      if (name === 'frame' && payload.body && payload.body.type === 'harness-echo') {
        resolve()
      }
    }
  })
  await a.send(peerId, 'attachment', {
    type: 'attach-chunk',
    fileId: 'chat-nested',
    offset: 0,
    b64: Buffer.from('nested-cipher').toString('base64'),
    meta: { fileKey: 'nope' },
  })
  // Same socket is ordered: echo after the chunk means ingest already ran.
  await a.send(peerId, 'message', { type: 'harness-echo', id: 'after-nested', text: 'after' })
  await echoed
  assert.ok(!frames.some((c) => c && c.type === 'attach-chunk-path'))
  assert.ok(!frames.some((c) => c && c.type === 'attach-chunk'))
  assert.equal(b._attachFiles.size, 0)
  const after = fs.readdirSync(os.tmpdir()).filter((n) => n.startsWith(attCtPrefix))
  assert.ok(after.every((n) => before.has(n)))
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

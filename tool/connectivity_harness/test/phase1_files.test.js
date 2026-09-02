'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { Worklet, hashPath, FILE_CHUNK, MAX_FILE_BYTES } = require('../src/worklet')

function waitEmit(worklet, name, pred, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(name + ' timeout')), timeoutMs || 20000)
    const prev = worklet._emit
    worklet._emit = (ev, payload) => {
      prev(ev, payload)
      if (ev === name && (!pred || pred(payload))) {
        clearTimeout(timer)
        worklet._emit = prev
        resolve(payload)
      }
    }
  })
}

async function pair() {
  const a = new Worklet({ backend: 'loopback' })
  const b = new Worklet({ backend: 'loopback' })
  const secret = Buffer.alloc(32, 11)
  await a.start({ peerId: 'A', discoverySecret: secret })
  await b.start({ peerId: 'B', discoverySecret: secret })
  await a.publish({ deviceId: 'a' })
  await b.publish({ deviceId: 'b' })
  await a.connect({ port: b._loop.port })
  const peerId = Array.from(a._peers.keys())[0]
  const bPeer = Array.from(b._peers.keys())[0]
  a.markAuthenticated(peerId)
  if (bPeer) b.markAuthenticated(bPeer)
  return { a, b, peerId }
}

function writePatternFile(filePath, megabytes) {
  const fd = fs.openSync(filePath, 'w')
  try {
    const chunk = Buffer.alloc(1024 * 1024)
    for (let i = 0; i < megabytes; i++) {
      chunk.fill((i + 1) & 0xff)
      fs.writeSync(fd, chunk)
    }
  } finally {
    fs.closeSync(fd)
  }
}

test('10 MiB file transfer matches sha256', { timeout: 60000 }, async () => {
  const { a, b, peerId } = await pair()
  const src = path.join(os.tmpdir(), 'orbits-harness-10m.bin')
  writePatternFile(src, 10)
  const expected = hashPath(src)
  assert.equal(expected.size, 10 * 1024 * 1024)
  const done = waitEmit(
    b,
    'frame',
    (p) => p.body && p.body.type === 'harness-file-received',
  )
  await a.sendFile(peerId, { path: src, fileName: 'ten.bin' })
  const received = (await done).body
  assert.equal(received.sha256, expected.digest)
  assert.equal(received.size, expected.size)
  assert.equal(hashPath(received.path).digest, expected.digest)
  await a.stop()
  await b.stop()
})

test('interrupted transfer + reconnect resumes from confirmed offset', { timeout: 30000 }, async () => {
  const { a, b, peerId } = await pair()
  const src = path.join(os.tmpdir(), 'orbits-harness-kill-resume.bin')
  const payload = Buffer.alloc(FILE_CHUNK * 3 + 2048, 19)
  fs.writeFileSync(src, payload)
  const expected = hashPath(src)
  let chunks = 0
  const prev = b._emit
  b._emit = (name, body) => {
    prev(name, body)
    if (name === 'frame' && body && body.body && body.body.type === 'harness-file-chunk') {
      chunks += 1
      if (chunks === 1) {
        const peer = a._peers.get(peerId)
        if (peer && peer.socket) peer.socket.destroy()
      }
    }
  }
  await assert.rejects(() => a.sendFile(peerId, { path: src, fileName: 'kill.bin' }))
  const deadline = Date.now() + 2000
  while (Date.now() < deadline && a._peers.size > 0) {
    await new Promise((r) => setTimeout(r, 10))
  }
  assert.ok(b._files.size >= 1, 'receiver kept partial file across disconnect')
  const incoming = Array.from(b._files.values())[0]
  const confirmed = incoming.ranges && incoming.ranges.length ? incoming.ranges[0][1] : 0
  assert.ok(confirmed > 0, 'receiver confirmed a contiguous offset')
  const bJoined = waitEmit(b, 'connected')
  await a.connect({ port: b._loop.port })
  const bPeer2 = (await bJoined).peerId
  const peerId2 = Array.from(a._peers.keys())[0]
  a.markAuthenticated(peerId2)
  if (bPeer2) b.markAuthenticated(bPeer2)
  const done = waitEmit(
    b,
    'frame',
    (p) => p.body && p.body.type === 'harness-file-received',
  )
  await a.sendFile(peerId2, { path: src, fileName: 'kill.bin' })
  const received = (await done).body
  assert.equal(received.sha256, expected.digest)
  assert.equal(received.size, expected.size)
  assert.equal(fs.readFileSync(received.path).equals(payload), true)
  await a.stop()
  await b.stop()
})

test('receiver cancellation removes the partial file', { timeout: 15000 }, async () => {
  const { a, b, peerId } = await pair()
  const src = path.join(os.tmpdir(), 'orbits-harness-rx-cancel.bin')
  fs.writeFileSync(src, Buffer.alloc(FILE_CHUNK * 4, 21))
  const prev = b._emit
  b._emit = (name, payload) => {
    prev(name, payload)
    if (name === 'frame' && payload && payload.body && payload.body.type === 'harness-file-start') {
      b.cancelFile('rx-cancel-1').catch(() => {})
    }
  }
  const sendP = a.sendFile(peerId, { path: src, id: 'rx-cancel-1', fileName: 'c.bin' })
  await assert.rejects(sendP, (err) => {
    return Boolean(
      err &&
        (err.code === 'file-cancelled' ||
          err.code === 'socket-closed' ||
          /file-cancelled|socket-closed|not connected/.test(String(err.message))),
    )
  })
  assert.equal(b._files.has('rx-cancel-1'), false)
  await a.stop()
  await b.stop()
})

test('sender cancellation stops chunking', { timeout: 15000 }, async () => {
  const { a, b, peerId } = await pair()
  const src = path.join(os.tmpdir(), 'orbits-harness-tx-cancel.bin')
  fs.writeFileSync(src, Buffer.alloc(FILE_CHUNK * 4, 22))
  const started = waitEmit(b, 'frame', (p) => p.body && p.body.type === 'harness-file-start')
  const ac = new AbortController()
  const sendP = a.sendFile(peerId, {
    path: src,
    id: 'tx-cancel-1',
    fileName: 't.bin',
    signal: ac.signal,
  })
  await started
  ac.abort()
  await assert.rejects(sendP, (err) => err && err.code === 'file-cancelled')
  assert.equal(a._outgoingFiles.has('tx-cancel-1'), false)
  await a.stop()
  await b.stop()
})

test('sendFile rejects files above MAX_FILE_BYTES', async () => {
  const { a, b, peerId } = await pair()
  const orig = fs.statSync
  fs.statSync = function statStub(p, opts) {
    if (String(p).includes('orbits-harness-oversize')) return { size: MAX_FILE_BYTES + 1 }
    return orig.call(fs, p, opts)
  }
  const src = path.join(os.tmpdir(), 'orbits-harness-oversize.bin')
  fs.writeFileSync(src, Buffer.alloc(32, 3))
  try {
    await assert.rejects(
      () => a.sendFile(peerId, { path: src, protocol: 'attach-chunk', fileId: 'big' }),
      (err) => err && err.code === 'file-too-large',
    )
  } finally {
    fs.statSync = orig
  }
  await a.stop()
  await b.stop()
})

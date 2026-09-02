'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { Worklet, handleIpcRequest, OUTBOUND_QUEUE_CAP } = require('../src/worklet')
const { encodeMux, MuxDecoder, FrameError, MAX_MUX_FRAME_BYTES } = require('../src/mux')
const { Decoder, IpcFrameError, encode, REQUEST } = require('../src/ipc')

function waitEmit(worklet, name, pred, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(name + ' timeout')), timeoutMs || 5000)
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

async function pair(opts) {
  const auth = (opts && opts.harnessAuth) || 'local'
  const a = new Worklet({ backend: 'loopback', harnessAuth: auth })
  const b = new Worklet({ backend: 'loopback', harnessAuth: auth })
  const secret = Buffer.alloc(32, 9)
  await a.start({ peerId: 'A', discoverySecret: secret })
  await b.start({ peerId: 'B', discoverySecret: secret })
  await a.publish({ deviceId: 'a' })
  await b.publish({ deviceId: 'b' })
  await a.connect({ port: b._loop.port })
  const peerId = Array.from(a._peers.keys())[0]
  return { a, b, peerId }
}

test('local loopback connect and diagnostics lifecycle', async () => {
  const { a, b, peerId } = await pair()
  assert.ok(peerId)
  assert.equal(a._peers.size >= 1, true)
  const d = a.diagnostics()
  assert.equal(d.lifecycle, 'started')
  assert.equal(d.backend, 'loopback')
  assert.equal(d.transport, 'loopback')
  assert.ok(d.peers[peerId])
  assert.equal(d.peers[peerId].authenticated, true)
  assert.equal(typeof d.peers[peerId].bytesSent, 'number')
  assert.equal(typeof d.droppedPreAuth, 'number')
  assert.ok(Array.isArray(d.activeFileTransfers))
  const viaIpc = await handleIpcRequest(a, { method: 'diagnostics', params: {} })
  assert.equal(viaIpc.lifecycle, 'started')
  await a.stop()
  await b.stop()
  assert.equal(a.diagnostics().lifecycle, 'stopped')
})

test('echo control message over loopback', async () => {
  const { a, b, peerId } = await pair()
  const got = waitEmit(
    a,
    'frame',
    (p) => p.body && p.body.type === 'harness-echo-reply',
  )
  await a.send(peerId, 'message', { type: 'harness-echo', id: 'c', text: 'control-echo' })
  assert.equal((await got).body.text, 'control-echo')
  await a.stop()
  await b.stop()
})

test('binary payload round trip', async () => {
  const { a, b, peerId } = await pair()
  const bin = Buffer.from([0, 1, 2, 255, 0, 10, 127])
  const got = waitEmit(b, 'frame', (p) => p.channel === 'message' && !p.body && p.frameB64)
  await a.send(peerId, 'message', bin)
  const frame = await got
  assert.equal(Buffer.from(frame.frameB64, 'base64').equals(bin), true)
  await a.stop()
  await b.stop()
})

test('empty payload round trip', async () => {
  const { a, b, peerId } = await pair()
  const got = waitEmit(b, 'frame', (p) => p.channel === 'message' && p.frameB64 === '')
  await a.send(peerId, 'message', Buffer.alloc(0))
  const frame = await got
  assert.equal(frame.frameB64, '')
  await a.stop()
  await b.stop()
})

test('malformed frame drops the peer', async () => {
  const { a, b, peerId } = await pair()
  const bPeerId = Array.from(b._peers.keys())[0]
  const dropped = waitEmit(b, 'disconnected', (p) => p.reason === 'malformed-frame')
  const bad = Buffer.alloc(7)
  bad.writeUInt8(99, 0)
  bad.writeUInt8(0, 1)
  bad.writeUInt32BE(0, 3)
  a._peers.get(peerId).socket.write(bad)
  const ev = await dropped
  assert.equal(ev.reason, 'malformed-frame')
  assert.equal(b._peers.has(bPeerId), false)
  await a.stop()
  await b.stop()
})

test('oversized frame drops the peer', async () => {
  const { a, b, peerId } = await pair()
  const dropped = waitEmit(b, 'disconnected', (p) => p.reason === 'oversized-frame')
  const header = Buffer.alloc(7)
  header.writeUInt8(1, 0)
  header.writeUInt8(1, 1)
  header.writeUInt8(0, 2)
  header.writeUInt32BE(MAX_MUX_FRAME_BYTES + 1, 3)
  a._peers.get(peerId).socket.write(header)
  const ev = await dropped
  assert.equal(ev.reason, 'oversized-frame')
  assert.ok(b.diagnostics().oversizedFrames >= 1)
  await a.stop()
  await b.stop()
})

test('MuxDecoder throws typed errors (behavioral feed, not a source scan)', () => {
  const dec = new MuxDecoder()
  const ok = encodeMux('message', Buffer.from('hi'))
  const frames = dec.add(ok)
  assert.equal(frames.length, 1)
  assert.equal(frames[0].payload.toString(), 'hi')
  assert.throws(
    () => new MuxDecoder().add(Buffer.from([2, 0, 0, 0, 0, 0, 0])),
    (err) => err instanceof FrameError && err.code === 'malformed-frame',
  )
  const huge = Buffer.alloc(7)
  huge.writeUInt8(1, 0)
  huge.writeUInt8(1, 1)
  huge.writeUInt32BE(MAX_MUX_FRAME_BYTES + 50, 3)
  assert.throws(
    () => new MuxDecoder().add(huge),
    (err) => err instanceof FrameError && err.code === 'oversized-frame',
  )
})

test('IPC Decoder throws typed errors on bad magic', () => {
  const dec = new Decoder()
  const good = encode(REQUEST, { id: 1, method: 'diagnostics' })
  assert.equal(dec.add(good).length, 1)
  const bad = Buffer.from(good)
  bad.writeUInt32BE(0x11111111, 0)
  assert.throws(
    () => new Decoder().add(bad),
    (err) => err instanceof IpcFrameError && err.code === 'malformed-frame',
  )
})

test('disconnect during handshake then no leftover peer', async () => {
  const a = new Worklet({ backend: 'loopback', harnessAuth: 'strict' })
  const b = new Worklet({ backend: 'loopback', harnessAuth: 'strict' })
  const secret = Buffer.alloc(32, 5)
  await a.start({ peerId: 'A', discoverySecret: secret })
  await b.start({ peerId: 'B', discoverySecret: secret })
  await a.publish({ deviceId: 'a' })
  await b.publish({ deviceId: 'b' })
  const dropped = waitEmit(a, 'disconnected')
  await a.connect({ port: b._loop.port })
  const peerId = Array.from(a._peers.keys())[0]
  assert.equal(a._peers.get(peerId).authenticated, false)
  a._peers.get(peerId).socket.destroy()
  await dropped
  assert.equal(a._peers.has(peerId), false)
  await a.stop()
  await b.stop()
})

test('reconnect after disconnect and echo still works', async () => {
  const { a, b, peerId } = await pair()
  await a.disconnect(peerId)
  assert.equal(a._peers.size, 0)
  await a.connect({ port: b._loop.port })
  const peerId2 = Array.from(a._peers.keys())[0]
  assert.ok(peerId2)
  const got = waitEmit(a, 'frame', (p) => p.body && p.body.type === 'harness-echo-reply')
  await a.send(peerId2, 'message', { type: 'harness-echo', id: 're', text: 'again' })
  assert.equal((await got).body.text, 'again')
  const d = a.diagnostics()
  const hist = d.peers[peerId2]
  assert.ok(hist)
  await a.stop()
  await b.stop()
})

test('connection timeout rejects with connect-timeout', async () => {
  const a = new Worklet({ backend: 'loopback' })
  await a.start({ peerId: 'A', discoverySecret: Buffer.alloc(32, 1) })
  a._loop.connect = () => new Promise(() => {})
  await assert.rejects(
    () => a.connect({ port: 9, timeoutMs: 80 }),
    (err) => err && err.code === 'connect-timeout',
  )
  await a.stop()
})

test('pre-auth application frame is dropped and counted', async () => {
  const { a, b, peerId } = await pair({ harnessAuth: 'strict' })
  const bPeerId = Array.from(b._peers.keys())[0]
  assert.equal(b._peers.get(bPeerId).authenticated, false)
  await a.send(peerId, 'message', { type: 'harness-echo', id: 'nope', text: 'secret' })
  const deadline = Date.now() + 500
  while (Date.now() < deadline && b.diagnostics().droppedPreAuth < 1) {
    await new Promise((r) => setTimeout(r, 10))
  }
  assert.ok(b.diagnostics().droppedPreAuth >= 1)
  assert.ok(
    !b.events.some((e) => e.name === 'frame' && e.payload && e.payload.body && e.payload.body.type === 'harness-echo'),
  )
  const binding = waitEmit(b, 'frame', (p) => p.body && p.body.type === 'device-binding')
  await a.send(peerId, 'control', { type: 'device-binding', nonce: 'n1' })
  assert.equal((await binding).body.nonce, 'n1')
  await handleIpcRequest(b, { method: 'markAuthenticated', params: { peerId: bPeerId } })
  await handleIpcRequest(a, { method: 'markAuthenticated', params: { peerId } })
  assert.equal(b._peers.get(bPeerId).authenticated, true)
  const echo = waitEmit(a, 'frame', (p) => p.body && p.body.type === 'harness-echo-reply')
  await a.send(peerId, 'message', { type: 'harness-echo', id: 'ok', text: 'after-auth' })
  assert.equal((await echo).body.text, 'after-auth')
  await a.stop()
  await b.stop()
})

test('outbound queue cap rejects without exceeding byte cap', async () => {
  const { a, b, peerId } = await pair()
  const rssBefore = process.memoryUsage().rss
  const piece = Math.min(MAX_MUX_FRAME_BYTES - 64, 900 * 1024)
  const peer = a._peers.get(peerId)
  peer.flushing = true
  const queued = []
  const errors = []
  for (let i = 0; i < 8; i++) {
    const p = a.send(peerId, 'message', Buffer.alloc(piece, 7))
    queued.push(p)
    p.catch((err) => errors.push(err))
  }
  await new Promise((resolve) => setImmediate(resolve))
  assert.ok(
    errors.some((err) => err && err.code === 'outbound-queue-full'),
    'expected outbound-queue-full while the socket cannot drain; got ' +
      errors.map((e) => e && e.code).join(','),
  )
  assert.ok(peer.maxOutBytes <= a._outboundQueueCap)
  assert.ok(peer.outBytes <= a._outboundQueueCap)
  assert.equal(a._outboundQueueCap, OUTBOUND_QUEUE_CAP)
  peer.flushing = false
  a._flushOut(peer)
  await Promise.allSettled(queued)
  const rssAfter = process.memoryUsage().rss
  assert.ok(rssAfter - rssBefore < 80 * 1024 * 1024)
  await a.stop()
  await b.stop()
})

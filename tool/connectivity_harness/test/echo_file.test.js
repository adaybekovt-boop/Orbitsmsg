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
      if (
        name === 'frame' &&
        payload.channel === 'control' &&
        payload.body &&
        payload.body.type === 'wireHello'
      ) {
        resolve(payload.body)
      }
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

test('10 and 50 MiB path sends stay chunked and can resume', async () => {
  for (const size of [10 * 1024 * 1024, 50 * 1024 * 1024]) {
    const { a, b, peerId } = await pair()
    const src = path.join(os.tmpdir(), `orbits-file-${size}.bin`)
    fs.writeFileSync(src, Buffer.alloc(size, 9))
    const chunks = []
    const prev = b._emit
    const done = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('sendFile timeout ' + size)), 120_000)
      b._emit = (name, payload) => {
        prev(name, payload)
        if (name === 'frame' && payload.channel === 'attachment') {
          chunks.push(payload.body)
          if (payload.body.type === 'harness-file-end') {
            clearTimeout(timer)
            resolve()
          }
        }
      }
    })
    await a.sendFile(peerId, { path: src, fileName: path.basename(src), sizeBytes: size })
    await done
    const dataChunks = chunks.filter((c) => c.type === 'harness-file-chunk')
    assert.ok(dataChunks.length > 1)
    assert.ok(dataChunks.every((c) => Buffer.from(c.b64, 'base64').length <= 64 * 1024))
    assert.equal(a._sendFilePeakBuffer, 64 * 1024)
    assert.ok(chunks.some((c) => c.type === 'harness-file-end' && c.sha256))
    await a.stop()
    await b.stop()
    fs.unlinkSync(src)
  }
})

test('sendFile resumes after interrupt and rejects mutation', async () => {
  const { a, b, peerId } = await pair()
  const src = path.join(os.tmpdir(), 'orbits-resume.bin')
  const size = 2 * 1024 * 1024
  fs.writeFileSync(src, Buffer.alloc(size, 3))
  const id = 'xfer-resume'
  let firstOffset = -1
  const prev = b._emit
  const firstChunk = new Promise((resolve) => {
    b._emit = (name, payload) => {
      prev(name, payload)
      if (name === 'frame' && payload.body && payload.body.type === 'harness-file-chunk') {
        if (firstOffset < 0) {
          firstOffset = payload.body.offset
          resolve()
        }
      }
    }
  })
  const pending = a.sendFile(peerId, {
    path: src,
    transferId: id,
    sizeBytes: size,
  })
  await firstChunk
  a.cancelFile(id)
  await assert.rejects(pending)
  const statePath = path.join(os.tmpdir(), 'orbits-transfers', id + '.json')
  const resumeFrom = Math.max(0, firstOffset)
  const second = new Worklet({ backend: 'loopback' })
  try {
    await second.start({ peerId: 'A2', discoverySecret: Buffer.alloc(32, 9) })
    await second.connect({ port: b._loop.port })
    const secondPeer = Array.from(second._peers.keys())[0]
    const done = new Promise((resolve) => {
      const prevB = b._emit
      b._emit = (name, payload) => {
        prevB(name, payload)
        if (name === 'frame' && payload.body && payload.body.type === 'harness-file-end') {
          resolve()
        }
      }
    })
    await second.sendFile(secondPeer, {
      path: src,
      transferId: id,
      sizeBytes: size,
      resumeOffset: resumeFrom,
      resumeStatePath: statePath,
    })
    await done
    await assert.rejects(() =>
      second.sendFile(secondPeer, {
        path: src,
        transferId: id + '-mut',
        sizeBytes: size + 1,
      }),
    )
  } finally {
    await a.stop()
    await b.stop()
    await second.stop()
  }
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

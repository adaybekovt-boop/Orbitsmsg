'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { Worklet } = require('../src/worklet')

function harnessTmpNames() {
  return fs.readdirSync(os.tmpdir()).filter((n) => n.startsWith('orbits-harness-'))
}

function receivedFrames(events) {
  return events.filter(
    (e) =>
      e.name === 'frame' &&
      e.payload &&
      e.payload.body &&
      e.payload.body.type === 'harness-file-received',
  )
}

function attachmentFrames(events) {
  return events.filter((e) => e.name === 'frame' && e.payload && e.payload.channel === 'attachment')
}

test('hostile harness-file-start with nested fileKey does not open or emit received', () => {
  const worklet = new Worklet()
  const events = []
  worklet._emit = (name, payload) => events.push({ name, payload })
  const before = new Set(harnessTmpNames())
  const opened = []
  const origOpen = fs.openSync
  fs.openSync = function openSyncSpy(filePath, flags, mode) {
    opened.push(String(filePath))
    return origOpen.call(fs, filePath, flags, mode)
  }
  try {
    const consumed = worklet._handleIncomingFile('peer-a', {
      type: 'harness-file-start',
      id: 'file-nested',
      name: 'bad.bin',
      size: 4,
      sha256: 'abc',
      meta: { fileKey: 'nope' },
    })
    assert.equal(consumed, true)
    assert.equal(worklet._files.size, 0)
    assert.equal(receivedFrames(events).length, 0)
    assert.equal(opened.length, 0)
    worklet._onFrame(
      'peer-a',
      'attachment',
      Buffer.from(
        JSON.stringify({
          type: 'harness-file-start',
          id: 'file-nested-frame',
          name: 'bad.bin',
          size: 4,
          meta: { discoverySecret: 'leaked' },
        }),
      ),
    )
    assert.equal(worklet._files.size, 0)
    assert.equal(attachmentFrames(events).length, 0)
    assert.equal(receivedFrames(events).length, 0)
    const after = harnessTmpNames()
    assert.ok(after.every((n) => before.has(n)))
  } finally {
    fs.openSync = origOpen
  }
})

test('harness-file-start with id https://evil is consumed without opening that URL', () => {
  const worklet = new Worklet()
  const events = []
  worklet._emit = (name, payload) => events.push({ name, payload })
  const before = new Set(harnessTmpNames())
  const opened = []
  const origOpen = fs.openSync
  fs.openSync = function openSyncSpy(filePath, flags, mode) {
    opened.push(String(filePath))
    return origOpen.call(fs, filePath, flags, mode)
  }
  try {
    const consumed = worklet._handleIncomingFile('peer-a', {
      type: 'harness-file-start',
      id: 'https://evil',
      name: 'ok.bin',
      size: 4,
      sha256: 'abc',
    })
    assert.equal(consumed, true)
    assert.equal(worklet._files.size, 0)
    assert.equal(receivedFrames(events).length, 0)
    assert.ok(!opened.some((p) => p.includes('https://evil') || p.includes('://')))
    assert.equal(opened.length, 0)
    worklet._onFrame(
      'peer-a',
      'attachment',
      Buffer.from(
        JSON.stringify({
          type: 'harness-file-chunk',
          id: 'https://evil',
          offset: 0,
          b64: Buffer.from('x').toString('base64'),
        }),
      ),
    )
    assert.equal(worklet._files.size, 0)
    assert.equal(attachmentFrames(events).length, 0)
    const after = harnessTmpNames()
    assert.ok(after.every((n) => before.has(n)))
  } finally {
    fs.openSync = origOpen
  }
})

test('harness-file-start refuses a remote body.path', () => {
  const worklet = new Worklet()
  const events = []
  worklet._emit = (name, payload) => events.push({ name, payload })
  const before = new Set(harnessTmpNames())
  const consumed = worklet._handleIncomingFile('peer-a', {
    type: 'harness-file-start',
    id: 'file-path',
    name: 'ok.bin',
    size: 4,
    path: 'https://evil.example/x',
  })
  assert.equal(consumed, true)
  assert.equal(worklet._files.size, 0)
  assert.equal(receivedFrames(events).length, 0)
  const after = harnessTmpNames()
  assert.ok(after.every((n) => before.has(n)))
})

test('legit harness-file-start still opens a local incoming file', () => {
  const worklet = new Worklet()
  const events = []
  worklet._emit = (name, payload) => events.push({ name, payload })
  const src = Buffer.from('ok-bytes')
  let incoming
  try {
    const consumed = worklet._handleIncomingFile('peer-a', {
      type: 'harness-file-start',
      id: 'file-ok',
      name: 'ok.bin',
      size: src.length,
      sha256: '',
      b64: src.toString('base64'),
      text: 'host-plaintext-ok',
    })
    assert.equal(consumed, undefined)
    incoming = worklet._files.get('file-ok')
    assert.ok(incoming)
    assert.ok(incoming.path)
    assert.ok(!String(incoming.path).includes('://'))
    assert.equal(incoming.name, 'ok.bin')
    worklet._handleIncomingFile('peer-a', {
      type: 'harness-file-chunk',
      id: 'file-ok',
      offset: 0,
      b64: src.toString('base64'),
    })
    worklet._handleIncomingFile('peer-a', { type: 'harness-file-end', id: 'file-ok' })
    const received = receivedFrames(events)
    assert.equal(received.length, 1)
    assert.equal(received[0].payload.body.size, src.length)
    assert.equal(fs.readFileSync(incoming.path).equals(src), true)
  } finally {
    if (incoming && incoming.path) {
      try {
        fs.rmSync(path.dirname(incoming.path), { recursive: true, force: true })
      } catch {
        // temp already gone
      }
    }
  }
})

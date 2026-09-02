'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {
  Worklet,
  handleIpcRequest,
  ipcPayloadHasForbiddenKey,
} = require('../src/worklet')
const { contactDiscoveryTopic } = require('../src/discovery')

test('src/ has no eval, new Function, or remote fetch/import/require (source scan)', () => {
  const dir = path.join(__dirname, '..', 'src')
  for (const name of fs.readdirSync(dir)) {
    if (!name.endsWith('.js')) continue
    const src = fs.readFileSync(path.join(dir, name), 'utf8')
    assert.doesNotMatch(src, /\beval\s*\(/, name + ' contains eval(')
    assert.doesNotMatch(src, /new\s+Function\s*\(/, name + ' contains new Function(')
    assert.doesNotMatch(
      src,
      /\bfetch\s*\(\s*['"`][a-zA-Z][a-zA-Z0-9+.-]*:\/\//,
      name + ' fetches a remote URL',
    )
    assert.doesNotMatch(
      src,
      /\bimport\s*\(\s*['"`][a-zA-Z][a-zA-Z0-9+.-]*:\/\//,
      name + ' import() of a remote URL',
    )
    assert.doesNotMatch(
      src,
      /\brequire\s*\(\s*['"`][a-zA-Z][a-zA-Z0-9+.-]*:\/\//,
      name + ' require() of a remote URL',
    )
  }
})

test('invalid and short discovery secrets are rejected', async () => {
  assert.throws(
    () => contactDiscoveryTopic(Buffer.alloc(8, 2)),
    (err) => err && err.code === 'short-discovery-secret',
  )
  const a = new Worklet({ backend: 'loopback' })
  await a.start({ peerId: 'A' })
  await assert.rejects(() => a.publish({ deviceId: 'a' }), /32 bytes|discoverySecret/)
  await a.stop()
  const b = new Worklet({ backend: 'loopback' })
  await assert.rejects(
    () => b.start({ peerId: 'B', discoverySecret: Buffer.alloc(16, 1) }),
    /32 bytes/,
  )
})

test(':// paths are rejected for file, journal, and worklet', async () => {
  const w = new Worklet({ backend: 'loopback' })
  const secret = Buffer.alloc(32, 4)
  await assert.rejects(
    () => w.start({ peerId: 'A', discoverySecret: secret, journalDir: 'https://evil.example/j' }),
    /:\/\//,
  )
  const w2 = new Worklet({ backend: 'loopback' })
  await assert.rejects(
    () =>
      w2.start({
        peerId: 'A',
        discoverySecret: secret,
        worklet: 'https://evil.example/worklet.js',
      }),
    /:\/\//,
  )
  const a = new Worklet({ backend: 'loopback' })
  const b = new Worklet({ backend: 'loopback' })
  await a.start({ peerId: 'A', discoverySecret: secret })
  await b.start({ peerId: 'B', discoverySecret: secret })
  await a.publish({ deviceId: 'a' })
  await b.publish({ deviceId: 'b' })
  await a.connect({ port: b._loop.port })
  const peerId = Array.from(a._peers.keys())[0]
  await assert.rejects(
    () => a.sendFile(peerId, { path: 'https://evil.example/file.bin' }),
    /remote path/,
  )
  await assert.rejects(() => a.cancelFile('https://evil.example/id'), /:\/\//)
  await a.stop()
  await b.stop()
})

test('IPC send/sendFile/journal.append refuse identityPrivateKey fileKey fileKeyB64 discoverySecret', async () => {
  const w = new Worklet({ backend: 'loopback' })
  await w.start({ peerId: 'A', discoverySecret: Buffer.alloc(32, 6) })
  assert.equal(ipcPayloadHasForbiddenKey({ fileKey: 'x' }), true)
  assert.equal(ipcPayloadHasForbiddenKey({ meta: { identityPrivateKey: 'x' } }), true)
  await assert.rejects(
    () =>
      handleIpcRequest(w, {
        method: 'send',
        params: { peerId: 'p', channel: 'message', frame: { fileKey: 'nope' } },
      }),
    /forbidden/,
  )
  await assert.rejects(
    () =>
      handleIpcRequest(w, {
        method: 'send',
        params: { peerId: 'p', channel: 'message', frame: { identityPrivateKey: 'nope' } },
      }),
    /forbidden/,
  )
  await assert.rejects(
    () =>
      handleIpcRequest(w, {
        method: 'sendFile',
        params: {
          peerId: 'p',
          file: { path: path.join(os.tmpdir(), 'x'), fileKeyB64: 'nope' },
        },
      }),
    /forbidden/,
  )
  await assert.rejects(
    () =>
      handleIpcRequest(w, {
        method: 'journal.append',
        params: { fields: { discoverySecret: 'nope', encryptedEnvelope: 'e' } },
      }),
    /forbidden|secret/,
  )
  const dumped = JSON.stringify(w.diagnostics())
  assert.equal(dumped.includes('identityPrivateKey'), false)
  assert.equal(dumped.includes('fileKeyB64'), false)
  await w.stop()
})

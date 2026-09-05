'use strict'

/**
 * LOCAL TESTNET ONLY. Two in-process worklets, distinct storage roots,
 * distinct peer ids. Not a public DHT / NAT result.
 */

const { test } = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { encodeMux } = require('../src/mux')
const { Worklet } = require('../src/worklet')

async function authorizeAll(worklet) {
  for (const id of Array.from(worklet._peers.keys())) {
    const rec = worklet._peers.get(id)
    if (rec && rec.authState !== 'authenticated') {
      await worklet.authorize(id)
    }
  }
}

async function echo(from, toPeer, text) {
  const got = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('echo timeout ' + text)), 4000)
    const prev = from._emit
    from._emit = (name, payload) => {
      prev(name, payload)
      if (name === 'frame' && payload.body && payload.body.type === 'harness-echo-reply') {
        clearTimeout(timer)
        resolve(payload.body.text)
      }
    }
  })
  await from.send(toPeer, 'message', { type: 'harness-echo', id: text, text })
  return got
}

test('two-runtime local loopback: text, isolation, mux, traversal, survivor', async () => {
  const homeA = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-home-a-'))
  const homeB = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-home-b-'))
  const incomingProbe = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-outside-'))
  const a = new Worklet({ backend: 'loopback', allowHarnessFiles: true })
  const b = new Worklet({ backend: 'loopback', allowHarnessFiles: true })
  const secret = crypto.randomBytes(32)
  await a.start({
    peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
    discoverySecret: secret,
    storageDir: path.join(homeA, 'corestore'),
  })
  await b.start({
    peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
    discoverySecret: secret,
    storageDir: path.join(homeB, 'corestore'),
  })
  await a.publish({ deviceId: 'dev-a', ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA' })
  await b.publish({ deviceId: 'dev-b', ownerPeerId: 'ORBIT-BBBBBBBBBBBBBBBB' })
  await a.connect({ port: b._loop.port })
  assert.ok(a.events.some((e) => e.name === 'identity-pending'))
  assert.ok(b.events.some((e) => e.name === 'identity-pending'))
  assert.ok(!a.events.some((e) => e.name === 'connected'))
  await authorizeAll(a)
  await authorizeAll(b)
  assert.ok(a.events.some((e) => e.name === 'connected'))
  assert.ok(b.events.some((e) => e.name === 'connected'))

  const peerFromA = Array.from(a._peers.keys())[0]
  const peerFromB = Array.from(b._peers.keys())[0]
  assert.equal(await echo(a, peerFromA, 'A-to-B'), 'A-to-B')
  assert.equal(await echo(b, peerFromB, 'B-to-A'), 'B-to-A')

  const filePath = path.join(homeA, 'ten.bin')
  const bytes = crypto.randomBytes(10 * 1024 * 1024)
  fs.writeFileSync(filePath, bytes)
  const expectedSha = crypto.createHash('sha256').update(bytes).digest('hex')
  const incomingRoot = path.join(homeB, 'corestore', 'orbits-incoming')
  await a.sendFile(peerFromA, {
    path: filePath,
    sizeBytes: bytes.length,
    fileName: 'ten.bin',
    transferId: 'tenmeg',
  })
  await new Promise((r) => setTimeout(r, 400))
  const blobs = []
  if (fs.existsSync(incomingRoot)) {
    const walk = (dir) => {
      for (const name of fs.readdirSync(dir)) {
        const next = path.join(dir, name)
        if (fs.statSync(next).isDirectory()) walk(next)
        else if (name === 'blob') blobs.push(next)
      }
    }
    walk(incomingRoot)
  }
  assert.ok(blobs.length >= 1, 'incoming blob missing')
  const gotSha = crypto.createHash('sha256').update(fs.readFileSync(blobs[0])).digest('hex')
  assert.equal(gotSha, expectedSha)

  const attacker = Array.from(b._peers.values())[0]
  attacker.socket.write(encodeMux('attachment', Buffer.from(JSON.stringify({
    type: 'harness-file-start',
    id: '../escape',
    name: 'x.bin',
    size: 1,
  }))))
  await new Promise((r) => setTimeout(r, 40))
  assert.equal(fs.existsSync(path.join(incomingProbe, 'escape')), false)
  assert.equal(fs.existsSync(path.join(homeB, 'escape')), false)

  const header = Buffer.alloc(7)
  header.writeUInt8(1, 0)
  header.writeUInt8(1, 1)
  header.writeUInt32BE(0xffffffff, 3)
  attacker.socket.write(header)
  await new Promise((r) => setTimeout(r, 40))
  assert.equal(attacker.closed, true)
  assert.equal(a._started, true)
  assert.equal(b._started, true)

  await a.stop()
  assert.equal(b._started, true)
  await b.stop()
})

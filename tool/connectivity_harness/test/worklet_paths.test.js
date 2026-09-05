'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { encodeMux } = require('../src/mux')
const { Worklet } = require('../src/worklet')

async function authedPair() {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-path-'))
  const a = new Worklet({ backend: 'loopback', allowHarnessFiles: true })
  const b = new Worklet({ backend: 'loopback', allowHarnessFiles: true })
  const secret = Buffer.alloc(32, 2)
  await a.start({ peerId: 'ORBIT-A', discoverySecret: secret, storageDir: path.join(base, 'a') })
  await b.start({ peerId: 'ORBIT-B', discoverySecret: secret, storageDir: path.join(base, 'b') })
  await a.connect({ port: b._loop.port })
  for (const w of [a, b]) {
    for (const id of w._peers.keys()) await w.authorize(id)
  }
  return { a, b, base }
}

test('traversal transfer ids never write outside incoming root', async () => {
  const { a, b, base } = await authedPair()
  const root = path.join(base, 'b', 'orbits-incoming')
  const outside = path.join(base, 'pwned.txt')
  const victim = Array.from(b._peers.values())[0]
  const attacks = ['../pwned', '..\\pwned', '/tmp/pwned', 'C:\\Windows\\pwned', 'a/b', '%2e%2e']
  for (const id of attacks) {
    victim.socket.write(encodeMux('attachment', Buffer.from(JSON.stringify({
      type: 'harness-file-start',
      id,
      name: 'x.bin',
      size: 3,
    }))))
    await new Promise((r) => setTimeout(r, 20))
  }
  assert.equal(fs.existsSync(outside), false)
  if (fs.existsSync(root)) {
    const walked = []
    const stack = [root]
    while (stack.length) {
      const dir = stack.pop()
      for (const name of fs.readdirSync(dir)) {
        const full = path.join(dir, name)
        walked.push(full)
        if (fs.statSync(full).isDirectory()) stack.push(full)
      }
    }
    for (const full of walked) {
      assert.ok(full.startsWith(root), full)
    }
  }
  await a.stop()
  await b.stop()
})

test('identical transfer ids from two senders stay isolated', async () => {
  const { a, b, base } = await authedPair()
  const c = new Worklet({ backend: 'loopback', allowHarnessFiles: true })
  await c.start({
    peerId: 'ORBIT-C',
    discoverySecret: Buffer.alloc(32, 2),
    storageDir: path.join(base, 'c'),
  })
  await c.connect({ port: b._loop.port })
  for (const id of c._peers.keys()) await c.authorize(id)
  for (const id of b._peers.keys()) {
    const rec = b._peers.get(id)
    if (rec.authState !== 'authenticated') await b.authorize(id)
  }
  const src = path.join(base, 'same.bin')
  fs.writeFileSync(src, Buffer.from('alice-file'))
  const srcC = path.join(base, 'carol.bin')
  fs.writeFileSync(srcC, Buffer.from('carol-file-xx'))
  const received = []
  const prev = b._emit
  const done = new Promise((resolve) => {
    b._emit = (name, payload) => {
      prev(name, payload)
      if (name === 'frame' && payload.body && payload.body.type === 'harness-file-received') {
        received.push(payload.body)
        if (received.length === 2) resolve()
      }
    }
  })
  const aPeer = Array.from(a._peers.keys())[0]
  const cPeer = Array.from(c._peers.keys())[0]
  await a.sendFile(aPeer, { path: src, fileName: 'same.bin', transferId: 'sharedxferid' })
  await c.sendFile(cPeer, { path: srcC, fileName: 'same.bin', transferId: 'sharedxferid' })
  await done
  assert.equal(received.length, 2)
  assert.notEqual(received[0].path, received[1].path)
  assert.ok(received.every((r) => r.path.includes('orbits-incoming')))
  await a.stop()
  await b.stop()
  await c.stop()
})

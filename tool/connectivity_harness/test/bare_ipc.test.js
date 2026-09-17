'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')
const { encode, Decoder, REQUEST, RESPONSE, EVENT } = require('../src/ipc')

function findBare() {
  if (process.env.ORBITS_BARE_BIN && fs.existsSync(process.env.ORBITS_BARE_BIN)) {
    return process.env.ORBITS_BARE_BIN
  }
  const root = path.join(__dirname, '..', '..', 'bare')
  const slots = [
    path.join(root, 'linux-x64', 'bare'),
    path.join(root, 'linux-arm64', 'bare'),
    path.join(root, 'darwin-x64', 'bare'),
    path.join(root, 'darwin-arm64', 'bare'),
    path.join(root, 'windows-x64', 'bare.exe'),
  ]
  return slots.find((p) => fs.existsSync(p)) || null
}

const bareBin = findBare()
const graph = fs.existsSync(
  path.join(__dirname, '..', 'node_modules', 'bare-fs', 'package.json'),
)
const skip = !bareBin || !graph ? 'vendored Bare + bare-fs not present' : false

test('Bare worklet answers orbits-bare-ipc-v1 start/stop', { skip }, async () => {
  const script = path.join(__dirname, '..', 'src', 'worklet.js')
  const child = spawn(bareBin, [script], {
    env: { ...process.env, ORBITS_HARNESS_BACKEND: 'loopback' },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const decoder = new Decoder()
  const pending = new Map()
  child.stdout.on('data', (chunk) => {
    for (const msg of decoder.add(chunk)) {
      if (msg.type === EVENT) continue
      if (msg.type !== RESPONSE) continue
      const wait = pending.get(msg.body.id)
      if (!wait) continue
      pending.delete(msg.body.id)
      if (msg.body.ok === false) wait.reject(new Error(msg.body.error))
      else wait.resolve(msg.body.result || {})
    }
  })
  let stderr = ''
  child.stderr.on('data', (c) => {
    stderr += c.toString()
  })
  function request(id, method, params) {
    const p = new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject })
    })
    child.stdin.write(encode(REQUEST, { id, method, params: params || {} }))
    return p
  }
  try {
    const started = await Promise.race([
      request(1, 'start', { peerId: 'ORBIT-AA' }),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error('start timeout ' + stderr.slice(0, 400))), 8000),
      ),
    ])
    assert.ok(started.port)
    const appended = await request(2, 'journal.append', {
      fields: { encryptedEnvelope: 'djI6Y2lwaGVy' },
    })
    assert.equal(appended.kind, 'messageEnvelopeCreated')
    await request(3, 'stop', {})
  } finally {
    child.kill()
  }
})

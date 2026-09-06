'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { REQUEST, RESPONSE, EVENT, encode, Decoder } = require('../src/ipc')

function officialBare() {
  const pinned = path.join(
    __dirname,
    '..',
    '..',
    '..',
    'build',
    'orbits-bare',
    'linux-x64',
    'bare',
  )
  return fs.existsSync(pinned) ? pinned : process.env.ORBITS_BARE_RUNTIME
}

function rpc(child, decoder, id, method, params, timeoutMs = 12000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout waiting for ' + method)), timeoutMs)
    const onData = (chunk) => {
      for (const msg of decoder.add(chunk)) {
        if (msg.type === EVENT) continue
        if (msg.type === RESPONSE && msg.body.id === id) {
          clearTimeout(timer)
          child.stdout.off('data', onData)
          if (!msg.body.ok) reject(new Error(msg.body.error))
          else resolve(msg.body.result || {})
        }
      }
    }
    child.stdout.on('data', onData)
    child.stdin.write(encode(REQUEST, { id, method, params }))
  })
}

test('official Bare launches the worklet and answers framed IPC', async (t) => {
  const bare = officialBare()
  if (!bare) {
    t.skip('official Bare binary is not fetched')
    return
  }
  const worklet = path.join(__dirname, '..', 'src', 'worklet.js')
  const child = spawn(bare, [worklet], {
    cwd: path.join(__dirname, '..'),
    env: { ...process.env, ORBITS_HARNESS_BACKEND: 'loopback' },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const err = []
  child.stderr.on('data', (c) => err.push(c))
  t.after(() => {
    child.kill()
  })
  const decoder = new Decoder()
  try {
    const storageDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-bare-ipc-'))
    const started = await rpc(child, decoder, 1, 'start', {
      peerId: 'ORBIT-BARE-A',
      requireRealCorestore: true,
      storageDir,
    })
    assert.ok(started)
    const info = await rpc(child, decoder, 2, 'runtime.info', {})
    assert.equal(info.runtime, 'bare')
    assert.equal(info.journal, 'corestore')
    assert.equal(info.version, 'orbits-bare-ipc-v1')
    await rpc(child, decoder, 3, 'journal.append', {
      fields: { encryptedEnvelope: 'v2:bare' },
    })
    const listed = await rpc(child, decoder, 4, 'journal.list', {})
    assert.equal(listed.blocks.length, 1)
    await rpc(child, decoder, 5, 'stop', {})
  } catch (e) {
    e.message += ' stderr=' + Buffer.concat(err).toString()
    throw e
  }
})

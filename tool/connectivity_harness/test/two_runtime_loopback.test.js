'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { REQUEST, RESPONSE, EVENT, encode, Decoder } = require('../src/ipc')

function officialBare() {
  const pinned = path.join(__dirname, '..', '..', '..', 'build', 'orbits-bare', 'linux-x64', 'bare')
  return fs.existsSync(pinned) ? pinned : process.env.ORBITS_BARE_RUNTIME
}

function attach(child) {
  const decoder = new Decoder()
  const pending = new Map()
  const events = []
  child.stdout.on('data', (chunk) => {
    for (const msg of decoder.add(chunk)) {
      if (msg.type === EVENT) {
        events.push(msg.body)
        continue
      }
      if (msg.type === RESPONSE) {
        const wait = pending.get(msg.body.id)
        if (!wait) continue
        pending.delete(msg.body.id)
        if (!msg.body.ok) wait.reject(new Error(msg.body.error))
        else wait.resolve(msg.body.result || {})
      }
    }
  })
  let next = 1
  return {
    events,
    request(method, params = {}, timeoutMs = 15000) {
      const id = next++
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('timeout ' + method)), timeoutMs)
        pending.set(id, {
          resolve: (v) => {
            clearTimeout(timer)
            resolve(v)
          },
          reject: (e) => {
            clearTimeout(timer)
            reject(e)
          },
        })
        child.stdin.write(encode(REQUEST, { id, method, params }))
      })
    },
    waitEvent(name, timeoutMs = 12000) {
      const found = events.find((e) => e.name === name)
      if (found) return Promise.resolve(found)
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('timeout event ' + name)), timeoutMs)
        const started = events.length
        const poll = setInterval(() => {
          const match = events.slice(started).find((e) => e.name === name)
          if (!match) return
          clearInterval(poll)
          clearTimeout(timer)
          resolve(match)
        }, 25)
      })
    },
  }
}

function spawnWorklet(bare, backend) {
  return spawn(bare, [path.join(__dirname, '..', 'src', 'worklet.js')], {
    cwd: path.join(__dirname, '..'),
    env: { ...process.env, ORBITS_HARNESS_BACKEND: backend },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
}

test('two official Bare worklets exchange a payload over loopback', async (t) => {
  const bare = officialBare()
  if (!bare) {
    t.skip('official Bare binary is not fetched')
    return
  }
  const a = spawnWorklet(bare, 'loopback')
  const b = spawnWorklet(bare, 'loopback')
  t.after(() => {
    a.kill()
    b.kill()
  })
  const ha = attach(a)
  const hb = attach(b)
  const dirA = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-loop-a-'))
  const dirB = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-loop-b-'))
  const startedA = await ha.request('start', {
    peerId: 'ORBIT-A',
    storageDir: dirA,
    requireRealCorestore: true,
  })
  await hb.request('start', {
    peerId: 'ORBIT-B',
    storageDir: dirB,
    requireRealCorestore: true,
  })
  assert.ok(startedA.port)
  await hb.request('connect', { port: startedA.port })
  const pendingA = await ha.waitEvent('identity-pending')
  const pendingB = await hb.waitEvent('identity-pending')
  await ha.request('authorize', { peerId: pendingA.payload.peerId })
  await hb.request('authorize', { peerId: pendingB.payload.peerId })
  const connected = await ha.waitEvent('connected')
  assert.ok(connected.payload.peerId)
  await ha.request('send', {
    peerId: connected.payload.peerId,
    channel: 'message',
    frame: { type: 'harness-echo', id: '1', text: 'hello-bare' },
  })
  const reply = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('echo timeout')), 12000)
    const started = ha.events.length
    const poll = setInterval(() => {
      const frame = ha.events.slice(started).find(
        (e) => e.name === 'frame' && e.payload && e.payload.body && e.payload.body.type === 'harness-echo-reply',
      )
      if (!frame) return
      clearInterval(poll)
      clearTimeout(timer)
      resolve(frame.payload.body)
    }, 25)
  })
  assert.equal(reply.text, 'hello-bare')
  await ha.request('stop')
  await hb.request('stop')
})

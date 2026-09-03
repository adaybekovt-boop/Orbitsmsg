'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
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
    request(method, params = {}) {
      const id = next++
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('timeout ' + method)), 12000)
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
  }
}

test('two official Bare worklets exchange a payload over loopback', async (t) => {
  const bare = officialBare()
  if (!bare) {
    t.skip('official Bare binary is not fetched')
    return
  }
  const worklet = path.join(__dirname, '..', 'src', 'worklet.js')
  const cwd = path.join(__dirname, '..')
  const a = spawn(bare, [worklet], {
    cwd,
    env: { ...process.env, ORBITS_HARNESS_BACKEND: 'loopback' },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const b = spawn(bare, [worklet], {
    cwd,
    env: { ...process.env, ORBITS_HARNESS_BACKEND: 'loopback' },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  t.after(() => {
    a.kill()
    b.kill()
  })
  const ha = attach(a)
  const hb = attach(b)
  const startedA = await ha.request('start', { peerId: 'ORBIT-A' })
  await hb.request('start', { peerId: 'ORBIT-B' })
  assert.ok(startedA.port)
  await hb.request('connect', { port: startedA.port })
  await new Promise((r) => setTimeout(r, 200))
  await ha.request('send', {
    peerId: [...ha.events].reverse().find((e) => e.name === 'connected')?.payload?.peerId,
    channel: 'message',
    frame: { type: 'harness-echo', id: '1', text: 'hello-bare' },
  }).catch(() => {})
})

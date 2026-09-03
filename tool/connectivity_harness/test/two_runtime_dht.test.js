'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const dgram = require('node:dgram')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { createLocalBootstrap } = require('../src/swarm')

function freeUdpPort() {
  return new Promise((resolve, reject) => {
    const socket = dgram.createSocket('udp4')
    socket.once('error', reject)
    socket.bind(0, '127.0.0.1', () => {
      const port = socket.address().port
      socket.close(() => resolve(port))
    })
  })
}
const { REQUEST, RESPONSE, EVENT, encode, Decoder } = require('../src/ipc')

function officialBare() {
  const pinned = path.join(__dirname, '..', '..', '..', 'build', 'orbits-bare', 'linux-x64', 'bare')
  return fs.existsSync(pinned) ? pinned : process.env.ORBITS_BARE_RUNTIME
}

function ignoreResetAfterSuccess(err) {
  if (err && (err.code === 'ECONNRESET' || /connection reset by peer/.test(String(err)))) {
    return
  }
  throw err
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
    waitEvent(name, timeoutMs = 15000) {
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

test('two official Bare worklets exchange an encrypted HyperDHT payload', async (t) => {
  const bare = officialBare()
  if (!bare) {
    t.skip('official Bare binary is not fetched')
    return
  }
  process.on('uncaughtException', ignoreResetAfterSuccess)
  t.after(() => process.off('uncaughtException', ignoreResetAfterSuccess))
  const a = spawnWorklet(bare, 'loopback')
  const b = spawnWorklet(bare, 'loopback')
  t.after(() => {
    a.kill()
    b.kill()
  })
  const ha = attach(a)
  const hb = attach(b)
  const dirA = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-dht-a-'))
  const dirB = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-dht-b-'))
  await ha.request('start', {
    peerId: 'ORBIT-DHT-A',
    storageDir: dirA,
    requireRealCorestore: true,
  })
  await hb.request('start', {
    peerId: 'ORBIT-DHT-B',
    storageDir: dirB,
    requireRealCorestore: true,
  })
  const bootPort = await freeUdpPort()
  const boot = await ha.request('dht.bootstrap', { port: bootPort })
  assert.ok(boot.bootstrap && boot.bootstrap[0] && boot.bootstrap[0].port)
  const listened = await ha.request('dht.listen', { bootstrap: boot.bootstrap })
  assert.ok(listened.publicKey)
  await new Promise((r) => setTimeout(r, 400))
  let connected = false
  let lastError
  for (let attempt = 0; attempt < 5 && !connected; attempt++) {
    try {
      await hb.request('dht.connect', {
        bootstrap: boot.bootstrap,
        publicKey: listened.publicKey,
        payload: 'orbits-bare-dht',
      })
      connected = true
    } catch (err) {
      lastError = err
      await new Promise((r) => setTimeout(r, 300 * (attempt + 1)))
    }
  }
  if (!connected) throw lastError || new Error('dht.connect failed')
  const data = await ha.waitEvent('dht.data')
  assert.equal(data.payload.text, 'orbits-bare-dht')
  await ha.request('stop')
  await hb.request('stop')
  await new Promise((r) => setTimeout(r, 200))
})

test('official Bare Hyperswarm backend joins a local bootstrap topic', async (t) => {
  const bare = officialBare()
  if (!bare) {
    t.skip('official Bare binary is not fetched')
    return
  }
  process.on('uncaughtException', ignoreResetAfterSuccess)
  t.after(() => process.off('uncaughtException', ignoreResetAfterSuccess))
  const boot = await createLocalBootstrap(0)
  t.after(() => boot.destroy())
  const child = spawnWorklet(bare, 'hyperswarm')
  t.after(() => child.kill())
  const h = attach(child)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-swarm-'))
  const started = await h.request('start', {
    peerId: 'ORBIT-SWARM',
    storageDir: dir,
    requireRealCorestore: true,
    bootstrap: boot.bootstrap,
    firewalled: false,
    discoverySecret: Buffer.alloc(32, 7).toString('hex'),
  })
  const info = await h.request('runtime.info')
  assert.equal(info.runtime, 'bare')
  assert.equal(info.backend, 'hyperswarm')
  assert.ok(started.noisePublicKey)
  await h.request('publish', {
    binding: { deviceId: 'dev-swarm' },
  })
  const published = await h.waitEvent('published')
  assert.equal(published.payload.topicHex.length, 64)
  await h.request('stop')
})

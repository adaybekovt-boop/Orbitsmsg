'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { createLocalBootstrap } = require('../src/swarm')
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
    request(method, params = {}, timeoutMs = 30000) {
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
    waitEvent(name, timeoutMs = 30000, match) {
      const found = events.find(
        (e) => e.name === name && (!match || match(e)),
      )
      if (found) return Promise.resolve(found)
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('timeout event ' + name)), timeoutMs)
        const started = events.length
        const poll = setInterval(() => {
          const hit = events.slice(started).find(
            (e) => e.name === name && (!match || match(e)),
          )
          if (!hit) return
          clearInterval(poll)
          clearTimeout(timer)
          resolve(hit)
        }, 25)
      })
    },
  }
}

function spawnWorklet(bare, backend, extraArgs = []) {
  return spawn(
    bare,
    [path.join(__dirname, '..', 'src', 'worklet.js'), '--backend=' + backend, ...extraArgs],
    {
      cwd: path.join(__dirname, '..'),
      env: { ...process.env, ORBITS_HARNESS_BACKEND: backend },
      stdio: ['pipe', 'pipe', 'pipe'],
    },
  )
}

function waitFrame(handler, pred, timeoutMs = 30000) {
  const found = handler.events.find(
    (e) => e.name === 'frame' && pred(e.payload || {}),
  )
  if (found) return Promise.resolve(found)
  return handler.waitEvent('frame', timeoutMs, (e) => pred(e.payload || {}))
}

test('two official Bare Hyperswarm worklets exchange messages and a hashed file', async (t) => {
  const bare = officialBare()
  if (!bare) {
    t.skip('official Bare binary is not fetched')
    return
  }
  process.on('uncaughtException', ignoreResetAfterSuccess)
  t.after(() => process.off('uncaughtException', ignoreResetAfterSuccess))

  const boot = await createLocalBootstrap(0)
  t.after(() => boot.destroy())
  const dirA = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-hs-a-'))
  const dirB = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-hs-b-'))
  const secret = crypto.randomBytes(32)

  const a = spawnWorklet(bare, 'hyperswarm')
  const b = spawnWorklet(bare, 'hyperswarm')
  t.after(() => {
    a.kill()
    b.kill()
  })
  const ha = attach(a)
  const hb = attach(b)

  const startedA = await ha.request('start', {
    peerId: 'ORBIT-HS-A',
    storageDir: dirA,
    requireRealCorestore: true,
    backend: 'hyperswarm',
    bootstrap: boot.bootstrap,
    firewalled: false,
    discoverySecret: Array.from(secret),
  })
  const startedB = await hb.request('start', {
    peerId: 'ORBIT-HS-B',
    storageDir: dirB,
    requireRealCorestore: true,
    backend: 'hyperswarm',
    bootstrap: boot.bootstrap,
    firewalled: false,
    discoverySecret: Array.from(secret),
  })
  const infoA = await ha.request('runtime.info')
  const infoB = await hb.request('runtime.info')
  assert.equal(infoA.runtime, 'bare')
  assert.equal(infoA.backend, 'hyperswarm')
  assert.equal(infoB.backend, 'hyperswarm')
  assert.ok(startedA.noisePublicKey)
  assert.ok(startedB.noisePublicKey)

  await ha.request('publish', { binding: { deviceId: 'dev-a' } })
  await hb.request('publish', { binding: { deviceId: 'dev-b' } })
  await ha.waitEvent('published')
  await hb.waitEvent('published')

  await Promise.all([
    ha.request(
      'connect',
      {
        peerId: 'ORBIT-HS-B',
        noisePublicKey: startedB.noisePublicKey,
        timeoutMs: 20000,
      },
      25000,
    ),
    hb.request(
      'connect',
      {
        peerId: 'ORBIT-HS-A',
        noisePublicKey: startedA.noisePublicKey,
        timeoutMs: 20000,
      },
      25000,
    ),
  ])
  await ha.waitEvent('connected')
  await hb.waitEvent('connected')

  const unique = 'orbits-hs-' + crypto.randomBytes(8).toString('hex')
  await ha.request('send', {
    peerId: 'ORBIT-HS-B',
    channel: 'message',
    frame: { type: 'harness-echo', id: '1', text: unique },
  })
  const echo = await waitFrame(
    ha,
    (p) => p.body && p.body.type === 'harness-echo-reply' && p.body.text === unique,
  )
  assert.equal(echo.payload.body.text, unique)

  const inbound = await waitFrame(
    hb,
    (p) => p.body && p.body.type === 'harness-echo' && p.body.text === unique,
  )
  assert.equal(inbound.payload.body.text, unique)

  const reply = 'reply-' + unique
  await hb.request('send', {
    peerId: 'ORBIT-HS-A',
    channel: 'message',
    frame: { type: 'note', text: reply },
  })
  const back = await waitFrame(ha, (p) => p.body && p.body.text === reply)
  assert.equal(back.payload.body.text, reply)

  await ha.request('journal.append', {
    kind: 'messageEnvelopeCreated',
    fields: { encryptedEnvelope: Buffer.from(unique).toString('base64') },
  })
  const listed = await ha.request('journal.list')
  assert.ok(listed.blocks && listed.blocks.length >= 1)

  await ha.request('stop')
  await hb.request('stop')
  a.kill()
  b.kill()
  await new Promise((r) => setTimeout(r, 300))

  const a2 = spawnWorklet(bare, 'hyperswarm')
  const b2 = spawnWorklet(bare, 'hyperswarm')
  t.after(() => {
    a2.kill()
    b2.kill()
  })
  const ha2 = attach(a2)
  const hb2 = attach(b2)
  await ha2.request('start', {
    peerId: 'ORBIT-HS-A',
    storageDir: dirA,
    requireRealCorestore: true,
    backend: 'hyperswarm',
    bootstrap: boot.bootstrap,
    firewalled: false,
    discoverySecret: Array.from(secret),
  })
  await hb2.request('start', {
    peerId: 'ORBIT-HS-B',
    storageDir: dirB,
    requireRealCorestore: true,
    backend: 'hyperswarm',
    bootstrap: boot.bootstrap,
    firewalled: false,
    discoverySecret: Array.from(secret),
  })
  const persisted = await ha2.request('journal.list')
  assert.ok(persisted.blocks && persisted.blocks.length >= 1)

  await ha2.request('publish', { binding: { deviceId: 'dev-a' } })
  await hb2.request('publish', { binding: { deviceId: 'dev-b' } })
  const againA = await ha2.request('runtime.info')
  const againB = await hb2.request('runtime.info')
  await Promise.all([
    ha2.request(
      'connect',
      { peerId: 'ORBIT-HS-B', noisePublicKey: againB.noisePublicKey, timeoutMs: 20000 },
      25000,
    ),
    hb2.request(
      'connect',
      { peerId: 'ORBIT-HS-A', noisePublicKey: againA.noisePublicKey, timeoutMs: 20000 },
      25000,
    ),
  ])

  const src = path.join(os.tmpdir(), 'orbits-hs-10m.bin')
  const payload = crypto.randomBytes(10 * 1024 * 1024)
  fs.writeFileSync(src, payload)
  const expected = crypto.createHash('sha256').update(payload).digest('hex')
  const chunks = []
  const done = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('file timeout')), 120000)
    const started = hb2.events.length
    const poll = setInterval(() => {
      for (const e of hb2.events.slice(started)) {
        if (e.name !== 'frame' || e.payload.channel !== 'attachment') continue
        chunks.push(e.payload.body)
        if (e.payload.body && e.payload.body.type === 'harness-file-end') {
          clearInterval(poll)
          clearTimeout(timer)
          resolve()
        }
      }
    }, 25)
  })
  await ha2.request(
    'sendFile',
    {
      peerId: 'ORBIT-HS-B',
      file: { path: src, sizeBytes: payload.length, fileName: 'orbits-hs-10m.bin' },
    },
    120000,
  )
  await done
  const end = chunks.find((c) => c && c.type === 'harness-file-end')
  assert.ok(end)
  assert.equal(end.sha256, expected)
  const rebuilt = Buffer.concat(
    chunks
      .filter((c) => c && c.type === 'harness-file-chunk')
      .sort((x, y) => x.offset - y.offset)
      .map((c) => Buffer.from(c.b64, 'base64')),
  )
  assert.equal(crypto.createHash('sha256').update(rebuilt).digest('hex'), expected)

  await ha2.request('stop')
  await hb2.request('stop')
})

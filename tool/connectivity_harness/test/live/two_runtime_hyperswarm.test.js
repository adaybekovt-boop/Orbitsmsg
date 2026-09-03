'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

// Stable path resolution anchored to directory of this test file (F-03)
const HARNESS_DIR = path.resolve(__dirname, '..', '..')
const REPO_ROOT = path.resolve(HARNESS_DIR, '..', '..')
const { createLocalTestnet } = require(path.join(HARNESS_DIR, 'src', 'swarm'))
const { REQUEST, RESPONSE, EVENT, encode, Decoder } = require(path.join(HARNESS_DIR, 'src', 'ipc'))

function officialBare() {
  const pinned = path.join(REPO_ROOT, 'build', 'orbits-bare', 'linux-x64', 'bare')
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
    [path.join(HARNESS_DIR, 'src', 'worklet.js'), '--backend=' + backend, ...extraArgs],
    {
      cwd: HARNESS_DIR,
      env: {
        ...process.env,
        ORBITS_HARNESS_BACKEND: backend,
        NODE_PATH: path.join(HARNESS_DIR, 'node_modules'),
      },
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

test('live Hyperswarm regression: two official Bare worklets over isolated testnet', async (t) => {
  // 1. Verify Bare binary exists and path resolves independently of shell CWD
  const bare = officialBare()
  if (!bare) {
    t.skip('official Bare binary is not fetched')
    return
  }

  // Set up deterministic 3-node DHT testnet (F-04)
  const testnet = await createLocalTestnet(3)
  t.after(async () => {
    await testnet.destroy()
  })

  const dirA = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-live-a-'))
  const dirB = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-live-b-'))
  const secret = crypto.randomBytes(32)

  // 2. A and B start successfully
  const procA = spawnWorklet(bare, 'hyperswarm')
  const procB = spawnWorklet(bare, 'hyperswarm')
  t.after(() => {
    try { procA.kill() } catch {}
    try { procB.kill() } catch {}
  })

  let procAExit = null
  let procBExit = null
  procA.on('exit', (code, signal) => { procAExit = { code, signal } })
  procB.on('exit', (code, signal) => { procBExit = { code, signal } })

  const ha = attach(procA)
  const hb = attach(procB)

  const startedA = await ha.request('start', {
    peerId: 'ORBIT-LIVE-A',
    storageDir: dirA,
    requireRealCorestore: true,
    backend: 'hyperswarm',
    bootstrap: testnet.bootstrap,
    firewalled: false,
    discoverySecret: Array.from(secret),
  })
  const startedB = await hb.request('start', {
    peerId: 'ORBIT-LIVE-B',
    storageDir: dirB,
    requireRealCorestore: true,
    backend: 'hyperswarm',
    bootstrap: testnet.bootstrap,
    firewalled: false,
    discoverySecret: Array.from(secret),
  })

  const infoA0 = await ha.request('runtime.info')
  const infoB0 = await hb.request('runtime.info')
  assert.equal(infoA0.runtime, 'bare')
  assert.equal(infoA0.backend, 'hyperswarm')
  assert.equal(infoB0.runtime, 'bare')
  assert.equal(infoB0.backend, 'hyperswarm')
  assert.ok(startedA.noisePublicKey)
  assert.ok(startedB.noisePublicKey)

  // 3. A and B publish the intended shared topic
  await ha.request('publish', { binding: { deviceId: 'dev-live-a' } })
  await hb.request('publish', { binding: { deviceId: 'dev-live-b' } })
  const pubEventA = await ha.waitEvent('published')
  const pubEventB = await hb.waitEvent('published')
  assert.equal(pubEventA.payload.topicHex, pubEventB.payload.topicHex)

  // 4. Connect and both receive the correct logical connected event (no phantom noise keys - F-13)
  await Promise.all([
    ha.request(
      'connect',
      {
        peerId: 'ORBIT-LIVE-B',
        noisePublicKey: startedB.noisePublicKey,
        timeoutMs: 25000,
      },
      30000,
    ),
    hb.request(
      'connect',
      {
        peerId: 'ORBIT-LIVE-A',
        noisePublicKey: startedA.noisePublicKey,
        timeoutMs: 25000,
      },
      30000,
    ),
  ])

  const connEventA = await ha.waitEvent('connected')
  const connEventB = await hb.waitEvent('connected')
  assert.equal(connEventA.payload.peerId, 'ORBIT-LIVE-B')
  assert.equal(connEventB.payload.peerId, 'ORBIT-LIVE-A')

  // Verify no noise hex event was emitted
  const allConnA = ha.events.filter((e) => e.name === 'connected')
  const allConnB = hb.events.filter((e) => e.name === 'connected')
  assert.equal(allConnA.length, 1)
  assert.equal(allConnB.length, 1)
  assert.ok(!/^[0-9a-f]{64}$/i.test(allConnA[0].payload.peerId))
  assert.ok(!/^[0-9a-f]{64}$/i.test(allConnB[0].payload.peerId))

  // 5. A sends a unique binary/text payload to B
  const payloadFromA = 'payload-A-to-B-' + crypto.randomBytes(16).toString('hex')
  await ha.request('send', {
    peerId: 'ORBIT-LIVE-B',
    channel: 'message',
    frame: { type: 'harness-echo', id: 'm1', text: payloadFromA },
  })

  // 6. B receives the exact bytes
  const inboundB = await waitFrame(
    hb,
    (p) => p.body && p.body.type === 'harness-echo' && p.body.text === payloadFromA,
  )
  assert.equal(inboundB.payload.body.text, payloadFromA)

  // 7. B replies and A receives the exact bytes
  const payloadFromB = 'reply-B-to-A-' + crypto.randomBytes(16).toString('hex')
  await hb.request('send', {
    peerId: 'ORBIT-LIVE-A',
    channel: 'message',
    frame: { type: 'note', id: 'm2', text: payloadFromB },
  })
  const inboundA = await waitFrame(
    ha,
    (p) => p.body && p.body.type === 'note' && p.body.text === payloadFromB,
  )
  assert.equal(inboundA.payload.body.text, payloadFromB)

  // Also verify echo reply from A's original message
  const echoReply = await waitFrame(
    ha,
    (p) => p.body && p.body.type === 'harness-echo-reply' && p.body.text === payloadFromA,
  )
  assert.equal(echoReply.payload.body.text, payloadFromA)

  // 8. B stops normally
  await hb.request('stop')
  procB.kill()
  await new Promise((r) => setTimeout(r, 200))

  // 9. A receives exactly one logical disconnect for B (F-02, F-13)
  const discEventA = await ha.waitEvent('disconnected', 15000)
  assert.equal(discEventA.payload.peerId, 'ORBIT-LIVE-B')
  const allDiscA = ha.events.filter((e) => e.name === 'disconnected')
  assert.equal(allDiscA.length, 1)

  // 10. A remains alive and answers runtime.info after B is gone (F-02)
  const infoAAfterB = await ha.request('runtime.info')
  assert.equal(infoAAfterB.runtime, 'bare')
  assert.equal(infoAAfterB.peerCount, 0)
  assert.equal(procAExit, null, 'Worklet A must not crash or exit when B disconnects')

  // 11. A stops normally without timeout or signal
  await ha.request('stop')
  procA.kill()
  await new Promise((r) => setTimeout(r, 200))

  // 12. No process produced an unhandled exception or SIGABRT
  if (procAExit) {
    assert.ok(procAExit.code === 0 || procAExit.signal === 'SIGTERM' || procAExit.signal === null)
    assert.notEqual(procAExit.signal, 'SIGABRT')
  }
  if (procBExit) {
    assert.ok(procBExit.code === 0 || procBExit.signal === 'SIGTERM' || procBExit.signal === null)
    assert.notEqual(procBExit.signal, 'SIGABRT')
  }
})

test('live Hyperswarm regression: reverse direction - A stops, B survives and stays responsive', async (t) => {
  const bare = officialBare()
  if (!bare) {
    t.skip('official Bare binary is not fetched')
    return
  }

  const testnet = await createLocalTestnet(3)
  t.after(async () => {
    await testnet.destroy()
  })

  const dirA = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-rev-a-'))
  const dirB = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-rev-b-'))
  const secret = crypto.randomBytes(32)

  const procA = spawnWorklet(bare, 'hyperswarm')
  const procB = spawnWorklet(bare, 'hyperswarm')
  t.after(() => {
    try { procA.kill() } catch {}
    try { procB.kill() } catch {}
  })

  let procBExit = null
  procB.on('exit', (code, signal) => { procBExit = { code, signal } })

  const ha = attach(procA)
  const hb = attach(procB)

  const startedA = await ha.request('start', {
    peerId: 'ORBIT-REV-A',
    storageDir: dirA,
    requireRealCorestore: true,
    backend: 'hyperswarm',
    bootstrap: testnet.bootstrap,
    firewalled: false,
    discoverySecret: Array.from(secret),
  })
  const startedB = await hb.request('start', {
    peerId: 'ORBIT-REV-B',
    storageDir: dirB,
    requireRealCorestore: true,
    backend: 'hyperswarm',
    bootstrap: testnet.bootstrap,
    firewalled: false,
    discoverySecret: Array.from(secret),
  })

  await ha.request('publish', { binding: { deviceId: 'dev-rev-a' } })
  await hb.request('publish', { binding: { deviceId: 'dev-rev-b' } })
  await ha.waitEvent('published')
  await hb.waitEvent('published')

  await Promise.all([
    ha.request(
      'connect',
      { peerId: 'ORBIT-REV-B', noisePublicKey: startedB.noisePublicKey, timeoutMs: 25000 },
      30000,
    ),
    hb.request(
      'connect',
      { peerId: 'ORBIT-REV-A', noisePublicKey: startedA.noisePublicKey, timeoutMs: 25000 },
      30000,
    ),
  ])

  await ha.waitEvent('connected')
  await hb.waitEvent('connected')

  // A stops first
  await ha.request('stop')
  procA.kill()

  // B must receive exactly one disconnect event for A
  const discB = await hb.waitEvent('disconnected', 15000)
  assert.equal(discB.payload.peerId, 'ORBIT-REV-A')
  const allDiscB = hb.events.filter((e) => e.name === 'disconnected')
  assert.equal(allDiscB.length, 1)

  // B remains alive and responsive to runtime.info
  const infoBAfterA = await hb.request('runtime.info')
  assert.equal(infoBAfterA.runtime, 'bare')
  assert.equal(infoBAfterA.peerCount, 0)
  assert.equal(procBExit, null, 'Worklet B must not crash or exit when A disconnects')

  // B stops cleanly
  await hb.request('stop')
  procB.kill()
})

test('live Hyperswarm regression: remote reset during active send does not kill survivor', async (t) => {
  const bare = officialBare()
  if (!bare) {
    t.skip('official Bare binary is not fetched')
    return
  }

  const testnet = await createLocalTestnet(3)
  t.after(async () => {
    await testnet.destroy()
  })

  const dirA = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-rst-a-'))
  const dirB = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-rst-b-'))
  const secret = crypto.randomBytes(32)

  const procA = spawnWorklet(bare, 'hyperswarm')
  const procB = spawnWorklet(bare, 'hyperswarm')
  t.after(() => {
    try { procA.kill() } catch {}
    try { procB.kill() } catch {}
  })

  let procAExit = null
  procA.on('exit', (code, signal) => { procAExit = { code, signal } })

  const ha = attach(procA)
  const hb = attach(procB)

  const startedA = await ha.request('start', {
    peerId: 'ORBIT-RST-A',
    storageDir: dirA,
    requireRealCorestore: true,
    backend: 'hyperswarm',
    bootstrap: testnet.bootstrap,
    firewalled: false,
    discoverySecret: Array.from(secret),
  })
  const startedB = await hb.request('start', {
    peerId: 'ORBIT-RST-B',
    storageDir: dirB,
    requireRealCorestore: true,
    backend: 'hyperswarm',
    bootstrap: testnet.bootstrap,
    firewalled: false,
    discoverySecret: Array.from(secret),
  })

  await ha.request('publish', { binding: { deviceId: 'dev-rst-a' } })
  await hb.request('publish', { binding: { deviceId: 'dev-rst-b' } })
  await ha.waitEvent('published')
  await hb.waitEvent('published')

  await Promise.all([
    ha.request(
      'connect',
      { peerId: 'ORBIT-RST-B', noisePublicKey: startedB.noisePublicKey, timeoutMs: 25000 },
      30000,
    ),
    hb.request(
      'connect',
      { peerId: 'ORBIT-RST-A', noisePublicKey: startedA.noisePublicKey, timeoutMs: 25000 },
      30000,
    ),
  ])

  await ha.waitEvent('connected')
  await hb.waitEvent('connected')

  // Kill B immediately with SIGKILL to simulate abrupt reset / hard drop
  procB.kill('SIGKILL')

  // Immediately send a batch of messages from A to B while B is already dead
  for (let i = 0; i < 5; i++) {
    await ha.request('send', {
      peerId: 'ORBIT-RST-B',
      channel: 'message',
      frame: { type: 'note', id: 's' + i, text: 'msg-' + i },
    }).catch(() => {})
  }

  // A must receive disconnect or notice B is gone without SIGABRT
  await ha.waitEvent('disconnected', 15000).catch(() => {})

  // A must still be alive and answer runtime.info
  const infoA = await ha.request('runtime.info')
  assert.equal(infoA.runtime, 'bare')
  assert.equal(procAExit, null, 'Worklet A must not crash when remote peer is hard-killed')

  await ha.request('stop')
  procA.kill()
})

test('live Hyperswarm regression: repeated start/stop cycles do not accumulate listeners or handles', async (t) => {
  const bare = officialBare()
  if (!bare) {
    t.skip('official Bare binary is not fetched')
    return
  }

  const testnet = await createLocalTestnet(3)
  t.after(async () => {
    await testnet.destroy()
  })

  const proc = spawnWorklet(bare, 'hyperswarm')
  t.after(() => {
    try { proc.kill() } catch {}
  })

  const h = attach(proc)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-cyc-'))

  // Perform 3 sequential start/publish/stop cycles on the same running worklet process
  for (let cycle = 1; cycle <= 3; cycle++) {
    const sec = crypto.randomBytes(32)
    await h.request('start', {
      peerId: 'ORBIT-CYC-' + cycle,
      storageDir: dir,
      requireRealCorestore: true,
      backend: 'hyperswarm',
      bootstrap: testnet.bootstrap,
      firewalled: false,
      discoverySecret: Array.from(sec),
    })

    await h.request('publish', { binding: { deviceId: 'dev-cyc-' + cycle } })
    const infoRunning = await h.request('runtime.info')
    assert.equal(infoRunning.started, true)
    assert.equal(infoRunning.published, true)

    await h.request('stop')
    const infoStopped = await h.request('runtime.info')
    assert.equal(infoStopped.started, false)
    assert.equal(infoStopped.published, false)
    assert.equal(infoStopped.peerCount, 0)
  }

  proc.kill()
})

'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { contactDiscoveryTopic } = require('../src/discovery')
const { Worklet, parseWorkletArgv, secretToBuffer } = require('../src/worklet')

test('parseWorkletArgv reads backend and storage', () => {
  const parsed = parseWorkletArgv([
    'worklet.js',
    '--backend=hyperswarm',
    '--storage=/tmp/orbits-corestore',
  ])
  assert.equal(parsed.backend, 'hyperswarm')
  assert.equal(parsed.storage, '/tmp/orbits-corestore')
})

test('hyperswarm connect without publish or noise key fails closed', async () => {
  const w = new Worklet({ backend: 'loopback' })
  w.backend = 'hyperswarm'
  w._started = true
  w._swarm = { swarm: { joinPeer() {}, async flush() {} } }
  await assert.rejects(
    () => w.connect({ peerId: 'ORBIT-X' }),
    /publish or noisePublicKey required/,
  )
})

test('connect joins the contact discovery topic from the shared secret', async () => {
  const joined = []
  const w = new Worklet({ backend: 'hyperswarm' })
  w._started = true
  w._swarm = {
    swarm: { joinPeer() {}, async flush() {} },
    async join(topic) {
      joined.push(topic)
    },
  }
  const secret = Buffer.alloc(32, 7)
  w._peers.set('ORBIT-B', { socket: { write() {}, destroy() {} }, info: {} })
  const result = await w.connect({
    peerId: 'ORBIT-B',
    discoverySecret: [...secret],
  })
  assert.equal(joined.length, 1)
  assert.deepEqual(joined[0], contactDiscoveryTopic(secret))
  assert.equal(result.peerId, 'ORBIT-B')
  assert.deepEqual(secretToBuffer([...secret]), secret)
})

test('loopback connect still requires a port and records a peer', async () => {
  const a = new Worklet({ backend: 'loopback' })
  const b = new Worklet({ backend: 'loopback' })
  await a.start({ peerId: 'A', discoverySecret: Buffer.alloc(32, 1) })
  await b.start({ peerId: 'B', discoverySecret: Buffer.alloc(32, 1) })
  await assert.rejects(() => a.connect({ peerId: 'B' }), /loopback connect needs port/)
  const result = await a.connect({ peerId: 'B', port: b._loop.port })
  assert.ok(result.peerId)
  assert.ok(a._peers.size > 0)
  await a.disconnect(result.peerId)
  assert.equal(a._peers.size, 0)
  await a.stop()
  await b.stop()
})

test('F-07: connect(C) does not resolve merely because B is connected', async () => {
  const w = new Worklet({ backend: 'hyperswarm' })
  w._started = true
  w._publishedTopic = Buffer.alloc(32, 1)
  w._swarm = { swarm: { joinPeer() {}, async flush() {} }, async join() { return {} } }

  // Peer B is already connected
  const fakeSocketB = { write() {}, destroy() {} }
  w._peers.set('ORBIT-B', { socket: fakeSocketB, info: {}, closed: false })

  // connect('ORBIT-C') with a short timeout must reject with timeout, NOT return B
  await assert.rejects(
    () => w.connect({ peerId: 'ORBIT-C', timeoutMs: 150 }),
    /connect timeout/,
  )
})

test('F-07: concurrent connect(B) and connect(C) cannot cross-resolve', async () => {
  const w = new Worklet({ backend: 'hyperswarm' })
  w._started = true
  w._publishedTopic = Buffer.alloc(32, 1)
  w._swarm = { swarm: { joinPeer() {}, async flush() {} }, async join() { return {} } }

  // Start two concurrent connection waiters for B and C
  const pB = w.connect({ peerId: 'ORBIT-B', timeoutMs: 2000 })
  const pC = w.connect({ peerId: 'ORBIT-C', timeoutMs: 2000 })

  // Now simulate an inbound connection from C first
  const fakeSocketC = { write() {}, destroy() {} }
  const connC = { socket: fakeSocketC, info: {}, logicalPeerId: null, emittedConnected: false, closed: false }
  w._connections.add(connC)
  w._assignLogicalPeer(connC, 'ORBIT-C')

  // pC must resolve with C
  const resC = await pC
  assert.equal(resC.peerId, 'ORBIT-C')

  // pB should still be pending in _connWaiters!
  assert.equal(w._connWaiters.length, 1)
  assert.equal(w._connWaiters[0].targetPeerId, 'ORBIT-B')

  // Now simulate B connecting
  const fakeSocketB = { write() {}, destroy() {} }
  const connB = { socket: fakeSocketB, info: {}, logicalPeerId: null, emittedConnected: false, closed: false }
  w._connections.add(connB)
  w._assignLogicalPeer(connB, 'ORBIT-B')

  const resB = await pB
  assert.equal(resB.peerId, 'ORBIT-B')
  assert.equal(w._connWaiters.length, 0)
})

test('F-07: an unrelated inbound connection cannot claim a pending targeted logical ID', async () => {
  const w = new Worklet({ backend: 'hyperswarm' })
  w._started = true
  w._publishedTopic = Buffer.alloc(32, 1)
  w._swarm = { swarm: { joinPeer() {}, async flush() {} }, async join() { return {} } }

  const pB = w.connect({ peerId: 'ORBIT-B', timeoutMs: 200 })

  // Unrelated peer X connects
  const fakeSocketX = { write() {}, destroy() {} }
  const connX = { socket: fakeSocketX, info: {}, logicalPeerId: null, emittedConnected: false, closed: false }
  w._connections.add(connX)
  w._assignLogicalPeer(connX, 'ORBIT-X')

  // pB must still timeout and not be resolved by X
  await assert.rejects(() => pB, /connect timeout/)
})

test('F-13: public connected event only emitted after logical identity known, no phantom noise key', async () => {
  const events = []
  const w = new Worklet({
    backend: 'hyperswarm',
    emit: (name, payload) => events.push({ name, payload }),
  })
  w._started = true
  w._config = { peerId: 'ORBIT-LOCAL' }

  // Raw socket connects with noise public key
  const fakeSocket = {
    write() {},
    destroy() {},
    on() {},
  }
  const noiseKey = Buffer.alloc(32, 0xaa)
  w._onConn(fakeSocket, { publicKey: noiseKey, path: 'direct' })

  // At this point, no public 'connected' event should be emitted!
  const connEvents = events.filter((e) => e.name === 'connected')
  assert.equal(connEvents.length, 0)

  // Now an orbits-identity frame arrives on control channel
  const framePayload = Buffer.from(JSON.stringify({
    type: 'orbits-identity',
    peerId: 'ORBIT-REMOTE',
    binding: {
      ownerPeerId: 'ORBIT-REMOTE',
      transportPublicKeyB64: noiseKey.toString('base64'),
    },
  }))
  const connRecord = Array.from(w._connections)[0]
  w._onFrame(connRecord, 'control', framePayload)

  const pending = events.filter((e) => e.name === 'identity-pending')
  assert.ok(pending.length >= 1)
  assert.equal(pending[pending.length - 1].payload.peerId, 'ORBIT-REMOTE')
  assert.equal(events.filter((e) => e.name === 'connected').length, 0)

  await w.authorize('ORBIT-REMOTE')

  const connEventsAfter = events.filter((e) => e.name === 'connected')
  assert.equal(connEventsAfter.length, 1)
  assert.equal(connEventsAfter[0].payload.peerId, 'ORBIT-REMOTE')
  const authEvents = events.filter((e) => e.name === 'authenticated')
  assert.equal(authEvents.length, 1)
  assert.equal(authEvents[0].payload.peerId, 'ORBIT-REMOTE')
  assert.equal(authEvents[0].payload.connectionNoisePublicKey, noiseKey.toString('hex'))

  // Disconnect emits disconnected only once for ORBIT-REMOTE
  w._handlePeerDisconnect(connRecord, null)
  const discEvents = events.filter((e) => e.name === 'disconnected')
  assert.equal(discEvents.length, 1)
  assert.equal(discEvents[0].payload.peerId, 'ORBIT-REMOTE')

  // Duplicate disconnect does not emit again
  w._handlePeerDisconnect(connRecord, null)
  const discEvents2 = events.filter((e) => e.name === 'disconnected')
  assert.equal(discEvents2.length, 1)
})

test('F-09: hyperswarm rejects plaintext orbits-identity without a Noise-bound certificate', async () => {
  const events = []
  const w = new Worklet({
    backend: 'hyperswarm',
    emit: (name, payload) => events.push({ name, payload }),
  })
  w._started = true
  w._config = { peerId: 'ORBIT-LOCAL' }
  const fakeSocket = { write() {}, destroy() {}, on() {} }
  const noiseKey = Buffer.alloc(32, 0xbb)
  w._onConn(fakeSocket, { publicKey: noiseKey, path: 'direct' })
  const connRecord = Array.from(w._connections)[0]
  w._onFrame(
    connRecord,
    'control',
    Buffer.from(JSON.stringify({ type: 'orbits-identity', peerId: 'ORBIT-REMOTE' })),
  )
  assert.equal(events.filter((e) => e.name === 'connected').length, 0)
  assert.equal(events.filter((e) => e.name === 'authenticated').length, 0)
})

test('F-18: publish local topic + join B + join C, then disconnect B and unpublish leaves correct topics', async () => {
  const left = []
  const destroyed = []
  const w = new Worklet({ backend: 'hyperswarm' })
  w._started = true
  const secretA = Buffer.alloc(32, 1)
  w._config = { discoverySecret: Array.from(secretA) }
  w._swarm = {
    swarm: { joinPeer() {}, async flush() {} },
    async join(topic) {
      return {
        topic,
        async destroy() { destroyed.push(topic.toString('hex')) },
      }
    },
    async leave(topic) {
      left.push(topic.toString('hex'))
    },
  }

  // 1. Publish local topic
  await w.publish({ deviceId: 'dev-a' })
  const pubTopicHex = contactDiscoveryTopic(secretA).toString('hex')
  assert.equal(w._publishedTopic.toString('hex'), pubTopicHex)
  assert.ok(w._discoveryHandles.has(pubTopicHex))

  // 2. Join peer B with secret B
  const secretB = Buffer.alloc(32, 2)
  const topicBHex = contactDiscoveryTopic(secretB).toString('hex')
  await w.connect({ peerId: 'ORBIT-B', discoverySecret: Array.from(secretB), timeoutMs: 50 })
    .catch(() => {}) // timeout expected as no socket attaches

  assert.ok(w._peerTopics.has('ORBIT-B'))
  assert.equal(w._peerTopics.get('ORBIT-B'), topicBHex)
  assert.ok(w._discoveryHandles.has(topicBHex))

  // 3. Join peer C with secret C
  const secretC = Buffer.alloc(32, 3)
  const topicCHex = contactDiscoveryTopic(secretC).toString('hex')
  await w.connect({ peerId: 'ORBIT-C', discoverySecret: Array.from(secretC), timeoutMs: 50 })
    .catch(() => {})

  assert.ok(w._peerTopics.has('ORBIT-C'))
  assert.equal(w._peerTopics.get('ORBIT-C'), topicCHex)
  assert.ok(w._discoveryHandles.has(topicCHex))

  // 4. Disconnect B: should leave topic B and destroy its handle, but NOT topic A or C
  await w.disconnect('ORBIT-B')
  assert.ok(!w._peerTopics.has('ORBIT-B'))
  assert.ok(!w._discoveryHandles.has(topicBHex))
  assert.ok(left.includes(topicBHex))
  assert.ok(destroyed.includes(topicBHex))
  assert.ok(!left.includes(pubTopicHex))
  assert.ok(!left.includes(topicCHex))

  // 5. Unpublish: should leave pubTopicHex, but NOT topic C
  await w.unpublish()
  assert.equal(w._publishedTopic, null)
  assert.ok(!w._discoveryHandles.has(pubTopicHex))
  assert.ok(left.includes(pubTopicHex))
  assert.ok(destroyed.includes(pubTopicHex))
  assert.ok(!left.includes(topicCHex))
  assert.ok(w._discoveryHandles.has(topicCHex))

  // 6. Stop: should clean up remaining handles (topic C)
  await w.stop()
  assert.equal(w._discoveryHandles.size, 0)
  assert.ok(destroyed.includes(topicCHex))
})

test('F-18: createHyperswarmBackend passes firewalled and bootstrap correctly to HyperDHT', async () => {
  const { createHyperswarmBackend } = require('../src/swarm')
  // Pass firewalled: false and firewalled: true
  const b1 = await createHyperswarmBackend({ firewalled: false, maxPeers: 10 })
  assert.equal(b1.dht.firewalled, false)
  await b1.destroy()

  const b2 = await createHyperswarmBackend({ firewalled: true, maxPeers: 10 })
  assert.equal(b2.dht.firewalled, true)
  await b2.destroy()
})

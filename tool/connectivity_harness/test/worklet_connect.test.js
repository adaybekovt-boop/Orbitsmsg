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

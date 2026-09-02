'use strict'

/**
 * Hyperswarm connections are keyed by Noise public key until Dart
 * `connect({ peerId, noisePublicKey })` maps them to the contact ORBIT
 * id. Discovery stays HASH("orbits-contact-discovery-v1" || secret).
 */

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { createHash } = require('node:crypto')
const { Worklet, handleIpcRequest } = require('../src/worklet')

test('connect maps Noise public key to ORBIT peerId, never HASH(peerId)', () => {
  const w = new Worklet({ backend: 'loopback' })
  const noise = 'ab'.repeat(32)
  w._rememberOrbitPeer('ORBIT-AAAAAAAAAAAAAAAA', noise)
  const resolved = w._resolvePeerId({
    publicKey: Buffer.from(noise, 'hex'),
    id: 'noise-hex-should-not-win',
  })
  assert.equal(resolved, 'ORBIT-AAAAAAAAAAAAAAAA')
  const hashedPeerId = createHash('sha256')
    .update('ORBIT-AAAAAAAAAAAAAAAA')
    .digest('hex')
  assert.notEqual(resolved, hashedPeerId)
  assert.notEqual(resolved, noise)
  w._rememberOrbitPeer('ORBIT-BAD://x', noise)
  assert.equal(
    w._resolvePeerId({ publicKey: Buffer.from(noise, 'hex') }),
    'ORBIT-AAAAAAAAAAAAAAAA',
  )
})

test('loopback info.id still wins when no Noise map exists', () => {
  const w = new Worklet({ backend: 'loopback' })
  assert.equal(
    w._resolvePeerId({
      id: 'outbound:9',
      publicKey: Buffer.alloc(32, 1),
    }),
    'outbound:9',
  )
})

test('rememberPeer maps Noise to ORBIT without joinPeer', () => {
  const w = new Worklet({ backend: 'loopback' })
  const noise = 'cd'.repeat(32)
  w.rememberPeer({
    peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
    noisePublicKey: noise,
    discoverySecret: 'must-not-be-used',
  })
  assert.equal(
    w._resolvePeerId({ publicKey: Buffer.from(noise, 'hex') }),
    'ORBIT-BBBBBBBBBBBBBBBB',
  )
  assert.equal(w._swarm, null)
  assert.equal(w._topic, null)
})

test('IPC disconnect removes peer and emits disconnected once', async () => {
  const worklet = new Worklet({ backend: 'loopback' })
  let destroyed = 0
  worklet._peers.set('ORBIT-AA', {
    peerId: 'ORBIT-AA',
    socket: {
      destroy() {
        destroyed += 1
      },
      end() {
        destroyed += 1
      },
    },
  })

  const urlResult = await handleIpcRequest(worklet, {
    method: 'disconnect',
    params: { peerId: 'https://evil' },
  })
  assert.deepEqual(urlResult, {})
  assert.equal(worklet._peers.has('ORBIT-AA'), true)
  assert.equal(
    worklet.events.filter((e) => e.name === 'disconnected').length,
    0,
  )
  assert.equal(destroyed, 0)

  const result = await handleIpcRequest(worklet, {
    method: 'disconnect',
    params: { peerId: 'ORBIT-AA' },
  })
  assert.deepEqual(result, {})
  assert.equal(worklet._peers.has('ORBIT-AA'), false)
  const disconnected = worklet.events.filter((e) => e.name === 'disconnected')
  assert.equal(disconnected.length, 1)
  assert.deepEqual(disconnected[0].payload, { peerId: 'ORBIT-AA' })
  assert.equal(destroyed, 1)
})

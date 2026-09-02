'use strict'

/**
 * Hyperswarm connections are keyed by Noise public key until Dart
 * `connect({ peerId, noisePublicKey })` maps them to the contact ORBIT
 * id. Discovery stays HASH("orbits-contact-discovery-v1" || secret).
 */

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { createHash } = require('node:crypto')
const { Worklet } = require('../src/worklet')

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

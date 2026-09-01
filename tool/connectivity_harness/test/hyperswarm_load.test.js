'use strict'

/**
 * Local-bootstrap Hyperswarm only. Never joins the public DHT.
 * Skips the live pair when hyperswarm/hyperdht are not installed
 * (CI historically ran `node --test` without `npm ci`).
 * UDX sockets do not always unref; the harness test script uses
 * `--test-force-exit` so teardown cannot hang the runner.
 */

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { createHash } = require('node:crypto')
const { Worklet } = require('../src/worklet')
const { createHyperswarmBackend, createLocalBootstrap } = require('../src/swarm')
const { contactDiscoveryTopic } = require('../src/discovery')

function hyperswarmAvailable() {
  try {
    require('hyperswarm')
    require('hyperdht')
    return true
  } catch {
    return false
  }
}

const skipLoad = hyperswarmAvailable() ? false : 'hyperswarm/hyperdht not installed'

test('worklet hyperswarm start refuses missing bootstrap', async () => {
  const w = new Worklet({ backend: 'hyperswarm' })
  await assert.rejects(() => w.start({ peerId: 'A' }), /refusing public DHT/)
  await assert.rejects(
    () => w.start({ peerId: 'A', bootstrap: [] }),
    /refusing public DHT/,
  )
})


test(
  'two worklets echo over local Hyperswarm bootstrap',
  { skip: skipLoad, timeout: 60000 },
  async (t) => {
    const local = await createLocalBootstrap()
    const bootstrapHost = local.bootstrap[0] && local.bootstrap[0].host
    assert.equal(bootstrapHost, '127.0.0.1')
    const secret = Buffer.alloc(32, 3)
    const topic = contactDiscoveryTopic(secret)
    const a = new Worklet({ backend: 'hyperswarm' })
    const b = new Worklet({ backend: 'hyperswarm' })
    t.after(async () => {
      try {
        await a.stop()
      } catch {
        /* ignore */
      }
      try {
        await b.stop()
      } catch {
        /* ignore */
      }
      try {
        await local.destroy()
      } catch {
        /* ignore */
      }
    })

    function waitConnected(worklet, label) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error(label + ' connect timeout')),
          45000,
        )
        const prev = worklet._emit
        worklet._emit = (name, payload) => {
          prev(name, payload)
          if (name === 'connected') {
            clearTimeout(timer)
            resolve(payload.peerId)
          }
        }
      })
    }

    const aPeer = waitConnected(a, 'A')
    const bPeer = waitConnected(b, 'B')

    await a.start({
      peerId: 'A',
      discoverySecret: secret,
      bootstrap: local.bootstrap,
      seed: Buffer.alloc(32, 7),
    })
    await b.start({
      peerId: 'B',
      discoverySecret: secret,
      bootstrap: local.bootstrap,
      seed: Buffer.alloc(32, 8),
    })
    await a.publish({ deviceId: 'a' })
    await b.publish({ deviceId: 'b' })

    assert.equal(a._topic.toString('hex'), topic.toString('hex'))
    assert.equal(b._topic.toString('hex'), topic.toString('hex'))
    const hashedPeerId = createHash('sha256').update('A').digest('hex')
    assert.notEqual(a._topic.toString('hex'), hashedPeerId)

    assert.equal(a.backend, 'hyperswarm')
    assert.ok(a._swarm)
    assert.ok(b._swarm)
    const aPk = a.noisePublicKeyHex()
    const bPk = b.noisePublicKeyHex()
    assert.equal(aPk.length, 64)
    assert.equal(bPk.length, 64)
    assert.notEqual(aPk, bPk)
    const peerId = await aPeer
    await bPeer

    const got = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('echo timeout')), 10000)
      const prev = a._emit
      a._emit = (name, payload) => {
        prev(name, payload)
        if (name === 'frame' && payload.body && payload.body.type === 'harness-echo-reply') {
          clearTimeout(timer)
          resolve(payload.body.text)
        }
      }
    })
    await a.send(peerId, 'message', {
      type: 'harness-echo',
      id: 'hs',
      text: 'local-swarm',
    })
    assert.equal(await got, 'local-swarm')
  },
)

test('relayThrough skips unsound key lengths', () {
  const { parseRelayThroughKeys } = require('../src/swarm')
  const keys = parseRelayThroughKeys([
    'aa',
    'not-hex',
    'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz',
    Buffer.alloc(16),
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  ])
  assert.equal(keys.length, 1)
  assert.equal(keys[0].length, 32)
})

test(
  'two worklets connect with local relayThrough keys wired',
  { skip: skipLoad, timeout: 60000 },
  async (t) => {
    const local = await createLocalBootstrap(5)
    const bootstrapHost = local.bootstrap[0] && local.bootstrap[0].host
    assert.equal(bootstrapHost, '127.0.0.1')
    assert.ok(local.nodes.length >= 5)
    const relayNode = local.nodes[3]
    const relayKey = Buffer.from(relayNode.defaultKeyPair.publicKey).toString('hex')
    assert.equal(relayKey.length, 64)

    const secret = Buffer.alloc(32, 4)
    const a = new Worklet({ backend: 'hyperswarm' })
    const b = new Worklet({ backend: 'hyperswarm' })
    t.after(async () => {
      try {
        await a.stop()
      } catch {
        /* ignore */
      }
      try {
        await b.stop()
      } catch {
        /* ignore */
      }
      try {
        await local.destroy()
      } catch {
        /* ignore */
      }
    })

    function waitConnected(worklet, label) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error(label + ' connect timeout')),
          45000,
        )
        const prev = worklet._emit
        worklet._emit = (name, payload) => {
          prev(name, payload)
          if (name === 'connected') {
            clearTimeout(timer)
            resolve(payload)
          }
        }
      })
    }

    const aPeer = waitConnected(a, 'A')
    const bPeer = waitConnected(b, 'B')

    await a.start({
      peerId: 'A',
      discoverySecret: secret,
      bootstrap: local.bootstrap,
      seed: Buffer.alloc(32, 9),
      relayForced: true,
      relayThrough: [relayKey],
    })
    await b.start({
      peerId: 'B',
      discoverySecret: secret,
      bootstrap: local.bootstrap,
      seed: Buffer.alloc(32, 10),
      relayForced: true,
      relayThrough: [relayKey],
    })
    assert.equal(a._swarm.relayThroughCount, 1)
    assert.equal(b._swarm.relayThroughCount, 1)
    await a.publish({ deviceId: 'a' })
    await b.publish({ deviceId: 'b' })

    const aInfo = await aPeer
    await bPeer
    assert.ok(aInfo.peerId)
    // Loopback often still reports path: direct. This asserts wiring, not NAT.

    const got = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('echo timeout')), 10000)
      const prev = a._emit
      a._emit = (name, payload) => {
        prev(name, payload)
        if (name === 'frame' && payload.body && payload.body.type === 'harness-echo-reply') {
          clearTimeout(timer)
          resolve(payload.body.text)
        }
      }
    })
    await a.send(aInfo.peerId, 'message', {
      type: 'harness-echo',
      id: 'hs-relay',
      text: 'local-relay-through',
    })
    assert.equal(await got, 'local-relay-through')
  },
)

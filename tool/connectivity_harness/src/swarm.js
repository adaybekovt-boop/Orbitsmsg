'use strict'

/**
 * Hyperswarm backend. Optional — loopback is the CI default so Windows
 * unit tests do not require UDP holepunching or a public bootstrap.
 *
 * Production Bare embeds this file and must not fetch remote JS.
 */

async function createHyperswarmBackend(opts = {}) {
  const bootstrap = opts.bootstrap
  if (!Array.isArray(bootstrap) || bootstrap.length === 0) {
    throw new Error(
      'hyperswarm backend requires explicit bootstrap; refusing public DHT default',
    )
  }
  let Hyperswarm
  try {
    Hyperswarm = require('hyperswarm')
  } catch (err) {
    throw new Error('hyperswarm is not installed: ' + err.message)
  }
  const swarmOpts = { bootstrap }
  if (opts.keyPair) swarmOpts.keyPair = opts.keyPair
  if (opts.seed) {
    swarmOpts.seed = Buffer.isBuffer(opts.seed) ? opts.seed : Buffer.from(opts.seed)
  }
  if (opts.firewall) swarmOpts.firewall = opts.firewall
  const keys = parseRelayThroughKeys(opts.relayThrough)
  if (keys.length > 0) {
    swarmOpts.relayThrough = (force) => {
      if (opts.relayForced || force) {
        return keys[Math.floor(Math.random() * keys.length)]
      }
      return null
    }
  }
  const swarm = new Hyperswarm(swarmOpts)
  return {
    swarm,
    relayThroughCount: keys.length,
    async join(topic) {
      const discovery = swarm.join(topic, { server: true, client: true })
      await discovery.flushed()
      return discovery
    },
    async leave(topic) {
      await swarm.leave(topic)
    },
    async suspend() {
      await swarm.suspend()
    },
    async resume() {
      await swarm.resume()
    },
    async refresh() {
      for (const topic of swarm.topics ? swarm.topics.keys() : []) {
        const st = swarm.status(topic)
        if (st) await st.refresh({ client: true, server: true })
      }
    },
    async destroy() {
      try {
        for (const conn of swarm.connections) {
          try {
            conn.destroy()
          } catch {
            /* ignore */
          }
        }
      } catch {
        /* ignore */
      }
      try {
        await swarm.dht.destroy({ force: true })
      } catch {
        /* ignore */
      }
    },
    onConnection(fn) {
      swarm.on('connection', (conn, info) => {
        conn.on('error', () => {})
        const relayed = Boolean(info && (info.relayed || info.client === false && conn.rawStream && conn.rawStream.relayed))
        fn(conn, {
          publicKey: info.publicKey,
          path: relayed ? 'relay' : 'direct',
          topics: info.topics || [],
        })
      })
    },
  }
}

function parseRelayThroughKeys(raw) {
  const keys = []
  if (!Array.isArray(raw)) return keys
  for (const k of raw) {
    const buf = parseRelayThroughKey(k)
    if (buf) keys.push(buf)
  }
  return keys
}

function parseRelayThroughKey(k) {
  if (!k) return null
  if (Buffer.isBuffer(k)) return k.length === 32 ? k : null
  const s = String(k).trim()
  if (!/^[0-9a-fA-F]{64}$/.test(s)) return null
  const buf = Buffer.from(s, 'hex')
  return buf.length === 32 ? buf : null
}

async function createLocalBootstrap(size = 3) {
  let createTestnet
  try {
    createTestnet = require('hyperdht/testnet')
  } catch (err) {
    throw new Error('hyperdht is not installed: ' + err.message)
  }
  const n = Number(size) > 0 ? Number(size) : 3
  const testnet = await createTestnet(n, { host: '127.0.0.1' })
  return {
    node: testnet,
    bootstrap: testnet.bootstrap,
    nodes: testnet.nodes || [],
    async destroy() {
      const nodes = testnet.nodes || []
      for (let i = nodes.length - 1; i >= 0; i--) {
        try {
          await nodes[i].destroy({ force: true })
        } catch {
          /* ignore */
        }
      }
    },
  }
}

module.exports = {
  createHyperswarmBackend,
  createLocalBootstrap,
  parseRelayThroughKeys,
}

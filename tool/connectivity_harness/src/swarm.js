'use strict'

/**
 * Hyperswarm backend. Optional — loopback is the CI default so Windows
 * unit tests do not require UDP holepunching or a public bootstrap.
 *
 * Production Bare embeds this file and must not fetch remote JS.
 */

async function createHyperswarmBackend(opts = {}) {
  let Hyperswarm
  try {
    Hyperswarm = require('hyperswarm')
  } catch (err) {
    throw new Error('hyperswarm is not installed: ' + err.message)
  }
  let dht = opts.dht
  let ownedDht = false
  if (!dht) {
    const DHT = require('hyperdht')
    const dhtOpts = {}
    if (opts.bootstrap) dhtOpts.bootstrap = opts.bootstrap
    if (opts.firewalled !== undefined) dhtOpts.firewalled = Boolean(opts.firewalled)
    if (opts.port) dhtOpts.port = opts.port
    if (opts.host) dhtOpts.host = opts.host
    dht = new DHT(dhtOpts)
    await dht.ready()
    ownedDht = true
  }
  // Note: Hyperswarm constructor does not support a firewalled option (it belongs to HyperDHT).
  // Passing firewalled directly to Hyperswarm was dead configuration.
  const swarm = new Hyperswarm({
    keyPair: opts.keyPair,
    seed: opts.seed,
    firewall: opts.firewall || (() => false),
    maxPeers: opts.maxPeers,
    dht,
  })
  return {
    swarm,
    dht,
    async join(topic) {
      const discovery = swarm.join(topic, { server: true, client: true })
      try {
        await Promise.race([
          swarm.flush(),
          new Promise((_, reject) =>
            setTimeout(() => reject(new Error('flush timeout')), 15_000),
          ),
        ])
      } catch {
        // Topic is already registered. Announce continues in the background.
      }
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
      const keys = swarm.topics
        ? swarm.topics.keys()
        : swarm._discovery
          ? swarm._discovery.keys()
          : []
      for (const topic of keys) {
        const st = swarm.status(topic)
        if (st) await st.refresh({ client: true, server: true })
      }
    },
    async destroy() {
      await swarm.destroy()
      if (ownedDht && dht) await dht.destroy()
    },
    onConnection(fn) {
      swarm.on('connection', (conn, info) => {
        const relayed = Boolean(
          info &&
            (info.relayed ||
              (info.client === false && conn.rawStream && conn.rawStream.relayed)),
        )
        fn(conn, {
          publicKey: info.publicKey,
          path: relayed ? 'relay' : 'direct',
          topics: info.topics || [],
        })
      })
    },
  }
}

async function createLocalBootstrap(port) {
  const DHT = require('hyperdht')
  const bindPort = port || 0
  let node
  if (bindPort && typeof DHT.bootstrapper === 'function') {
    node = DHT.bootstrapper(bindPort, '127.0.0.1')
  } else {
    node = new DHT({ ephemeral: false, bootstrap: [], host: '127.0.0.1', firewalled: false })
  }
  await node.ready()
  const addr = node.address()
  return {
    node,
    bootstrap: [{ host: '127.0.0.1', port: addr.port }],
    async destroy() {
      await node.destroy()
    },
  }
}

async function createLocalTestnet(size = 3, opts = {}) {
  let testnet
  try {
    testnet = require('hyperdht/testnet')
  } catch (err) {
    throw new Error('hyperdht/testnet is not available: ' + err.message)
  }
  const tn = await testnet(size, { host: '127.0.0.1', ...opts })
  return {
    nodes: tn.nodes,
    bootstrap: tn.bootstrap,
    async destroy() {
      await tn.destroy()
    },
  }
}

module.exports = { createHyperswarmBackend, createLocalBootstrap, createLocalTestnet }

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
  const swarm = new Hyperswarm({
    bootstrap: opts.bootstrap,
    keyPair: opts.keyPair,
    seed: opts.seed,
    firewall: opts.firewall,
  })
  return {
    swarm,
    async join(topic) {
      const discovery = swarm.join(topic, { server: true, client: true })
      await swarm.flush()
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
      await swarm.destroy()
    },
    onConnection(fn) {
      swarm.on('connection', (conn, info) => {
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

async function createLocalBootstrap() {
  const DHT = require('hyperdht')
  const node = new DHT({ ephemeral: true, bootstrap: [] })
  await node.ready()
  const { host, port } = node.address()
  return {
    node,
    bootstrap: [{ host: host || '127.0.0.1', port }],
    async destroy() {
      await node.destroy()
    },
  }
}

module.exports = { createHyperswarmBackend, createLocalBootstrap }

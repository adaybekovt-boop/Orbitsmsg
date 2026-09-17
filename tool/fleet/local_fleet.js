'use strict'

/**
 * Loopback fleet for CI. Not a public deployment.
 * 3 bootstrap + 2 relay + 2 storage.
 *
 * Bootstrap is a local HyperDHT testnet when `hyperdht` is installed
 * next to the connectivity harness. HTTP health ports are never used as
 * HyperDHT addresses. Extra testnet nodes (4 and 5) are relay rows with
 * DHT public keys for Hyperswarm `relayThrough`. Without hyperdht,
 * relays stay HTTP health. Storage is the blind HTTP mailbox. This is
 * not a public fleet.
 */

const http = require('node:http')
const path = require('node:path')
const { createServer: createStorage } = require('../storage_peer/server.js')

function healthServer(role, id) {
  return http.createServer((req, res) => {
    if (req.method === 'GET' && (req.url === '/health' || req.url === '/')) {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ ok: true, role, id, plaintext: false }))
      return
    }
    res.writeHead(404)
    res.end()
  })
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port))
  })
}

function loadHyperDhtTestnet() {
  const candidates = [
    'hyperdht/testnet',
    path.join(__dirname, '../connectivity_harness/node_modules/hyperdht/testnet'),
  ]
  for (const id of candidates) {
    try {
      return require(id)
    } catch {
      /* try next */
    }
  }
  return null
}

function dhtPublicKeyHex(node) {
  const pk =
    (node && node.defaultKeyPair && node.defaultKeyPair.publicKey) ||
    (node && node._keyPair && node._keyPair.publicKey)
  if (!pk) return ''
  const hex = Buffer.from(pk).toString('hex')
  return hex.length === 64 ? hex : ''
}

function dhtListenPort(node, row) {
  if (row && row.port) return row.port
  try {
    const addr = node && typeof node.address === 'function' ? node.address() : null
    return addr && addr.port ? addr.port : 0
  } catch {
    return 0
  }
}

async function startLocalDht(count = 5) {
  const createTestnet = loadHyperDhtTestnet()
  if (!createTestnet) return null
  const testnet = await createTestnet(count, { host: '127.0.0.1' })
  return testnet
}

async function destroyTestnet(testnet) {
  if (!testnet) return
  const nodes = testnet.nodes || []
  for (let i = nodes.length - 1; i >= 0; i--) {
    try {
      await nodes[i].destroy({ force: true })
    } catch {
      /* ignore */
    }
  }
}

async function startLocalFleet(opts = {}) {
  const testnet = opts.skipDht ? null : await startLocalDht(5)
  const bootstrapHealth = [
    healthServer('bootstrap', 'b-ca'),
    healthServer('bootstrap', 'b-eu'),
    healthServer('bootstrap', 'b-spare'),
  ]
  const relay = [healthServer('relay', 'r1'), healthServer('relay', 'r2')]
  const storage = [
    createStorage({ token: opts.token || 'local-mailbox' }),
    createStorage({ token: opts.token || 'local-mailbox' }),
  ]
  const peers = []
  const dhtRows = Array.isArray(testnet && testnet.bootstrap) ? testnet.bootstrap : []
  for (let i = 0; i < bootstrapHealth.length; i++) {
    const healthPort = await listen(bootstrapHealth[i])
    const dht = dhtRows[i] || dhtRows[0]
    if (dht && dht.port) {
      peers.push({
        kind: 'bootstrap',
        protocol: 'hyperdht',
        host: dht.host || '127.0.0.1',
        port: dht.port,
        healthPort,
        server: bootstrapHealth[i],
      })
    } else {
      peers.push({
        kind: 'bootstrap',
        protocol: 'http',
        host: '127.0.0.1',
        port: healthPort,
        healthPort,
        server: bootstrapHealth[i],
      })
    }
  }
  const dhtNodes = Array.isArray(testnet && testnet.nodes) ? testnet.nodes : []
  for (let i = 0; i < relay.length; i++) {
    const s = relay[i]
    const healthPort = await listen(s)
    const node = dhtNodes[bootstrapHealth.length + i]
    const dht = dhtRows[bootstrapHealth.length + i]
    const publicKey = dhtPublicKeyHex(node)
    const port = dhtListenPort(node, dht)
    const host = (dht && dht.host) || '127.0.0.1'
    if (publicKey && port) {
      peers.push({
        kind: 'relay',
        protocol: 'hyperdht',
        host,
        port,
        healthPort,
        publicKey,
        server: s,
      })
    } else {
      peers.push({
        kind: 'relay',
        protocol: 'http',
        host: '127.0.0.1',
        port: healthPort,
        healthPort,
        server: s,
      })
    }
  }
  for (const s of storage) {
    const port = await listen(s)
    peers.push({
      kind: 'storage',
      protocol: 'http',
      host: '127.0.0.1',
      port,
      healthPort: port,
      server: s,
    })
  }
  return {
    peers,
    dht: testnet,
    live: false,
    async close() {
      await Promise.all(
        peers.map((p) => new Promise((resolve) => p.server.close(resolve))),
      )
      await destroyTestnet(testnet)
    },
  }
}

module.exports = {
  startLocalFleet,
  healthServer,
  loadHyperDhtTestnet,
  dhtPublicKeyHex,
}

if (require.main === module) {
  startLocalFleet().then((fleet) => {
    const summary = {}
    for (const p of fleet.peers) {
      summary[p.kind] = (summary[p.kind] || 0) + 1
    }
    process.stdout.write(
      JSON.stringify({
        live: false,
        counts: summary,
        dht: Boolean(fleet.dht),
        peers: fleet.peers.map((p) => ({
          kind: p.kind,
          protocol: p.protocol,
          port: p.port,
          healthPort: p.healthPort,
        })),
      }) + '\n',
    )
    return fleet.close()
  })
}

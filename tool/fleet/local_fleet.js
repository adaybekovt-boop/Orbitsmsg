'use strict'

/**
 * Loopback fleet for CI. Not a public deployment.
 * 3 bootstrap + 2 relay + 2 storage health servers.
 */

const http = require('node:http')
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

async function startLocalFleet(opts = {}) {
  const bootstrap = [
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
  for (const s of bootstrap) {
    peers.push({ kind: 'bootstrap', port: await listen(s), server: s })
  }
  for (const s of relay) {
    peers.push({ kind: 'relay', port: await listen(s), server: s })
  }
  for (const s of storage) {
    peers.push({ kind: 'storage', port: await listen(s), server: s })
  }
  return {
    peers,
    async close() {
      await Promise.all(
        peers.map((p) => new Promise((resolve) => p.server.close(resolve))),
      )
    },
  }
}

module.exports = { startLocalFleet, healthServer }

if (require.main === module) {
  startLocalFleet().then((fleet) => {
    const summary = {}
    for (const p of fleet.peers) {
      summary[p.kind] = (summary[p.kind] || 0) + 1
    }
    process.stdout.write(JSON.stringify({ live: false, counts: summary, peers: fleet.peers.map((p) => ({ kind: p.kind, port: p.port })) }) + '\n')
  })
}

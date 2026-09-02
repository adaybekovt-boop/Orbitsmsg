'use strict'

/**
 * Canonical unsigned loopback lab fleet. Keep in sync with
 * lab_directory.json via peersToDirectoryRows. Not a public fleet.
 * HTTP rows are health only — Dart must not treat them as HyperDHT.
 */

function labFleet() {
  return {
    live: false,
    peers: [
      {
        kind: 'bootstrap',
        protocol: 'http',
        host: '127.0.0.1',
        port: 49737,
        healthPort: 18001,
      },
      {
        kind: 'bootstrap',
        protocol: 'http',
        host: '127.0.0.1',
        port: 49738,
        healthPort: 18002,
      },
      {
        kind: 'bootstrap',
        protocol: 'http',
        host: '127.0.0.1',
        port: 49739,
        healthPort: 18003,
      },
      {
        kind: 'relay',
        protocol: 'http',
        host: '127.0.0.1',
        port: 49740,
        healthPort: 18004,
      },
      {
        kind: 'relay',
        protocol: 'http',
        host: '127.0.0.1',
        port: 49741,
        healthPort: 18005,
      },
      {
        kind: 'storage',
        protocol: 'http',
        host: '127.0.0.1',
        port: 8787,
        healthPort: 8787,
      },
      {
        kind: 'storage',
        protocol: 'http',
        host: '127.0.0.1',
        port: 8788,
        healthPort: 8788,
      },
    ],
  }
}

function labDirectoryDocument() {
  const { peersToDirectoryRows } = require('./directory.js')
  return {
    issuedAt: 1,
    expiresAt: 10,
    signature: '',
    identityPublicKey: '',
    live: false,
    note: 'Unsigned loopback lab directory from tool/fleet/directory.js. Not a public fleet. kLiveSignedRelayDirectory stays false.',
    peers: peersToDirectoryRows(labFleet()),
  }
}

module.exports = { labFleet, labDirectoryDocument }

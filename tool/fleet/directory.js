'use strict'

/**
 * Map a local loopback fleet to unsigned directory rows.
 * Signing is Dart identity-signing-v1 (see RelayDirectory). This is not
 * a live public directory.
 */

function peersToDirectoryRows(fleet) {
  const regions = { bootstrap: ['ca', 'eu', 'spare'], relay: ['ca', 'eu'], storage: ['ca', 'eu'] }
  const seen = { bootstrap: 0, relay: 0, storage: 0 }
  return fleet.peers.map((p) => {
    const idx = seen[p.kind] || 0
    seen[p.kind] = idx + 1
    const region = (regions[p.kind] || ['lab'])[idx] || 'lab'
    return {
      id: `${p.kind}-${idx + 1}`,
      kind: p.kind,
      host: '127.0.0.1',
      port: p.port,
      region,
      rttMs: idx,
      unsound: false,
      live: false,
    }
  })
}

function meetsFleetMinimum(rows) {
  const n = { bootstrap: 0, relay: 0, storage: 0 }
  for (const r of rows) {
    if (!r.unsound) n[r.kind] = (n[r.kind] || 0) + 1
  }
  return n.bootstrap >= 3 && n.relay >= 2 && n.storage >= 2
}

module.exports = { peersToDirectoryRows, meetsFleetMinimum }

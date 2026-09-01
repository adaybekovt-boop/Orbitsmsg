'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const http = require('node:http')
const { startLocalFleet } = require('./local_fleet.js')

function get(port, path) {
  return new Promise((resolve, reject) => {
    http.get({ hostname: '127.0.0.1', port, path }, (res) => {
      const chunks = []
      res.on('data', (c) => chunks.push(c))
      res.on('end', () =>
        resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }),
      )
    }).on('error', reject)
  })
}

test('local fleet has 3 bootstrap / 2 relay / 2 storage and is not public', async (t) => {
  const fleet = await startLocalFleet()
  t.after(() => fleet.close())
  const counts = { bootstrap: 0, relay: 0, storage: 0 }
  for (const p of fleet.peers) {
    counts[p.kind] += 1
    const res = await get(p.port, '/health')
    assert.equal(res.status, 200)
    const json = JSON.parse(res.body)
    assert.equal(json.ok, true)
    assert.equal(json.plaintext, false)
    assert.equal(json.role, p.kind)
  }
  assert.equal(counts.bootstrap, 3)
  assert.equal(counts.relay, 2)
  assert.equal(counts.storage, 2)
})

test('local fleet maps to unsigned directory rows and is not live', async (t) => {
  const { peersToDirectoryRows, meetsFleetMinimum } = require('./directory.js')
  const fleet = await startLocalFleet()
  t.after(() => fleet.close())
  const rows = peersToDirectoryRows(fleet)
  assert.equal(meetsFleetMinimum(rows), true)
  for (const row of rows) {
    assert.equal(row.live, false)
    assert.equal(row.host, '127.0.0.1')
    assert.equal(row.unsound, false)
  }
})

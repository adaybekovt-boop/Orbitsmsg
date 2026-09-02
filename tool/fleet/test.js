'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const http = require('node:http')
const path = require('node:path')
const { startLocalFleet } = require('./local_fleet.js')
const { labFleet, labDirectoryDocument } = require('./lab_fleet.js')
const { peersToDirectoryRows, meetsFleetMinimum } = require('./directory.js')

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

test('lab_directory.json matches peersToDirectoryRows(labFleet) and is not live', () => {
  const fixturePath = path.join(__dirname, 'lab_directory.json')
  const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'))
  assert.deepEqual(fixture, labDirectoryDocument())
  assert.equal(fixture.live, false)
  assert.equal(fixture.signature, '')
  assert.equal(fixture.identityPublicKey, '')
  const rows = peersToDirectoryRows(labFleet())
  assert.deepEqual(fixture.peers, rows)
  assert.equal(meetsFleetMinimum(rows), true)
  assert.equal(rows.filter((r) => r.kind === 'bootstrap').length, 3)
  assert.equal(rows.filter((r) => r.kind === 'relay').length, 2)
  assert.equal(rows.filter((r) => r.kind === 'storage').length, 2)
  for (const row of rows) {
    assert.equal(row.live, false)
    assert.equal(row.host, '127.0.0.1')
    assert.equal(row.protocol, 'http')
  }
})

test('local fleet has 3 bootstrap / 2 relay / 2 storage and is not public', async (t) => {
  const fleet = await startLocalFleet()
  t.after(() => fleet.close())
  assert.equal(fleet.live, false)
  const counts = { bootstrap: 0, relay: 0, storage: 0 }
  for (const p of fleet.peers) {
    counts[p.kind] += 1
    const healthPort = p.healthPort || p.port
    const res = await get(healthPort, '/health')
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

test('skipDht fleet stays HTTP health including relays', async (t) => {
  const fleet = await startLocalFleet({ skipDht: true })
  t.after(() => fleet.close())
  assert.equal(fleet.dht, null)
  for (const p of fleet.peers) {
    assert.equal(p.protocol, 'http')
    assert.equal(p.publicKey, undefined)
  }
})

test('local fleet maps to unsigned directory rows and is not live', async (t) => {
  const fleet = await startLocalFleet()
  t.after(() => fleet.close())
  const rows = peersToDirectoryRows(fleet)
  assert.equal(meetsFleetMinimum(rows), true)
  for (const row of rows) {
    assert.equal(row.live, false)
    assert.equal(row.host, '127.0.0.1')
    assert.equal(row.unsound, false)
  }
  const bootstrap = rows.filter((r) => r.kind === 'bootstrap')
  assert.equal(bootstrap.length, 3)
  if (fleet.dht) {
    for (const row of bootstrap) {
      assert.equal(row.protocol, 'hyperdht')
      assert.notEqual(row.port, row.healthPort)
    }
  } else {
    for (const row of bootstrap) {
      assert.equal(row.protocol, 'http')
    }
  }
  for (const row of rows.filter((r) => r.kind === 'storage')) {
    assert.equal(row.protocol, 'http')
    assert.equal(row.publicKey, undefined)
  }
  const relays = rows.filter((r) => r.kind === 'relay')
  assert.equal(relays.length, 2)
  if (fleet.dht) {
    for (const row of relays) {
      assert.equal(row.protocol, 'hyperdht')
      assert.equal(row.publicKey.length, 64)
      assert.notEqual(row.port, row.healthPort)
    }
  } else {
    for (const row of relays) {
      assert.equal(row.protocol, 'http')
      assert.equal(row.publicKey, undefined)
    }
  }
})

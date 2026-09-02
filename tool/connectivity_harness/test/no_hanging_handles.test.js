'use strict'

/**
 * After stop(), sockets / servers / worklet timers must be gone.
 * `--test-force-exit` stays on the npm script for leftover Hyperswarm/UDX
 * tests; this file must fail on its own if handles remain.
 */

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { Worklet } = require('../src/worklet')

function tally(kinds) {
  const info = process.getActiveResourcesInfo ? process.getActiveResourcesInfo() : []
  const counts = {}
  for (const t of info) {
    if (kinds && !kinds.has(t)) continue
    counts[t] = (counts[t] || 0) + 1
  }
  return counts
}

function tcpCount(counts) {
  return (counts.TCPWRAP || 0) + (counts.TCPServerWrap || 0) + (counts.TCPSERVERWRAP || 0)
}

test('stop() releases worklet sockets and timers', async () => {
  assert.equal(typeof process.getActiveResourcesInfo, 'function')
  const watch = new Set(['TCPWRAP', 'TCPServerWrap', 'TCPSERVERWRAP', 'Timeout'])
  const before = tally(watch)
  const a = new Worklet({ backend: 'loopback', harnessAuth: 'local' })
  const b = new Worklet({ backend: 'loopback', harnessAuth: 'local' })
  const secret = Buffer.alloc(32, 8)
  await a.start({ peerId: 'A', discoverySecret: secret })
  await b.start({ peerId: 'B', discoverySecret: secret })
  await a.publish({ deviceId: 'a' })
  await b.publish({ deviceId: 'b' })
  await a.connect({ port: b._loop.port })
  const mid = tally(watch)
  assert.ok(tcpCount(mid) > tcpCount(before), 'pair should hold TCP handles while running')
  await a.stop()
  await b.stop()
  await new Promise((resolve) => setImmediate(resolve))
  await new Promise((resolve) => setTimeout(resolve, 25))
  const after = tally(watch)
  assert.ok(
    tcpCount(after) <= tcpCount(before),
    'TCP handles remain after stop(): before=' +
      JSON.stringify(before) +
      ' after=' +
      JSON.stringify(after),
  )
  assert.ok(
    (after.Timeout || 0) <= (before.Timeout || 0) + 2,
    'Timeout handles remain after stop(): before=' +
      (before.Timeout || 0) +
      ' after=' +
      (after.Timeout || 0),
  )
  assert.equal(a._timers.size, 0)
  assert.equal(b._peers.size, 0)
})

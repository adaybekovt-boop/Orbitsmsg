'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const {
  runScenario,
  percentile,
  validateStandResult,
  compareBaseline,
  aggregateReports,
  emptyResult,
  helpText,
  RESULT_VERSION,
  LOCAL_SCENARIOS,
  UNMEASURED,
} = require('../src/stand')

test('percentile helper', () => {
  assert.equal(percentile([1, 2, 3, 4], 50), 2)
  assert.equal(percentile([], 95), UNMEASURED)
})

test('loopback stand records success metrics', async () => {
  const report = await runScenario('loopback', 3)
  assert.equal(report.scenario, 'loopback')
  assert.equal(report.iterations, 3)
  assert.ok(report.connectionSuccessRate >= 0)
  assert.ok('medianMs' in report === false)
  assert.ok('medianConnectMs' in report)
  assert.ok('p95ConnectMs' in report)
  validateStandResult(report)
})

test('result schema keeps unmeasured battery as null', async () => {
  const report = await runScenario('ipv4-only', 1, { seed: 7 })
  assert.equal(report.v, RESULT_VERSION)
  assert.equal(report.battery, null)
  assert.equal(report.hardware, false)
  assert.equal(report.modeled, true)
  assert.notEqual(report.memoryBytes, 0)
  assert.ok(report.memoryBytes > 0)
  validateStandResult(report)
})

test('udp-blocked and relay-forced model relay path', async () => {
  const udp = await runScenario('udp-blocked', 1, { seed: 1 })
  const relay = await runScenario('relay-forced', 1, { seed: 1 })
  assert.equal(udp.relayRatio, 1)
  assert.equal(relay.relayRatio, 1)
  assert.equal(udp.directRatio, 0)
})

test('reconnect and wifi-lte scenarios emit measured-or-null reconnect', async () => {
  const rec = await runScenario('reconnect', 1, { seed: 2 })
  assert.notEqual(rec.reconnectSuccessRate, undefined)
  const lte = await runScenario('wifi-lte', 1, { seed: 2 })
  assert.equal(lte.reconnectSuccessRate, null)
  validateStandResult(rec)
  validateStandResult(lte)
})

test('schema validation rejects missing fields and fake battery', () => {
  assert.throws(() => validateStandResult({ v: RESULT_VERSION }))
  assert.throws(() =>
    validateStandResult(
      emptyResult({
        scenario: 'loopback',
        battery: 100,
        hardware: false,
      }),
    ),
  )
})

test('baseline comparison and aggregation stay honest', async () => {
  const a = await runScenario('loopback', 1, { seed: 3 })
  const b = await runScenario('loopback', 1, { seed: 3 })
  const cmp = compareBaseline(b, a)
  assert.equal(cmp.compared, true)
  const agg = aggregateReports([a, b])
  assert.equal(agg.v, RESULT_VERSION)
  assert.equal(agg.hardware, false)
  assert.ok(helpText().includes('Kazakhstan'))
  assert.ok(LOCAL_SCENARIOS.includes('packet-loss'))
})

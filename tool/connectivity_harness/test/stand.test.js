'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { runScenario, percentile } = require('../src/stand')

test('percentile helper', () => {
  assert.equal(percentile([1, 2, 3, 4], 50), 2)
})

test('loopback stand records success metrics', async () => {
  const report = await runScenario('loopback', 3)
  assert.equal(report.scenario, 'loopback')
  assert.equal(report.iterations, 3)
  assert.ok(report.connectionSuccessRate >= 0)
  assert.ok('medianMs' in report)
  assert.ok('p95Ms' in report)
})

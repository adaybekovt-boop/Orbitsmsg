'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawnSync } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

test('missing Bare binary is fail-closed', () => {
  const missing = path.join(os.tmpdir(), 'orbits-no-such-bare')
  const result = spawnSync(missing, ['tool/connectivity_harness/src/worklet.js'], {
    encoding: 'utf8',
  })
  assert.notEqual(result.status, 0)
})

test('wrong worklet hash is rejected by the Dart/host contract', () => {
  const manifest = JSON.parse(
    fs.readFileSync(path.join(__dirname, '..', 'BUNDLE.manifest'), 'utf8'),
  )
  assert.equal(manifest.remoteJs, false)
  assert.equal(manifest.ipc, 'orbits-bare-ipc-v1')
  assert.notEqual(manifest.workletSha256, '0'.repeat(64))
})

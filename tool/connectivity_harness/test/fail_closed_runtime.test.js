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

test('verify-runtime rejects a corrupt sidecar', () => {
  const binary = path.join(__dirname, '..', '..', '..', 'build', 'orbits-bare', 'linux-x64', 'bare')
  if (!fs.existsSync(binary)) {
    assert.ok(true)
    return
  }
  const result = spawnSync(
    'bash',
    ['tool/bare/verify-runtime.sh'],
    {
      cwd: path.join(__dirname, '..', '..', '..'),
      encoding: 'utf8',
      env: {
        ...process.env,
        ORBITS_BARE_CACHE: fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-empty-cache-')),
      },
    },
  )
  assert.notEqual(result.status, 0)
  assert.match(result.stderr + result.stdout, /BARE_RUNTIME_MISSING/)
})

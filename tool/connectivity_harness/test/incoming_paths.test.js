'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {
  generateLocalStorageId,
  assertSafeTransferId,
  resolveIncomingDir,
  assertInsideRoot,
  incomingRoot,
  blobPathFor,
} = require('../src/incoming_paths')

const cases = [
  ['../', '../escape'],
  ['..\\', '..\\escape'],
  ['absolute-unix', '/tmp/evil'],
  ['windows-drive', 'C:\\Windows\\evil'],
  ['nested-separators', 'a/b/c'],
  ['encoded-traversal', '%2e%2e%2fsecret'],
]

for (const [name, raw] of cases) {
  test('rejects ' + name, () => {
    assert.throws(() => assertSafeTransferId(raw))
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-in-'))
    assert.throws(() => resolveIncomingDir(root, raw, generateLocalStorageId()))
  })
}

test('matching names still isolate by local storage id', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-in-'))
  const a = resolveIncomingDir(root, 'ORBIT-A', generateLocalStorageId())
  const b = resolveIncomingDir(root, 'ORBIT-A', generateLocalStorageId())
  assert.notEqual(a, b)
  assert.ok(a.startsWith(incomingRoot(root)))
  assert.ok(b.startsWith(incomingRoot(root)))
})

test('symlink inside incoming root cannot escape', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-in-'))
  const incoming = incomingRoot(root)
  fs.mkdirSync(incoming, { recursive: true })
  const outside = path.join(root, 'outside.txt')
  fs.writeFileSync(outside, 'secret')
  const link = path.join(incoming, 'ORBIT-A')
  try {
    fs.symlinkSync(path.dirname(outside), link)
  } catch (err) {
    if (err.code === 'EPERM' || err.code === 'EACCES') return
    throw err
  }
  const dest = path.join(link, generateLocalStorageId())
  assert.throws(() => assertInsideRoot(incoming, dest), /path-escape/)
})

test('blob path stays under the incoming directory', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-in-'))
  const dir = resolveIncomingDir(root, 'ORBIT-ALICE', generateLocalStorageId())
  fs.mkdirSync(dir, { recursive: true })
  const blob = blobPathFor(dir)
  const resolved = assertInsideRoot(incomingRoot(root), blob)
  assert.equal(resolved, path.resolve(blob))
  assert.ok(resolved.startsWith(incomingRoot(root)))
  assert.ok(blob.endsWith(`${path.sep}blob`))
})

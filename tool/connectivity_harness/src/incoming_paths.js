'use strict'

const { fs, path, crypto } = require('./bare_compat')

const SAFE_TRANSFER_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/
const SAFE_SENDER_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
const WIN_DRIVE = /^[a-zA-Z]:[\\/]/
const ENCODED_DOTDOT = /%2e%2e|%2E%2E|%252e|%c0%ae/i

function generateLocalStorageId() {
  return crypto.randomBytes(16).toString('hex')
}

function rejectUnsafeFragment(raw, label) {
  const value = String(raw == null ? '' : raw)
  if (!value) throw new Error('unsafe-' + label)
  if (value.includes('\0')) throw new Error('unsafe-' + label + '-nul')
  if (value.includes('..') || ENCODED_DOTDOT.test(value)) {
    throw new Error('unsafe-' + label + '-dotdot')
  }
  if (value.includes('/') || value.includes('\\')) {
    throw new Error('unsafe-' + label + '-separator')
  }
  if (path.isAbsolute(value) || WIN_DRIVE.test(value) || value.startsWith('\\\\')) {
    throw new Error('unsafe-' + label + '-absolute')
  }
  return value
}

function assertSafeTransferId(raw) {
  const value = rejectUnsafeFragment(raw, 'transfer-id')
  if (!SAFE_TRANSFER_ID.test(value)) throw new Error('unsafe-transfer-id-format')
  return value
}

function assertSafeSenderId(raw) {
  const value = rejectUnsafeFragment(raw, 'sender-id')
  if (!SAFE_SENDER_ID.test(value)) throw new Error('unsafe-sender-id-format')
  return value
}

function incomingRoot(baseDir) {
  return path.resolve(String(baseDir), 'orbits-incoming')
}

function resolveIncomingDir(baseDir, trustedSenderId, localStorageId) {
  const sender = assertSafeSenderId(trustedSenderId)
  const localId = assertSafeTransferId(localStorageId)
  const root = incomingRoot(baseDir)
  const dest = path.resolve(root, sender, localId)
  const rel = path.relative(root, dest)
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel) || rel.includes('..')) {
    throw new Error('path-escape')
  }
  return dest
}

function assertInsideRoot(root, candidate) {
  const realRoot = fs.existsSync(root) ? fs.realpathSync(root) : path.resolve(root)
  const abs = path.resolve(candidate)
  const missing = []
  let probe = abs
  while (!fs.existsSync(probe)) {
    missing.unshift(path.basename(probe))
    const parent = path.dirname(probe)
    if (parent === probe) break
    probe = parent
  }
  const realExisting = fs.existsSync(probe) ? fs.realpathSync(probe) : path.resolve(probe)
  const real = missing.length ? path.join(realExisting, ...missing) : realExisting
  const rel = path.relative(realRoot, real)
  if (rel.startsWith('..') || path.isAbsolute(rel)) throw new Error('path-escape')
  return real
}

function blobPathFor(dir) {
  return path.join(dir, 'blob')
}

module.exports = {
  SAFE_TRANSFER_ID,
  generateLocalStorageId,
  rejectUnsafeFragment,
  assertSafeTransferId,
  assertSafeSenderId,
  incomingRoot,
  resolveIncomingDir,
  assertInsideRoot,
  blobPathFor,
}

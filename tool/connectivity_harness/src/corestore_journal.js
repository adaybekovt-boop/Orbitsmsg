'use strict'

/**
 * Bare-side append-only journal. Encrypted envelopes only.
 * Prefers Holepunch Corestore when the module is linked locally.
 * Falls back to an in-memory stand-in. Never stores plaintext.
 * Never fetches a remote .node addon.
 */

const FORBIDDEN = new Set([
  'plaintext',
  'password',
  'kek',
  'vaultKek',
  'rootKey',
  'sendCk',
  'recvCk',
  'dhPriv',
  'skipped',
  'discoverySecret',
  'sharedDiscoverySecret',
  'attachmentBytes',
  'privBytes',
])

function fieldsAreSafe(fields) {
  if (!fields || typeof fields !== 'object') return false
  for (const key of Object.keys(fields)) {
    if (FORBIDDEN.has(key)) return false
  }
  return true
}

function isRemoteUrl(p) {
  if (typeof p !== 'string') return false
  const t = p.trim().toLowerCase()
  return t.startsWith('http://') || t.startsWith('https://')
}

function localBareAddonPath() {
  const env =
    (typeof process !== 'undefined' &&
      process.env &&
      process.env.ORBITS_CORESTORE_ADDON) ||
    ''
  if (env && !isRemoteUrl(env)) return env
  try {
    const path = require('node:path')
    const fs = require('node:fs')
    const candidates = [
      path.join(__dirname, '..', '..', 'bare', 'addons', 'corestore.bare'),
    ]
    for (const c of candidates) {
      if (!isRemoteUrl(c) && fs.existsSync(c)) return c
    }
  } catch {
    // missing fs
  }
  return ''
}

class CorestoreJournal {
  constructor(writerDeviceId) {
    this.writerDeviceId = writerDeviceId || 'local-device'
    this.blocks = []
    this.backend = 'memory'
    this._core = null
    this._store = null
    this._logPath = null
  }

  // Try to open Holepunch Corestore. Missing module → memory.
  // Node's `corestore` addon must not be required from Bare: it hangs
  // the 1.31 runtime instead of throwing. The native Bare addon is a
  // separate slot (`kHolepunchCorestoreAddonLinked`).
  async useCorestoreIfPresent(dir) {
    if (typeof Bare !== 'undefined') {
      return this._useBareJournal(dir)
    }
    let Corestore
    try {
      Corestore = require('corestore')
    } catch {
      this.backend = 'memory'
      return false
    }
    const path = require('node:path')
    const os = require('node:os')
    const root = dir || path.join(os.tmpdir(), 'orbits-corestore-' + this.writerDeviceId)
    this._store = new Corestore(root)
    await this._store.ready()
    this._core = this._store.get({ name: 'orbits-journal-v1' })
    await this._core.ready()
    this.backend = 'corestore'
    return true
  }

  async _useBareJournal(dir) {
    const addon = localBareAddonPath()
    if (addon) {
      try {
        const fs = require('node:fs')
        if (
          fs.existsSync(addon) &&
          typeof Bare !== 'undefined' &&
          Bare.Addon &&
          typeof Bare.Addon.load === 'function'
        ) {
          Bare.Addon.load(addon)
        }
      } catch {
        // missing / unloadable local addon — keep probing fs journal
      }
    }
    return this.useEncryptedEnvelopeFileJournal(dir)
  }

  // Encrypted-envelope JSONL on Bare only. Not a Holepunch Corestore.
  useEncryptedEnvelopeFileJournal(dir) {
    try {
      const fs = require('node:fs')
      const path = require('node:path')
      const os = require('node:os')
      const root =
        dir || path.join(os.tmpdir(), 'orbits-journal-' + this.writerDeviceId)
      fs.mkdirSync(root, { recursive: true })
      this._logPath = path.join(root, 'envelopes.jsonl')
      this.backend = 'fs'
      return false
    } catch {
      this.backend = 'memory'
      return false
    }
  }

  async close() {
    if (this._store && this._store.close) await this._store.close()
    this._core = null
    this._store = null
    this._logPath = null
  }

  append(record) {
    const fields = record.fields || {}
    if (!fieldsAreSafe(fields)) {
      throw new Error('refusing secret field in corestore journal')
    }
    if (!fields.encryptedEnvelope) {
      throw new Error('journal requires encryptedEnvelope')
    }
    const stored = {
      seq: record.seq == null ? this.blocks.length + 1 : record.seq,
      writerDeviceId: record.writerDeviceId || this.writerDeviceId,
      kind: record.kind || 'messageEnvelopeCreated',
      fields,
    }
    this.blocks.push(stored)
    if (this._core) {
      const pending = this._core.append(Buffer.from(JSON.stringify(stored)))
      if (pending && typeof pending.then === 'function') {
        pending.catch(() => {})
      }
    }
    if (this._logPath) {
      try {
        require('node:fs').appendFileSync(
          this._logPath,
          JSON.stringify(stored) + '\n',
        )
      } catch {
        // keep the in-memory copy
      }
    }
    return stored
  }

  list() {
    return this.blocks.slice()
  }
}

module.exports = { CorestoreJournal, fieldsAreSafe, FORBIDDEN }

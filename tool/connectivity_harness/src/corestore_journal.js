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

class CorestoreJournal {
  constructor(writerDeviceId) {
    this.writerDeviceId = writerDeviceId || 'local-device'
    this.blocks = []
    this.backend = 'memory'
    this._core = null
    this._store = null
  }

  // Try to open Holepunch Corestore. Missing module → memory.
  // Node's `corestore` addon must not be required from Bare: it hangs
  // the 1.31 runtime instead of throwing. The native Bare addon is a
  // separate slot (`kHolepunchCorestoreAddonLinked`).
  async useCorestoreIfPresent(dir) {
    if (typeof Bare !== 'undefined') {
      this.backend = 'memory'
      return false
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

  async close() {
    if (this._store && this._store.close) await this._store.close()
    this._core = null
    this._store = null
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
    return stored
  }

  list() {
    return this.blocks.slice()
  }
}

module.exports = { CorestoreJournal, fieldsAreSafe, FORBIDDEN }

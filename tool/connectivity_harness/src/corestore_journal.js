'use strict'

/**
 * Journal of encrypted envelopes. Production uses official Corestore.
 * The in-memory adapter remains only for Node unit tests that do not
 * open a storage directory. Never stores plaintext or KEK material.
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

function assertRecord(record) {
  const fields = record.fields || {}
  if (!fieldsAreSafe(fields)) {
    throw new Error('refusing secret field in corestore journal')
  }
  if (!fields.encryptedEnvelope) {
    throw new Error('journal requires encryptedEnvelope')
  }
  return fields
}

class CorestoreJournal {
  constructor(writerDeviceId) {
    this.writerDeviceId = writerDeviceId || 'local-device'
    this.blocks = []
    this.backend = 'memory'
  }

  append(record) {
    const fields = assertRecord(record)
    const stored = {
      seq: record.seq == null ? this.blocks.length + 1 : record.seq,
      writerDeviceId: record.writerDeviceId || this.writerDeviceId,
      kind: record.kind || 'messageEnvelopeCreated',
      fields,
    }
    this.blocks.push(stored)
    return stored
  }

  list() {
    return this.blocks.slice()
  }
}

class RealCorestoreJournal {
  constructor(store, core, writerDeviceId) {
    this.store = store
    this.core = core
    this.writerDeviceId = writerDeviceId || 'local-device'
    this.backend = 'corestore'
  }

  static async open(opts = {}) {
    let Corestore
    try {
      Corestore = require('corestore')
    } catch (err) {
      throw new Error('CORESTORE_ADDON_MISSING: ' + (err && err.message))
    }
    if (!opts.storageDir) {
      throw new Error('CORESTORE_ADDON_MISSING: storageDir required')
    }
    const store = new Corestore(opts.storageDir)
    const core = store.get({ name: opts.coreName || 'orbits-journal' })
    await core.ready()
    return new RealCorestoreJournal(store, core, opts.writerDeviceId)
  }

  async append(record) {
    const fields = assertRecord(record)
    const stored = {
      seq: record.seq == null ? this.core.length + 1 : record.seq,
      writerDeviceId: record.writerDeviceId || this.writerDeviceId,
      kind: record.kind || 'messageEnvelopeCreated',
      fields,
    }
    await this.core.append(Buffer.from(JSON.stringify(stored)))
    return stored
  }

  async list() {
    const blocks = []
    for (let i = 0; i < this.core.length; i++) {
      const raw = await this.core.get(i)
      blocks.push(JSON.parse(Buffer.from(raw).toString('utf8')))
    }
    return blocks
  }

  async close() {
    try {
      await this.store.close()
    } catch {
      // already closed
    }
  }
}

async function openJournal(opts = {}) {
  const requireReal =
    opts.requireReal === true ||
    (typeof Bare !== 'undefined' && opts.requireReal !== false)
  if (requireReal || opts.storageDir) {
    try {
      return await RealCorestoreJournal.open(opts)
    } catch (err) {
      if (requireReal) throw err
    }
  }
  return new CorestoreJournal(opts.writerDeviceId)
}

module.exports = {
  CorestoreJournal,
  RealCorestoreJournal,
  openJournal,
  fieldsAreSafe,
  FORBIDDEN,
}

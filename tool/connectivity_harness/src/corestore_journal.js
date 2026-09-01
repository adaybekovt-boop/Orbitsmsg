'use strict'

/**
 * Bare-side append-only journal. Encrypted envelopes only.
 * This is the local Corestore writer stand-in until a Holepunch
 * Corestore native addon is linked. Never stores plaintext.
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
    return stored
  }

  list() {
    return this.blocks.slice()
  }
}

module.exports = { CorestoreJournal, fieldsAreSafe, FORBIDDEN }

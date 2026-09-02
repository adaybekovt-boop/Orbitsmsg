'use strict'

/**
 * Bare-side append-only journal. Encrypted envelopes only.
 * Prefers Holepunch Corestore when the module is linked locally.
 * Falls back to an encrypted-envelope JSONL file when a journalDir is
 * given. Never stores plaintext. Never fetches a remote .node addon.
 *
 * Append awaits the durable write and reopen hydrates from disk /
 * Hypercore. In-memory list() is a cache of that durable log.
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
  'fileKey',
  'fileKeyB64',
  'privBytes',
])

const ENVELOPE_KINDS = new Set([
  'messageEnvelopeCreated',
  'attachmentPublished',
])

function fieldsAreSafe(fields) {
  if (!fields || typeof fields !== 'object') return false
  const seen = new Set()
  function walk(value) {
    if (!value || typeof value !== 'object') return true
    if (seen.has(value)) return true
    seen.add(value)
    if (Array.isArray(value)) return value.every(walk)
    for (const [key, child] of Object.entries(value)) {
      if (FORBIDDEN.has(key)) return false
      if (!walk(child)) return false
    }
    return true
  }
  return walk(fields)
}

function isRemoteUrl(p) {
  if (typeof p !== 'string') return false
  const t = p.trim().toLowerCase()
  return t.startsWith('http://') || t.startsWith('https://') || t.includes('://')
}

// Same keys as Dart `_kReplicationIdentifierKeys`. Present key + empty
// or `://` is unsafe. Do not put these on FORBIDDEN — that set is
// secret *names*. `text` / `b64` stay allowed even when URL-shaped.
const IDENTIFIER_KEYS = new Set([
  'eventId',
  'conversationId',
  'roomId',
  'peerId',
  'deviceId',
  'fileId',
])

function identifierValuesSafe(fields) {
  if (!fields || typeof fields !== 'object') return false
  for (const key of IDENTIFIER_KEYS) {
    if (!Object.prototype.hasOwnProperty.call(fields, key)) continue
    const value = fields[key]
    if (typeof value !== 'string' || !value || isRemoteUrl(value)) return false
  }
  return true
}

function safeJournalDir(dir) {
  if (typeof dir !== 'string') return ''
  const t = dir.trim()
  if (!t || isRemoteUrl(t)) return ''
  return t
}

function parseStored(raw) {
  let rec = raw
  if (raw == null) return null
  if (typeof raw === 'string' || Buffer.isBuffer(raw)) {
    try {
      rec = JSON.parse(Buffer.isBuffer(raw) ? raw.toString('utf8') : raw)
    } catch {
      return null
    }
  }
  if (!rec || typeof rec !== 'object') return null
  const fields = rec.fields
  if (!fields || typeof fields !== 'object') return null
  if (!fieldsAreSafe(fields)) return null
  if (!identifierValuesSafe(fields)) return null
  if (typeof rec.writerDeviceId === 'string' && isRemoteUrl(rec.writerDeviceId)) {
    return null
  }
  const kind = rec.kind || 'messageEnvelopeCreated'
  if (typeof kind === 'string' && (isRemoteUrl(kind) || kind.includes('://'))) {
    return null
  }
  if (ENVELOPE_KINDS.has(kind) && !fields.encryptedEnvelope) return null
  return rec
}

function isLocalAddonFile(p) {
  if (typeof p !== 'string') return false
  const t = p.trim()
  if (!t || isRemoteUrl(t)) return false
  if (!(t.endsWith('.bare') || t.endsWith('.node'))) return false
  try {
    return require('node:fs').existsSync(t)
  } catch {
    return false
  }
}

/**
 * Map `Bare.Addon.load` output to a Corestore constructor.
 *
 * Holepunch Corestore on Node is `require('corestore')`. That hangs Bare
 * 1.31 — never `require('corestore')` on the Bare path. A Holepunch-built
 * `corestore.bare` may return the constructor, `{ Corestore }`, or
 * `{ default }`. Anything else → encrypted JSONL.
 */
function corestoreCtorFromAddon(loaded) {
  if (typeof loaded === 'function') return loaded
  if (loaded && typeof loaded === 'object') {
    if (typeof loaded.Corestore === 'function') return loaded.Corestore
    if (typeof loaded.default === 'function') return loaded.default
  }
  return null
}

function localBareAddonPath() {
  const env =
    (typeof process !== 'undefined' &&
      process.env &&
      process.env.ORBITS_CORESTORE_ADDON) ||
    ''
  if (env) return isRemoteUrl(env) ? '' : env
  try {
    const path = require('node:path')
    const candidates = [
      path.join(__dirname, 'addons', 'corestore.bare'),
      path.join(__dirname, '..', 'addons', 'corestore.bare'),
      path.join(__dirname, '..', 'corestore.bare'),
      path.join(__dirname, '..', '..', 'bare', 'addons', 'corestore.bare'),
    ]
    for (const c of candidates) {
      if (isLocalAddonFile(c)) return c
    }
  } catch {
    // missing fs / __dirname
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

  // Try to open Holepunch Corestore. Missing module → JSONL when a
  // journalDir is given, else memory. Never persist to a shared tmp
  // path keyed only by device id — leftover ciphertext would leak
  // across unrelated process starts.
  // Node's `corestore` addon must not be required from Bare: it hangs
  // the 1.31 runtime instead of throwing. The native Bare addon is a
  // separate slot (`kHolepunchCorestoreAddonLinked`).
  async useCorestoreIfPresent(dir) {
    const root = safeJournalDir(dir)
    if (typeof Bare !== 'undefined') {
      if (!root) {
        this.backend = 'memory'
        return false
      }
      return this._useBareJournal(root)
    }
    let Corestore
    try {
      Corestore = require('corestore')
    } catch {
      if (root) return this.useEncryptedEnvelopeFileJournal(root)
      this.backend = 'memory'
      return false
    }
    if (!root) {
      this.backend = 'memory'
      return false
    }
    try {
      return await this._openWithCtor(Corestore, root)
    } catch {
      return this.useEncryptedEnvelopeFileJournal(root)
    }
  }

  async _openWithCtor(Corestore, root) {
    const store = new Corestore(root)
    await store.ready()
    const core = store.get({ name: 'orbits-journal-v1' })
    await core.ready()
    this._store = store
    this._core = core
    await this._hydrateFromCore()
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
          const loaded = Bare.Addon.load(addon)
          const Corestore = corestoreCtorFromAddon(loaded)
          if (typeof Corestore === 'function') {
            return await this._openWithCtor(Corestore, dir)
          }
        }
      } catch {
        // missing / unloadable local addon — encrypted JSONL
      }
    }
    return this.useEncryptedEnvelopeFileJournal(dir)
  }

  // Encrypted-envelope JSONL on Bare (and Node when Corestore is
  // missing). Not a Holepunch Corestore. Reopen hydrates this.blocks.
  useEncryptedEnvelopeFileJournal(dir) {
    try {
      const fs = require('node:fs')
      const path = require('node:path')
      const os = require('node:os')
      const root =
        safeJournalDir(dir) ||
        path.join(os.tmpdir(), 'orbits-journal-' + this.writerDeviceId)
      fs.mkdirSync(root, { recursive: true })
      this._logPath = path.join(root, 'envelopes.jsonl')
      this.backend = 'fs'
      this._hydrateFromLog()
      return false
    } catch {
      this.backend = 'memory'
      return false
    }
  }

  async _hydrateFromCore() {
    if (!this._core) return
    await this._core.ready()
    const out = []
    const n = this._core.length || 0
    for (let i = 0; i < n; i++) {
      const rec = parseStored(await this._core.get(i))
      if (rec) out.push(rec)
    }
    this.blocks = out
  }

  _hydrateFromLog() {
    if (!this._logPath) return
    try {
      const fs = require('node:fs')
      if (!fs.existsSync(this._logPath)) {
        this.blocks = []
        return
      }
      const text = fs.readFileSync(this._logPath, 'utf8')
      const out = []
      for (const line of text.split('\n')) {
        if (!line.trim()) continue
        const rec = parseStored(line)
        if (rec) out.push(rec)
      }
      this.blocks = out
    } catch {
      this.blocks = []
    }
  }

  async close() {
    if (this._core && typeof this._core.close === 'function') {
      try {
        await this._core.close()
      } catch {
        // already closed
      }
    }
    if (this._store && this._store.close) await this._store.close()
    this._core = null
    this._store = null
    this._logPath = null
  }

  async append(record) {
    const fields = record.fields || {}
    if (!fieldsAreSafe(fields)) {
      throw new Error('refusing secret field in corestore journal')
    }
    if (!identifierValuesSafe(fields)) {
      throw new Error('refusing secret field in corestore journal')
    }
    const kind = record.kind || 'messageEnvelopeCreated'
    if (ENVELOPE_KINDS.has(kind) && !fields.encryptedEnvelope) {
      throw new Error('journal requires encryptedEnvelope')
    }
    const writer = record.writerDeviceId || this.writerDeviceId
    if (isRemoteUrl(writer) || !writer) {
      throw new Error('refusing secret field in corestore journal')
    }
    if (typeof kind === 'string' && (isRemoteUrl(kind) || kind.includes('://'))) {
      throw new Error('refusing secret field in corestore journal')
    }
    const stored = {
      seq: record.seq == null ? this.blocks.length + 1 : record.seq,
      writerDeviceId: writer,
      kind,
      fields,
    }
    if (this._core) {
      await this._core.append(Buffer.from(JSON.stringify(stored)))
    }
    if (this._logPath) {
      try {
        require('node:fs').appendFileSync(
          this._logPath,
          JSON.stringify(stored) + '\n',
        )
      } catch {
        // keep trying the in-memory copy after a durable miss
      }
    }
    this.blocks.push(stored)
    return stored
  }

  list() {
    return this.blocks.slice()
  }
}

module.exports = {
  CorestoreJournal,
  corestoreCtorFromAddon,
  fieldsAreSafe,
  identifierValuesSafe,
  IDENTIFIER_KEYS,
  FORBIDDEN,
  ENVELOPE_KINDS,
  isLocalAddonFile,
  localBareAddonPath,
  parseStored,
  safeJournalDir,
}

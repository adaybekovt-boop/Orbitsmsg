'use strict'

/**
 * Blind storage peer. Encrypted envelopes only.
 * No remote JS. No plaintext, peer IDs, or keys in the protocol.
 */

const http = require('node:http')
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const { URL } = require('node:url')

const VERSION = 'orbits-mailbox-http-v1'
const CAP_INFO = 'orbits-mailbox-cap-v1'
const MAX_BODY = 12 * 1024 * 1024
const CLOCK_SKEW_MS = 5 * 60 * 1000
const REPLAY_TTL_MS = 30 * 60 * 1000
const FORBIDDEN = new Set([
  'plaintext',
  'text',
  'body',
  'peerId',
  'kek',
  'rootKey',
  'password',
  'vaultKek',
  'sendCk',
  'recvCk',
  'dhPriv',
  'skipped',
  'discoverySecret',
  'sharedDiscoverySecret',
  'attachmentBytes',
  'privBytes',
])

function rejectForbidden(obj) {
  for (const key of Object.keys(obj || {})) {
    if (FORBIDDEN.has(key)) {
      const err = new Error('plaintext')
      err.code = 'plaintext'
      throw err
    }
  }
}

function hmac(secret, data) {
  return crypto.createHmac('sha256', Buffer.from(secret)).update(data).digest()
}

function canonicalCap(cap) {
  const scopes = [...cap.scopes].sort()
  return [
    CAP_INFO,
    cap.tokenId,
    cap.mailboxId,
    scopes.join(','),
    String(cap.issuedAt),
    String(cap.notBefore),
    String(cap.expiresAt),
    String(cap.quotaBytes),
    String(cap.retentionMs),
  ].join('\n')
}

function issueCapability(secret, fields) {
  if (!fields.tokenId) {
    const err = new Error('anonymous writes are rejected')
    err.code = 'anonymous'
    throw err
  }
  const draft = { ...fields }
  const mac = hmac(secret, canonicalCap(draft))
  return { ...draft, v: CAP_INFO, mac: mac.toString('base64') }
}

function verifyCapability(secret, cap, scope, mailboxId, now) {
  if (!cap || !cap.tokenId) {
    const err = new Error('anonymous')
    err.code = 'anonymous'
    throw err
  }
  const expected = hmac(secret, canonicalCap(cap))
  const got = Buffer.from(cap.mac || '', 'base64')
  if (expected.length !== got.length || !crypto.timingSafeEqual(expected, got)) {
    const err = new Error('invalid-mac')
    err.code = 'invalid-mac'
    throw err
  }
  if (!Array.isArray(cap.scopes) || !cap.scopes.includes(scope)) {
    const err = new Error('unauthorized')
    err.code = 'unauthorized'
    throw err
  }
  if (cap.mailboxId !== mailboxId) {
    const err = new Error('wrong-recipient')
    err.code = 'wrong-recipient'
    throw err
  }
  if (cap.issuedAt > now + CLOCK_SKEW_MS) {
    const err = new Error('not-yet-valid')
    err.code = 'not-yet-valid'
    throw err
  }
  if (now + CLOCK_SKEW_MS < cap.notBefore) {
    const err = new Error('not-yet-valid')
    err.code = 'not-yet-valid'
    throw err
  }
  if (now > cap.expiresAt) {
    const err = new Error('expired')
    err.code = 'expired'
    throw err
  }
}

function rejectPlaintextEnvelope(bytes) {
  const text = Buffer.from(bytes).toString('utf8')
  if (text.startsWith('v2:')) return
  try {
    const parsed = JSON.parse(text)
    if (parsed && typeof parsed === 'object') rejectForbidden(parsed)
  } catch (err) {
    if (err.code === 'plaintext') throw err
  }
}

function createStore(persistPath) {
  const cores = new Map()
  const seqs = new Map()
  const seen = new Map()

  function persist() {
    if (!persistPath) return
    const payload = {
      v: VERSION,
      cores: Object.fromEntries(
        [...cores.entries()].map(([k, list]) => [
          k,
          list.map((b) => ({
            seq: b.seq,
            b64: Buffer.from(b.bytes).toString('base64'),
            storedAt: b.storedAt,
            envelopeId: b.envelopeId,
            acked: b.acked,
            tombstoned: b.tombstoned,
          })),
        ]),
      ),
      seq: Object.fromEntries(seqs),
    }
    fs.mkdirSync(path.dirname(persistPath), { recursive: true })
    const tmp = persistPath + '.tmp'
    fs.writeFileSync(tmp, JSON.stringify(payload))
    fs.renameSync(tmp, persistPath)
  }

  function hydrate() {
    if (!persistPath || !fs.existsSync(persistPath)) return
    try {
      const raw = JSON.parse(fs.readFileSync(persistPath, 'utf8'))
      for (const [key, list] of Object.entries(raw.cores || {})) {
        cores.set(
          key,
          (list || [])
            .map((item) => {
              try {
                rejectForbidden(item)
                return {
                  seq: item.seq,
                  bytes: Buffer.from(item.b64 || '', 'base64'),
                  storedAt: item.storedAt || 0,
                  envelopeId: item.envelopeId,
                  acked: !!item.acked,
                  tombstoned: !!item.tombstoned,
                }
              } catch {
                return null
              }
            })
            .filter(Boolean),
        )
      }
      for (const [key, value] of Object.entries(raw.seq || {})) {
        seqs.set(key, value)
      }
    } catch {
      // skip corrupt file; keep whatever parsed
    }
  }

  hydrate()

  return {
    remember(requestId, now) {
      for (const [id, at] of seen) {
        if (now - at > REPLAY_TTL_MS) seen.delete(id)
      }
      if (seen.has(requestId)) return false
      seen.set(requestId, now)
      return true
    },
    has(mailboxId, envelopeId) {
      return (cores.get(mailboxId) || []).some(
        (b) => b.envelopeId === envelopeId && !b.tombstoned,
      )
    },
    deposit(mailboxId, envelopeId, bytes, quotaBytes) {
      rejectPlaintextEnvelope(bytes)
      const list = cores.get(mailboxId) || []
      const existing = list.find((b) => b.envelopeId === envelopeId)
      if (existing) return { block: existing, duplicate: true }
      const used = list.filter((b) => !b.tombstoned).reduce((n, b) => n + b.bytes.length, 0)
      if (used + bytes.length > quotaBytes) {
        const err = new Error('quota')
        err.code = 'quota'
        throw err
      }
      const seq = (seqs.get(mailboxId) || 0)
      seqs.set(mailboxId, seq + 1)
      const block = {
        seq,
        bytes,
        storedAt: Date.now(),
        envelopeId,
        acked: false,
        tombstoned: false,
      }
      list.push(block)
      cores.set(mailboxId, list)
      persist()
      return { block, duplicate: false }
    },
    drain(mailboxId, retentionMs, fromSeq) {
      const now = Date.now()
      return (cores.get(mailboxId) || []).filter(
        (b) =>
          !b.tombstoned &&
          !b.acked &&
          b.seq >= fromSeq &&
          now - b.storedAt <= retentionMs,
      )
    },
    ack(mailboxId, envelopeId) {
      for (const b of cores.get(mailboxId) || []) {
        if (b.envelopeId === envelopeId) b.acked = true
      }
      persist()
    },
    del(mailboxId, envelopeId) {
      for (const b of cores.get(mailboxId) || []) {
        if (b.envelopeId === envelopeId) {
          b.tombstoned = true
          b.bytes = Buffer.alloc(0)
        }
      }
      persist()
    },
  }
}

function readBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    req.on('data', (c) => {
      size += c.length
      if (size > maxBytes) {
        const err = new Error('oversized')
        err.code = 'oversized'
        reject(err)
        req.destroy()
        return
      }
      chunks.push(c)
    })
    req.on('end', () => resolve(Buffer.concat(chunks)))
    req.on('error', reject)
  })
}

function statusFor(code) {
  if (code === 'oversized') return 413
  if (['unauthorized', 'anonymous', 'invalid-mac', 'wrong-recipient'].includes(code)) {
    return 403
  }
  if (['expired', 'not-yet-valid', 'replay'].includes(code)) return 401
  if (code === 'quota') return 429
  return 400
}

function createServer(opts = {}) {
  const secret = Buffer.from(opts.grantSecret || crypto.randomBytes(32))
  const store = createStore(opts.persistPath)
  const nowMs = opts.nowMs || (() => Date.now())
  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://127.0.0.1')
      if (req.method === 'GET' && url.pathname === '/health') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true, role: 'storage', plaintext: false }))
        return
      }
      if (req.method === 'POST' && url.pathname === '/v1/mailbox') {
        const raw = await readBody(req, opts.maxBodyBytes || MAX_BODY)
        let body
        try {
          body = JSON.parse(raw.toString('utf8'))
        } catch {
          const err = new Error('malformed')
          err.code = 'malformed'
          throw err
        }
        rejectForbidden(body)
        if (body.v !== VERSION) {
          const err = new Error('malformed')
          err.code = 'malformed'
          throw err
        }
        const cap = body.capability
        rejectForbidden(cap)
        const mailboxId = body.mailboxId || cap.mailboxId
        verifyCapability(secret, cap, body.op, mailboxId, nowMs())
        if (!store.remember(body.requestId, nowMs())) {
          const err = new Error('replay')
          err.code = 'replay'
          throw err
        }
        if (body.op === 'deposit') {
          const bytes = Buffer.from(body.ciphertextB64 || '', 'base64')
          const result = store.deposit(mailboxId, body.envelopeId, bytes, cap.quotaBytes)
          res.writeHead(200, { 'content-type': 'application/json' })
          res.end(JSON.stringify({ v: VERSION, ok: true, duplicate: result.duplicate }))
          return
        }
        if (body.op === 'drain') {
          const envelopes = store.drain(mailboxId, cap.retentionMs, Number(body.fromSeq || 0))
          res.writeHead(200, { 'content-type': 'application/json' })
          res.end(
            JSON.stringify({
              v: VERSION,
              ok: true,
              envelopes: envelopes.map((b) => ({
                envelopeId: b.envelopeId,
                seq: b.seq,
                ciphertextB64: Buffer.from(b.bytes).toString('base64'),
                storedAt: b.storedAt,
              })),
            }),
          )
          return
        }
        if (body.op === 'ack') {
          store.ack(mailboxId, body.envelopeId)
          res.writeHead(200, { 'content-type': 'application/json' })
          res.end(JSON.stringify({ v: VERSION, ok: true }))
          return
        }
        if (body.op === 'delete') {
          store.del(mailboxId, body.envelopeId)
          res.writeHead(200, { 'content-type': 'application/json' })
          res.end(JSON.stringify({ v: VERSION, ok: true }))
          return
        }
        const err = new Error('malformed')
        err.code = 'malformed'
        throw err
      }
      res.writeHead(404)
      res.end()
    } catch (err) {
      const code = err.code || 'malformed'
      res.writeHead(statusFor(code), { 'content-type': 'application/json' })
      res.end(JSON.stringify({ v: VERSION, ok: false, error: code }))
    }
  })
  server.issueCapability = (fields) => issueCapability(secret, fields)
  server.grantSecret = secret
  return server
}

if (require.main === module) {
  const port = Number(process.env.ORBITS_STORAGE_PORT || 8787)
  const server = createServer({
    grantSecret: process.env.ORBITS_MAILBOX_GRANT_SECRET || crypto.randomBytes(32),
    persistPath: process.env.ORBITS_STORAGE_PATH || undefined,
  })
  server.listen(port, '127.0.0.1', () => {
    process.stdout.write('storage-peer ' + port + '\n')
  })
}

module.exports = { createServer, issueCapability, FORBIDDEN, VERSION }

'use strict'

/**
 * Blind storage peer. queueId + capability hashes + sealed blobs.
 * No remote JS. No plaintext, peer IDs, writerKey, or envelope keys.
 */

const http = require('node:http')
const crypto = require('node:crypto')
const { URL } = require('node:url')

/** Keep in sync with kStoragePeerForbiddenKeys in lib/mailbox/storage_peer_client.dart */
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
  'text',
  'body',
  'peerId',
  'writerKey',
  'conversationId',
])

const HEX64 = /^[0-9a-fA-F]{64}$/
const DEFAULT_QUOTA = 8 * 1024 * 1024
const DEFAULT_RETENTION_MS = 7 * 24 * 60 * 60 * 1000
const MAX_TTL_MS = 30 * 24 * 60 * 60 * 1000
const ADMIN_HEADER = 'x-orbits-admin-token'

function hasForbiddenKey(value, seen) {
  if (!value || typeof value !== 'object') return false
  const walk = seen || new Set()
  if (walk.has(value)) return false
  walk.add(value)
  if (Array.isArray(value)) {
    for (const item of value) {
      if (hasForbiddenKey(item, walk)) return true
    }
    return false
  }
  for (const [key, child] of Object.entries(value)) {
    if (FORBIDDEN.has(key)) return true
    if (hasForbiddenKey(child, walk)) return true
  }
  return false
}

/** Opaque hex / capability. Keep in sync with mailboxCapStringIsSafe. */
function tokenIsSafe(token) {
  if (typeof token !== 'string' || token.length === 0) return false
  if (token.includes('://')) return false
  if (token.includes('peerId')) return false
  if (token.includes('fileKey')) return false
  if (token.includes('rootKey')) return false
  if (token.includes('discoverySecret')) return false
  if (token.includes('writerKey')) return false
  return true
}

function isHex64(value) {
  return typeof value === 'string' && HEX64.test(value)
}

function sha256Hex(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex')
}

function ctEqHex(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false
  try {
    const left = Buffer.from(a, 'hex')
    const right = Buffer.from(b, 'hex')
    if (left.length !== right.length || left.length === 0) return false
    return crypto.timingSafeEqual(left, right)
  } catch {
    return false
  }
}

const MAX_BODY_BYTES = 256 * 1024
const RATE_LIMIT = 32
const RATE_WINDOW_MS = 10 * 1000

function createStore(opts = {}) {
  const nowMs = opts.nowMs || (() => Date.now())
  const requireAdmin = opts.requireAdminForFirstGrant !== false
  const queues = new Map()
  const queueHits = new Map()
  const capHits = new Map()

  function now() {
    return nowMs()
  }

  function queue(queueId) {
    return queues.get(queueId)
  }

  function assertNotExpired(q) {
    if (q.expiresAt <= now()) {
      const err = new Error('mailbox expired')
      err.code = 'forbidden'
      throw err
    }
  }

  function assertRead(q, readCapHex) {
    assertNotExpired(q)
    if (!ctEqHex(sha256Hex(Buffer.from(readCapHex, 'hex')), q.readCapHash)) {
      const err = new Error('mailbox read capability rejected')
      err.code = 'forbidden'
      throw err
    }
  }

  function assertDeposit(q, depositCapHex) {
    assertNotExpired(q)
    if (!ctEqHex(sha256Hex(Buffer.from(depositCapHex, 'hex')), q.depositCapHash)) {
      const err = new Error('mailbox deposit capability rejected')
      err.code = 'forbidden'
      throw err
    }
  }

  function gc(q) {
    const cutoff = now() - q.retentionMs
    q.blocks = q.blocks.filter((b) => {
      if (b.createdAt < cutoff) {
        q.seenHashes.delete(b.blockHash)
        return false
      }
      return true
    })
  }

  function rateCheck(bucket, key) {
    const t = now()
    const list = bucket.get(key) || []
    const kept = list.filter((ts) => t - ts <= RATE_WINDOW_MS)
    if (kept.length >= RATE_LIMIT) {
      const err = new Error('mailbox rate limited')
      err.code = 'rate'
      throw err
    }
    kept.push(t)
    bucket.set(key, kept)
  }

  function grant(body, adminOk) {
    const queueId = String(body.queueId || '').toLowerCase()
    const readCapHash = String(body.readCapHash || '').toLowerCase()
    const depositCapHash = String(body.depositCapHash || '').toLowerCase()
    if (!isHex64(queueId) || !isHex64(readCapHash) || !isHex64(depositCapHash)) {
      throw new Error('invalid grant fields')
    }
    if (!tokenIsSafe(queueId)) throw new Error('unsafe mailbox queue')
    const existing = queues.get(queueId)
    if (existing) {
      if (!isHex64(body.readCap)) {
        const err = new Error('mailbox re-registration requires readCap')
        err.code = 'forbidden'
        throw err
      }
      assertRead(existing, body.readCap)
    } else if (requireAdmin && !adminOk) {
      const err = new Error('mailbox first registration requires admin')
      err.code = 'forbidden'
      throw err
    }
    const t = now()
    const expiresAt = body.expiresAt || t + DEFAULT_RETENTION_MS
    if (expiresAt <= t || expiresAt > t + MAX_TTL_MS) {
      throw new Error('expiresAt out of range')
    }
    const next = {
      queueId,
      readCapHash,
      depositCapHash,
      quotaBytes: body.quotaBytes || DEFAULT_QUOTA,
      retentionMs: body.retentionMs || DEFAULT_RETENTION_MS,
      expiresAt,
      nextSeq: existing ? existing.nextSeq : 1,
      blocks: existing ? existing.blocks.slice() : [],
      seenHashes: existing ? new Set(existing.seenHashes) : new Set(),
    }
    queues.set(queueId, next)
    return next
  }

  function put(queueId, depositCapHex, bytes, blockHash) {
    const q = queue(queueId)
    if (!q) {
      const err = new Error('unknown mailbox queue')
      err.code = 'forbidden'
      throw err
    }
    assertDeposit(q, depositCapHex)
    if (bytes.length > MAX_BODY_BYTES) {
      const err = new Error('mailbox block too large')
      err.code = 'tooLarge'
      throw err
    }
    const computed = sha256Hex(bytes)
    if (!ctEqHex(computed, String(blockHash || '').toLowerCase())) {
      throw new Error('mailbox blockHash mismatch')
    }
    gc(q)
    const hash = computed
    if (q.seenHashes.has(hash)) {
      const err = new Error('mailbox replay rejected')
      err.code = 'replay'
      throw err
    }
    const used = q.blocks.reduce((n, b) => n + b.bytes.length, 0)
    if (used + bytes.length > q.quotaBytes) {
      throw new Error('mailbox quota exceeded')
    }
    rateCheck(queueHits, queueId)
    rateCheck(capHits, sha256Hex(Buffer.from(depositCapHex, 'hex')))
    const block = {
      seq: q.nextSeq++,
      bytes,
      createdAt: now(),
      blockHash: hash,
    }
    q.blocks.push(block)
    q.seenHashes.add(hash)
    return block
  }

  function get(queueId, readCapHex, fromSeq) {
    const q = queue(queueId)
    if (!q) {
      const err = new Error('unknown mailbox queue')
      err.code = 'forbidden'
      throw err
    }
    assertRead(q, readCapHex)
    gc(q)
    return q.blocks.filter((b) => b.seq >= fromSeq)
  }

  function tombstone(queueId, readCapHex, seq) {
    const q = queue(queueId)
    if (!q) {
      const err = new Error('unknown mailbox queue')
      err.code = 'forbidden'
      throw err
    }
    assertRead(q, readCapHex)
    const before = q.blocks.length
    q.blocks = q.blocks.filter((b) => b.seq !== seq)
    return q.blocks.length < before
  }

  function stats(queueId, readCapHex) {
    const q = queue(queueId)
    if (!q) {
      const err = new Error('unknown mailbox queue')
      err.code = 'forbidden'
      throw err
    }
    assertRead(q, readCapHex)
    gc(q)
    const bytes = q.blocks.reduce((n, b) => n + b.bytes.length, 0)
    return {
      queueId,
      blocks: q.blocks.length,
      bytes,
      usedBytes: bytes,
      pendingCount: q.blocks.length,
      quotaBytes: q.quotaBytes,
      retentionMs: q.retentionMs,
      expiresAt: q.expiresAt,
    }
  }

  function storedBlobs(queueId) {
    const q = queue(queueId)
    return q ? q.blocks.map((b) => b.bytes) : []
  }

  return { grant, put, get, tombstone, stats, storedBlobs, queues }
}

function statusFor(err) {
  if (!err) return 400
  if (err.statusCode) return err.statusCode
  if (err.code === 'rate') return 429
  if (err.code === 'replay') return 409
  if (err.code === 'tooLarge') return 413
  if (err.code === 'forbidden') return 403
  const m = String(err.message || '')
  if (m.includes('rejected') || m.includes('admin') || m.includes('expired') || m.includes('readCap')) {
    return 403
  }
  return 400
}

function readBody(req, maxBytes = MAX_BODY_BYTES) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let n = 0
    let tooLarge = false
    req.on('data', (c) => {
      n += c.length
      if (n > maxBytes) {
        tooLarge = true
        chunks.length = 0
        return
      }
      if (!tooLarge) chunks.push(c)
    })
    req.on('end', () => {
      if (tooLarge) {
        const err = new Error('payload too large')
        err.statusCode = 413
        reject(err)
        return
      }
      resolve(Buffer.concat(chunks))
    })
    req.on('error', reject)
  })
}

function createServer(opts = {}) {
  const maxBody = opts.maxBodyBytes || MAX_BODY_BYTES
  const adminToken = opts.adminToken || process.env.ORBITS_STORAGE_ADMIN_TOKEN || ''
  const store = createStore(opts)

  function adminOk(req) {
    if (!adminToken) return false
    const got = req.headers[ADMIN_HEADER] || ''
    if (!got) return false
    const a = Buffer.from(String(got))
    const b = Buffer.from(String(adminToken))
    if (a.length !== b.length) return false
    return crypto.timingSafeEqual(a, b)
  }

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://127.0.0.1')
      if (req.method === 'GET' && url.pathname === '/health') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true, role: 'storage', plaintext: false }))
        return
      }
      if (req.method === 'POST' && url.pathname === '/v1/grant') {
        const body = JSON.parse((await readBody(req, maxBody)).toString('utf8'))
        if (hasForbiddenKey(body) || body.token || body.writerKey) {
          res.writeHead(400)
          res.end()
          return
        }
        if (!isHex64(body.queueId) || !isHex64(body.readCapHash) || !isHex64(body.depositCapHash)) {
          res.writeHead(400)
          res.end()
          return
        }
        store.grant(body, adminOk(req))
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true }))
        return
      }
      if (req.method === 'POST' && url.pathname === '/v1/blocks') {
        const body = JSON.parse((await readBody(req, maxBody)).toString('utf8'))
        if (hasForbiddenKey(body) || body.token || body.writerKey) {
          res.writeHead(400)
          res.end()
          return
        }
        if (!isHex64(body.queueId) || !isHex64(body.depositCap) || !body.block) {
          res.writeHead(400)
          res.end()
          return
        }
        const raw = body.block.bytes || body.block.b64 || ''
        const bytes = Buffer.from(raw, 'base64')
        const stored = store.put(
          String(body.queueId).toLowerCase(),
          String(body.depositCap).toLowerCase(),
          bytes,
          body.block.blockHash,
        )
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true, seq: stored.seq }))
        return
      }
      if (req.method === 'POST' && url.pathname === '/v1/tombstone') {
        const body = JSON.parse((await readBody(req, maxBody)).toString('utf8'))
        if (hasForbiddenKey(body) || body.token || body.writerKey) {
          res.writeHead(400)
          res.end()
          return
        }
        if (!isHex64(body.queueId) || !isHex64(body.readCap) || body.seq == null) {
          res.writeHead(400)
          res.end()
          return
        }
        store.tombstone(String(body.queueId).toLowerCase(), String(body.readCap).toLowerCase(), body.seq)
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true }))
        return
      }
      if (req.method === 'GET' && url.pathname === '/v1/stats') {
        const queueId = url.searchParams.get('queueId') || ''
        const readCap = url.searchParams.get('readCap') || ''
        if (!isHex64(queueId) || !isHex64(readCap)) {
          res.writeHead(400)
          res.end()
          return
        }
        const s = store.stats(queueId.toLowerCase(), readCap.toLowerCase())
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify(s))
        return
      }
      if (req.method === 'GET' && url.pathname === '/v1/blocks') {
        const queueId = url.searchParams.get('queueId') || ''
        const readCap = url.searchParams.get('readCap') || ''
        if (!isHex64(queueId) || !isHex64(readCap)) {
          res.writeHead(400)
          res.end()
          return
        }
        const blocks = store.get(
          queueId.toLowerCase(),
          readCap.toLowerCase(),
          Number(url.searchParams.get('fromSeq') || 0),
        )
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(
          JSON.stringify({
            blocks: blocks.map((b) => ({
              seq: b.seq,
              bytes: Buffer.from(b.bytes).toString('base64'),
              blockHash: b.blockHash,
              createdAt: b.createdAt,
            })),
          }),
        )
        return
      }
      res.writeHead(404)
      res.end()
    } catch (err) {
      res.writeHead(statusFor(err))
      res.end()
    }
  })
  server._orbitsStore = store
  return server
}

if (require.main === module) {
  const port = Number(process.env.ORBITS_STORAGE_PORT || 8787)
  const server = createServer({
    adminToken: process.env.ORBITS_STORAGE_ADMIN_TOKEN || 'lab-admin',
  })
  server.listen(port, '127.0.0.1', () => {
    process.stdout.write('storage-peer ' + port + '\n')
  })
}

module.exports = {
  createServer,
  createStore,
  hasForbiddenKey,
  tokenIsSafe,
  sha256Hex,
  ctEqHex,
  FORBIDDEN,
  MAX_BODY_BYTES,
  RATE_LIMIT,
  RATE_WINDOW_MS,
}

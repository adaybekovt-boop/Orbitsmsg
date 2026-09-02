'use strict'

/**
 * Blind storage peer. Encrypted blocks only.
 * No remote JS. No plaintext, peer IDs, or keys in the protocol.
 */

const http = require('node:http')
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
])

/** Keep in sync with kMailboxHttpMaxBodyBytes in lib/mailbox/blind_store.dart */
const MAX_BODY_BYTES = 256 * 1024
/** Keep in sync with kMailboxHttpRateLimit / kMailboxHttpRateWindowMs */
const RATE_LIMIT = 32
const RATE_WINDOW_MS = 10 * 1000

const caps = new Map()
const cores = new Map()

function grant(token, quotaBytes, retentionMs, expiresAt) {
  if (!token) throw new Error('anonymous writes are rejected')
  caps.set(token, { quotaBytes, retentionMs, expiresAt })
}

function put(token, writerKey, seq, bytes) {
  const cap = caps.get(token)
  if (!cap || Date.now() >= cap.expiresAt) throw new Error('capability rejected')
  sweep(token, writerKey)
  const list = cores.get(writerKey) || []
  const used = list.reduce((n, b) => n + b.bytes.length, 0)
  if (used + bytes.length > cap.quotaBytes) throw new Error('quota exceeded')
  list.push({ seq, bytes, storedAt: Date.now() })
  cores.set(writerKey, list)
}

function tombstone(token, writerKey, seq) {
  const cap = caps.get(token)
  if (!cap) throw new Error('capability rejected')
  const list = cores.get(writerKey) || []
  cores.set(
    writerKey,
    list.filter((b) => b.seq !== seq),
  )
}

function stats(token, writerKey) {
  const cap = caps.get(token)
  if (!cap || Date.now() >= cap.expiresAt) throw new Error('capability rejected')
  sweep(token, writerKey)
  const list = cores.get(writerKey) || []
  return {
    usedBytes: list.reduce((n, b) => n + b.bytes.length, 0),
    pendingCount: list.length,
  }
}

function sweep(token, writerKey) {
  const cap = caps.get(token)
  if (!cap) return 0
  const list = cores.get(writerKey) || []
  const now = Date.now()
  const kept = list.filter((b) => now - b.storedAt <= cap.retentionMs)
  cores.set(writerKey, kept)
  return list.length - kept.length
}

function get(token, writerKey, fromSeq) {
  const cap = caps.get(token)
  if (!cap || Date.now() >= cap.expiresAt) throw new Error('capability rejected')
  sweep(token, writerKey)
  return (cores.get(writerKey) || []).filter((b) => b.seq >= fromSeq)
}

function rateOk(token, now = Date.now(), limit = RATE_LIMIT, windowMs = RATE_WINDOW_MS, hits = null) {
  if (!token) return false
  const rateHits = hits || rateOk._hits || (rateOk._hits = new Map())
  const hit = rateHits.get(token)
  if (!hit || now - hit.windowStart >= windowMs) {
    rateHits.set(token, { count: 1, windowStart: now })
    return true
  }
  if (hit.count >= limit) return false
  hit.count += 1
  return true
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
  const rateLimit = opts.rateLimit || RATE_LIMIT
  const rateWindowMs = opts.rateWindowMs || RATE_WINDOW_MS
  const hits = new Map()
  grant(
    opts.token || 'local-mailbox',
    opts.quotaBytes || 64 * 1024 * 1024,
    opts.retentionMs || 30 * 24 * 3600 * 1000,
    Date.now() + (opts.ttlMs || 86400000 * 30),
  )
  return http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://127.0.0.1')
      if (req.method === 'GET' && url.pathname === '/health') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true, role: 'storage', plaintext: false }))
        return
      }
      if (req.method === 'POST' && url.pathname === '/v1/grant') {
        const body = JSON.parse((await readBody(req, maxBody)).toString('utf8'))
        for (const key of Object.keys(body)) {
          if (FORBIDDEN.has(key)) {
            res.writeHead(400)
            res.end()
            return
          }
        }
        if (!body.token) {
          res.writeHead(400)
          res.end()
          return
        }
        grant(
          body.token,
          body.quotaBytes || 64 * 1024 * 1024,
          body.retentionMs || 30 * 24 * 3600 * 1000,
          body.expiresAt || Date.now() + 86400000 * 30,
        )
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true }))
        return
      }
      if (req.method === 'POST' && url.pathname === '/v1/blocks') {
        const body = JSON.parse((await readBody(req, maxBody)).toString('utf8'))
        for (const key of Object.keys(body)) {
          if (FORBIDDEN.has(key)) {
            res.writeHead(400)
            res.end()
            return
          }
        }
        if (!body.token || !body.writerKey) {
          res.writeHead(400)
          res.end()
          return
        }
        if (!rateOk(body.token, Date.now(), rateLimit, rateWindowMs, hits)) {
          res.writeHead(429)
          res.end()
          return
        }
        put(body.token, body.writerKey, body.seq, Buffer.from(body.b64 || '', 'base64'))
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true }))
        return
      }
      if (req.method === 'POST' && url.pathname === '/v1/tombstone') {
        const body = JSON.parse((await readBody(req, maxBody)).toString('utf8'))
        for (const key of Object.keys(body)) {
          if (FORBIDDEN.has(key)) {
            res.writeHead(400)
            res.end()
            return
          }
        }
        if (!body.token || !body.writerKey || body.seq == null) {
          res.writeHead(400)
          res.end()
          return
        }
        tombstone(body.token, body.writerKey, body.seq)
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true }))
        return
      }
      if (req.method === 'GET' && url.pathname === '/v1/stats') {
        const token = url.searchParams.get('token') || ''
        const writerKey = url.searchParams.get('writerKey') || ''
        if (!token || !writerKey) {
          res.writeHead(400)
          res.end()
          return
        }
        const s = stats(token, writerKey)
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify(s))
        return
      }
      if (req.method === 'GET' && url.pathname === '/v1/blocks') {
        const token = url.searchParams.get('token') || ''
        const writerKey = url.searchParams.get('writerKey') || ''
        if (!token || !writerKey) {
          res.writeHead(400)
          res.end()
          return
        }
        const blocks = get(
          token,
          writerKey,
          Number(url.searchParams.get('fromSeq') || 0),
        )
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(
          JSON.stringify({
            blocks: blocks.map((b) => ({
              seq: b.seq,
              b64: Buffer.from(b.bytes).toString('base64'),
              storedAt: b.storedAt,
            })),
          }),
        )
        return
      }
      res.writeHead(404)
      res.end()
    } catch (err) {
      res.writeHead((err && err.statusCode) || 400)
      res.end()
    }
  })
}

if (require.main === module) {
  const port = Number(process.env.ORBITS_STORAGE_PORT || 8787)
  const server = createServer()
  server.listen(port, '127.0.0.1', () => {
    process.stdout.write('storage-peer ' + port + '\n')
  })
}

module.exports = {
  createServer,
  grant,
  put,
  get,
  tombstone,
  stats,
  sweep,
  rateOk,
  FORBIDDEN,
  MAX_BODY_BYTES,
  RATE_LIMIT,
  RATE_WINDOW_MS,
}

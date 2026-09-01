'use strict'

/**
 * Blind storage peer. Encrypted blocks only.
 * No remote JS. No plaintext, peer IDs, or keys in the protocol.
 */

const http = require('node:http')
const { URL } = require('node:url')

const FORBIDDEN = new Set([
  'plaintext',
  'text',
  'body',
  'peerId',
  'kek',
  'rootKey',
])

const caps = new Map()
const cores = new Map()

function grant(token, quotaBytes, retentionMs, expiresAt) {
  if (!token) throw new Error('anonymous writes are rejected')
  caps.set(token, { quotaBytes, retentionMs, expiresAt })
}

function put(token, writerKey, seq, bytes) {
  const cap = caps.get(token)
  if (!cap || Date.now() >= cap.expiresAt) throw new Error('capability rejected')
  const list = cores.get(writerKey) || []
  const used = list.reduce((n, b) => n + b.bytes.length, 0)
  if (used + bytes.length > cap.quotaBytes) throw new Error('quota exceeded')
  list.push({ seq, bytes, storedAt: Date.now() })
  cores.set(writerKey, list)
}

function get(token, writerKey, fromSeq) {
  const cap = caps.get(token)
  if (!cap || Date.now() >= cap.expiresAt) throw new Error('capability rejected')
  const now = Date.now()
  return (cores.get(writerKey) || []).filter(
    (b) => b.seq >= fromSeq && now - b.storedAt <= cap.retentionMs,
  )
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    req.on('data', (c) => chunks.push(c))
    req.on('end', () => resolve(Buffer.concat(chunks)))
    req.on('error', reject)
  })
}

function createServer(opts = {}) {
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
      if (req.method === 'POST' && url.pathname === '/v1/blocks') {
        const body = JSON.parse((await readBody(req)).toString('utf8'))
        for (const key of Object.keys(body)) {
          if (FORBIDDEN.has(key)) {
            res.writeHead(400)
            res.end()
            return
          }
        }
        put(body.token, body.writerKey, body.seq, Buffer.from(body.b64 || '', 'base64'))
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true }))
        return
      }
      if (req.method === 'GET' && url.pathname === '/v1/blocks') {
        const blocks = get(
          url.searchParams.get('token') || '',
          url.searchParams.get('writerKey') || '',
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
    } catch {
      res.writeHead(400)
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

module.exports = { createServer, grant, put, get, FORBIDDEN }

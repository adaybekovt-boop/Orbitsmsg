'use strict'

/**
 * Local opaque wake intake. Not APNs/FCM. Not a public gateway.
 * Rejects plaintext, names, peer IDs, conversation IDs.
 */

const http = require('node:http')

/** Keep in sync with OpaqueWake.forbiddenKeys in lib/push/opaque_wake.dart */
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
  'title',
  'senderName',
  'displayName',
  'peerId',
  'conversationId',
  'attachment',
  'mime',
  'fileName',
])

/**
 * Cycle-safe walk of objects/arrays. Rejects if any key is in FORBIDDEN,
 * including nested `{ meta: { fileKey } }` / `{ extra: { discoverySecret } }`.
 */
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

function createPushGateway() {
  const accepted = []
  const server = http.createServer(async (req, res) => {
    try {
      if (req.method === 'GET' && req.url === '/health') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true, role: 'wake', deployed: false }))
        return
      }
      if (req.method === 'POST' && req.url === '/v1/wake') {
        const chunks = []
        for await (const c of req) chunks.push(c)
        const body = JSON.parse(Buffer.concat(chunks).toString('utf8'))
        if (hasForbiddenKey(body)) {
          res.writeHead(400)
          res.end()
          return
        }
        if (!body.opaqueWakeToken || !body.collapseId || !body.protocolVersion) {
          res.writeHead(400)
          res.end()
          return
        }
        accepted.push(body)
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true, accepted: true, deployed: false }))
        return
      }
      res.writeHead(404)
      res.end()
    } catch {
      res.writeHead(400)
      res.end()
    }
  })
  server.accepted = accepted
  return server
}

module.exports = { createPushGateway, FORBIDDEN, hasForbiddenKey }

if (require.main === module) {
  const port = Number(process.env.ORBITS_PUSH_PORT || 8788)
  createPushGateway().listen(port, '127.0.0.1', () => {
    process.stdout.write('push-gateway ' + port + '\n')
  })
}

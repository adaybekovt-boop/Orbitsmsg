'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { createServer, issueCapability, VERSION } = require('./server')

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      resolve(`http://127.0.0.1:${port}`)
    })
  })
}

test('versioned deposit then drain after sender is gone', async () => {
  const secret = Buffer.alloc(32, 9)
  const server = createServer({ grantSecret: secret })
  const origin = await listen(server)
  const now = Date.now()
  const cap = issueCapability(secret, {
    tokenId: 'tok',
    mailboxId: 'mb-1',
    scopes: ['deposit', 'drain', 'ack', 'delete'],
    issuedAt: now - 10,
    notBefore: now - 10,
    expiresAt: now + 60_000,
    quotaBytes: 4096,
    retentionMs: 30_000,
  })
  const deposit = await fetch(`${origin}/v1/mailbox`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      v: VERSION,
      op: 'deposit',
      requestId: 'd1',
      issuedAt: now,
      capability: cap,
      mailboxId: 'mb-1',
      envelopeId: 'e1',
      ciphertextB64: Buffer.from('v2:a:b:c').toString('base64'),
    }),
  })
  assert.equal(deposit.status, 200)
  const drained = await fetch(`${origin}/v1/mailbox`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      v: VERSION,
      op: 'drain',
      requestId: 'r1',
      issuedAt: now,
      capability: cap,
      mailboxId: 'mb-1',
    }),
  })
  const body = await drained.json()
  assert.equal(body.ok, true)
  assert.equal(body.envelopes.length, 1)
  assert.equal(body.envelopes[0].envelopeId, 'e1')
  server.close()
})

test('plaintext and replay are rejected', async () => {
  const secret = Buffer.alloc(32, 8)
  const server = createServer({ grantSecret: secret })
  const origin = await listen(server)
  const now = Date.now()
  const cap = issueCapability(secret, {
    tokenId: 'tok',
    mailboxId: 'mb-1',
    scopes: ['deposit', 'drain'],
    issuedAt: now - 10,
    notBefore: now - 10,
    expiresAt: now + 60_000,
    quotaBytes: 4096,
    retentionMs: 30_000,
  })
  const plain = await fetch(`${origin}/v1/mailbox`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      v: VERSION,
      op: 'deposit',
      requestId: 'p1',
      issuedAt: now,
      capability: cap,
      mailboxId: 'mb-1',
      envelopeId: 'e-plain',
      ciphertextB64: Buffer.from(JSON.stringify({ plaintext: 'x' })).toString(
        'base64',
      ),
    }),
  })
  assert.equal(plain.status, 400)
  const req = {
    v: VERSION,
    op: 'deposit',
    requestId: 'same',
    issuedAt: now,
    capability: cap,
    mailboxId: 'mb-1',
    envelopeId: 'e2',
    ciphertextB64: Buffer.from('v2:a:b:c').toString('base64'),
  }
  const first = await fetch(`${origin}/v1/mailbox`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(req),
  })
  assert.equal(first.status, 200)
  const replay = await fetch(`${origin}/v1/mailbox`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(req),
  })
  assert.equal(replay.status, 401)
  server.close()
})

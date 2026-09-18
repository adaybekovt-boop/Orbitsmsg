'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {
  createServer,
  issueCapability,
  VERSION,
  wrapOpaqueEnvelope,
} = require('./server')

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      resolve(`http://127.0.0.1:${port}`)
    })
  })
}

function capFor(secret, now, mailboxId = 'mb-1') {
  return issueCapability(secret, {
    tokenId: 'tok',
    mailboxId,
    scopes: ['deposit', 'drain', 'ack', 'delete'],
    issuedAt: now - 10,
    notBefore: now - 10,
    expiresAt: now + 60_000,
    quotaBytes: 4096,
    retentionMs: 30_000,
  })
}

test('versioned deposit then drain after sender is gone', async () => {
  const secret = Buffer.alloc(32, 9)
  const server = createServer({ grantSecret: secret })
  const origin = await listen(server)
  const now = Date.now()
  const cap = capFor(secret, now)
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
      ciphertextB64: wrapOpaqueEnvelope(Buffer.from('v2:a:b:c')).toString('base64'),
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
  const cap = capFor(secret, now)
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
    ciphertextB64: wrapOpaqueEnvelope(Buffer.from('v2:a:b:c')).toString('base64'),
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

test('legacy /v1/blocks is not served', async () => {
  const server = createServer({ grantSecret: Buffer.alloc(32, 1) })
  const origin = await listen(server)
  const res = await fetch(`${origin}/v1/blocks`, { method: 'POST' })
  assert.equal(res.status, 404)
  server.close()
})

test('unknown fields and unframed bytes are rejected', async () => {
  const secret = Buffer.alloc(32, 4)
  const server = createServer({ grantSecret: secret })
  const origin = await listen(server)
  const now = Date.now()
  const cap = capFor(secret, now)
  const unknown = await fetch(`${origin}/v1/mailbox`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      v: VERSION,
      op: 'deposit',
      requestId: 'u1',
      issuedAt: now,
      capability: cap,
      mailboxId: 'mb-1',
      envelopeId: 'e',
      ciphertextB64: wrapOpaqueEnvelope(Buffer.from('v2:a:b:c')).toString('base64'),
      extra: true,
    }),
  })
  assert.equal(unknown.status, 400)
  const unframed = await fetch(`${origin}/v1/mailbox`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      v: VERSION,
      op: 'deposit',
      requestId: 'u2',
      issuedAt: now,
      capability: cap,
      mailboxId: 'mb-1',
      envelopeId: 'e',
      ciphertextB64: Buffer.from('v2:a:b:c').toString('base64'),
    }),
  })
  assert.equal(unframed.status, 400)
  server.close()
})

test('replay survives storage-peer restart', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-sp-'))
  const persistPath = path.join(dir, 'store.json')
  const secret = Buffer.alloc(32, 5)
  const first = createServer({ grantSecret: secret, persistPath })
  const origin1 = await listen(first)
  const now = Date.now()
  const cap = capFor(secret, now)
  const req = {
    v: VERSION,
    op: 'deposit',
    requestId: 'restart-1',
    issuedAt: now,
    capability: cap,
    mailboxId: 'mb-1',
    envelopeId: 'persist',
    ciphertextB64: wrapOpaqueEnvelope(Buffer.from('v2:keep')).toString('base64'),
  }
  const ok = await fetch(`${origin1}/v1/mailbox`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(req),
  })
  assert.equal(ok.status, 200)
  await new Promise((resolve) => first.close(resolve))
  const second = createServer({ grantSecret: secret, persistPath })
  const origin2 = await listen(second)
  const replay = await fetch(`${origin2}/v1/mailbox`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(req),
  })
  assert.equal(replay.status, 401)
  const drain = await fetch(`${origin2}/v1/mailbox`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      v: VERSION,
      op: 'drain',
      requestId: 'drain-after-restart',
      issuedAt: now,
      capability: cap,
      mailboxId: 'mb-1',
    }),
  })
  const body = await drain.json()
  assert.equal(body.envelopes.length, 1)
  await new Promise((resolve) => second.close(resolve))
  fs.rmSync(dir, { recursive: true, force: true })
})

test('corrupt persist fails closed', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-sp-bad-'))
  const persistPath = path.join(dir, 'store.json')
  fs.writeFileSync(persistPath, '{not-json')
  assert.throws(() => createServer({ persistPath }))
  fs.rmSync(dir, { recursive: true, force: true })
})

test('senderBucket isolates cores; peer id is rejected', async () => {
  const secret = Buffer.alloc(32, 7)
  const server = createServer({ grantSecret: secret })
  const origin = await listen(server)
  const now = Date.now()
  const cap = capFor(secret, now)
  const bucketFor = (sender) => require('node:crypto')
    .createHash('sha256')
    .update(`orbits-mailbox-sender-v1|mb-1|${sender}`)
    .digest('hex')
  const alice = bucketFor('ORBIT-AAAAAAAAAAAAAAAA')
  const carol = bucketFor('ORBIT-CCCCCCCCCCCCCCCC')
  assert.match(alice, /^[a-f0-9]{64}$/)

  const bad = await fetch(`${origin}/v1/mailbox`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      v: VERSION,
      op: 'deposit',
      requestId: 'bad-b',
      issuedAt: now,
      capability: cap,
      mailboxId: 'mb-1',
      envelopeId: 'e-bad',
      senderBucket: 'ORBIT-AAAAAAAAAAAAAAAA',
      ciphertextB64: wrapOpaqueEnvelope(Buffer.from('v2:a:b:c')).toString('base64'),
    }),
  })
  assert.equal(bad.status, 400)

  async function deposit(id, bucket, requestId) {
    return fetch(`${origin}/v1/mailbox`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        v: VERSION,
        op: 'deposit',
        requestId,
        issuedAt: now,
        capability: cap,
        mailboxId: 'mb-1',
        envelopeId: id,
        senderBucket: bucket,
        ciphertextB64: wrapOpaqueEnvelope(Buffer.from('v2:hdr:iv:' + id)).toString('base64'),
      }),
    })
  }
  assert.equal((await deposit('alice-1', alice, 'd-a')).status, 200)
  assert.equal((await deposit('carol-1', carol, 'd-c')).status, 200)

  async function drain(bucket, requestId) {
    const body = {
      v: VERSION, op: 'drain', requestId, issuedAt: now,
      capability: cap, mailboxId: 'mb-1',
    }
    if (bucket != null) body.senderBucket = bucket
    const res = await fetch(`${origin}/v1/mailbox`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    })
    return res.json()
  }
  const unbucketed = await drain(null, 'r0')
  assert.equal(unbucketed.envelopes.length, 0)
  const drainedAlice = await drain(alice, 'r-a')
  assert.equal(drainedAlice.envelopes.length, 1)
  assert.equal(drainedAlice.envelopes[0].envelopeId, 'alice-1')
  const drainedCarol = await drain(carol, 'r-c')
  assert.equal(drainedCarol.envelopes.length, 1)
  assert.equal(drainedCarol.envelopes[0].envelopeId, 'carol-1')
  server.close()
})

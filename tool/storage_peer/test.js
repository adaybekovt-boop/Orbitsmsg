'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const http = require('node:http')
const { createServer, hasForbiddenKey, tokenIsSafe, sha256Hex } = require('./server.js')

const ADMIN = 'lab-admin'

function hex32(fill = 1) {
  return Buffer.alloc(32, fill).toString('hex')
}

function request(port, { method, path, body, headers }) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { hostname: '127.0.0.1', port, method, path, headers: headers || {} },
      (res) => {
        const chunks = []
        res.on('data', (c) => chunks.push(c))
        res.on('end', () =>
          resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }),
        )
      },
    )
    req.on('error', reject)
    if (body) req.write(JSON.stringify(body))
    req.end()
  })
}

function grantBody(queueId, readFill = 2, depositFill = 3) {
  const readCap = hex32(readFill)
  const depositCap = hex32(depositFill)
  return {
    queueId,
    readCapHash: sha256Hex(Buffer.from(readCap, 'hex')),
    depositCapHash: sha256Hex(Buffer.from(depositCap, 'hex')),
    expiresAt: Date.now() + 60 * 1000,
    readCap,
    depositCap,
  }
}

function blockBody(queueId, depositCap, bytes) {
  return {
    queueId,
    depositCap,
    block: {
      bytes: Buffer.from(bytes).toString('base64'),
      blockHash: sha256Hex(Buffer.from(bytes)),
    },
  }
}

test('HTTP storage peer grants with admin, stores ciphertext, rejects stranger', async (t) => {
  const server = createServer({ adminToken: ADMIN })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise((resolve) => server.close(resolve)))
  const port = server.address().port
  const queueId = hex32(9)
  const g = grantBody(queueId)

  const anon = await request(port, {
    method: 'POST',
    path: '/v1/grant',
    body: { queueId, readCapHash: g.readCapHash, depositCapHash: g.depositCapHash, expiresAt: g.expiresAt },
  })
  assert.equal(anon.status, 403)

  const granted = await request(port, {
    method: 'POST',
    path: '/v1/grant',
    headers: { 'x-orbits-admin-token': ADMIN },
    body: {
      queueId,
      readCapHash: g.readCapHash,
      depositCapHash: g.depositCapHash,
      expiresAt: g.expiresAt,
    },
  })
  assert.equal(granted.status, 200)

  const rereg = await request(port, {
    method: 'POST',
    path: '/v1/grant',
    headers: { 'x-orbits-admin-token': ADMIN },
    body: {
      queueId,
      readCapHash: g.readCapHash,
      depositCapHash: g.depositCapHash,
      expiresAt: g.expiresAt,
    },
  })
  assert.equal(rereg.status, 403)

  const plain = await request(port, {
    method: 'POST',
    path: '/v1/blocks',
    body: { ...blockBody(queueId, g.depositCap, [1, 2, 3]), plaintext: 'nope' },
  })
  assert.equal(plain.status, 400)

  const put = await request(port, {
    method: 'POST',
    path: '/v1/blocks',
    body: blockBody(queueId, g.depositCap, [1, 2, 3]),
  })
  assert.equal(put.status, 200)
  assert.equal(JSON.parse(put.body).seq, 1)

  const replay = await request(port, {
    method: 'POST',
    path: '/v1/blocks',
    body: blockBody(queueId, g.depositCap, [1, 2, 3]),
  })
  assert.equal(replay.status, 409)

  const depositorRead = await request(port, {
    method: 'GET',
    path: `/v1/blocks?queueId=${queueId}&readCap=${g.depositCap}`,
  })
  assert.equal(depositorRead.status, 403)

  const stranger = await request(port, {
    method: 'GET',
    path: `/v1/blocks?queueId=${queueId}&readCap=${hex32(8)}`,
  })
  assert.equal(stranger.status, 403)

  const got = await request(port, {
    method: 'GET',
    path: `/v1/blocks?queueId=${queueId}&readCap=${g.readCap}`,
  })
  assert.equal(got.status, 200)
  const json = JSON.parse(got.body)
  assert.equal(json.blocks.length, 1)
  assert.equal(json.blocks[0].bytes, Buffer.from([1, 2, 3]).toString('base64'))
  assert.ok(!JSON.stringify(json).includes('peerId'))
  assert.ok(!JSON.stringify(json).includes('writerKey'))

  const blobs = server._orbitsStore.storedBlobs(queueId)
  assert.equal(blobs.length, 1)
  assert.deepEqual(Buffer.from(blobs[0]), Buffer.from([1, 2, 3]))

  const st = await request(port, {
    method: 'GET',
    path: `/v1/stats?queueId=${queueId}&readCap=${g.readCap}`,
  })
  assert.equal(st.status, 200)
  const statsBody = JSON.parse(st.body)
  assert.equal(statsBody.pendingCount, 1)
  assert.equal(statsBody.usedBytes, 3)

  const strangerStats = await request(port, {
    method: 'GET',
    path: `/v1/stats?queueId=${queueId}&readCap=${hex32(8)}`,
  })
  assert.equal(strangerStats.status, 403)

  const tomb = await request(port, {
    method: 'POST',
    path: '/v1/tombstone',
    body: { queueId, readCap: hex32(8), seq: 1 },
  })
  assert.equal(tomb.status, 403)

  const tombOk = await request(port, {
    method: 'POST',
    path: '/v1/tombstone',
    body: { queueId, readCap: g.readCap, seq: 1 },
  })
  assert.equal(tombOk.status, 200)
  const after = await request(port, {
    method: 'GET',
    path: `/v1/blocks?queueId=${queueId}&readCap=${g.readCap}`,
  })
  assert.equal(JSON.parse(after.body).blocks.length, 0)
})

test('expired grant and fake caps are rejected', async (t) => {
  let now = Date.now()
  const server = createServer({ adminToken: ADMIN, nowMs: () => now })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise((resolve) => server.close(resolve)))
  const port = server.address().port
  const queueId = hex32(4)
  const g = grantBody(queueId)
  const granted = await request(port, {
    method: 'POST',
    path: '/v1/grant',
    headers: { 'x-orbits-admin-token': ADMIN },
    body: {
      queueId,
      readCapHash: g.readCapHash,
      depositCapHash: g.depositCapHash,
      expiresAt: now + 20,
    },
  })
  assert.equal(granted.status, 200)
  now += 50
  const put = await request(port, {
    method: 'POST',
    path: '/v1/blocks',
    body: blockBody(queueId, g.depositCap, [1]),
  })
  assert.equal(put.status, 403)
  const got = await request(port, {
    method: 'GET',
    path: `/v1/blocks?queueId=${queueId}&readCap=${g.readCap}`,
  })
  assert.equal(got.status, 403)
})

test('quota exceeded and writerKey/peerId keys are rejected', async (t) => {
  const server = createServer({ adminToken: ADMIN })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise((resolve) => server.close(resolve)))
  const port = server.address().port
  const queueId = hex32(5)
  const g = grantBody(queueId)
  await request(port, {
    method: 'POST',
    path: '/v1/grant',
    headers: { 'x-orbits-admin-token': ADMIN },
    body: {
      queueId,
      readCapHash: g.readCapHash,
      depositCapHash: g.depositCapHash,
      quotaBytes: 2,
      expiresAt: Date.now() + 60 * 1000,
    },
  })
  const over = await request(port, {
    method: 'POST',
    path: '/v1/blocks',
    body: blockBody(queueId, g.depositCap, [1, 2, 3]),
  })
  assert.equal(over.status, 400)

  const leaked = await request(port, {
    method: 'POST',
    path: '/v1/blocks',
    body: { ...blockBody(queueId, g.depositCap, [1]), writerKey: 'w', peerId: 'ORBIT-AA' },
  })
  assert.equal(leaked.status, 400)
})

test('hasForbiddenKey walks nested objects/arrays and is cycle-safe', () => {
  assert.equal(hasForbiddenKey({ queueId: hex32(1) }), false)
  assert.equal(hasForbiddenKey({ meta: { fileKey: 'x' } }), true)
  assert.equal(hasForbiddenKey({ extra: { peerId: 'ORBIT-AA' } }), true)
  assert.equal(hasForbiddenKey({ extra: { plaintext: 'nope' } }), true)
  assert.equal(hasForbiddenKey({ items: [{ fileKey: 'x' }] }), true)
  assert.equal(hasForbiddenKey({ note: 'fileKey' }), false)
  const cyclic = { queueId: hex32(1) }
  cyclic.self = cyclic
  assert.equal(hasForbiddenKey(cyclic), false)
})

test('tokenIsSafe rejects empty, URL, peerId, writerKey, and secret fragments', () => {
  assert.equal(tokenIsSafe('cap'), true)
  assert.equal(tokenIsSafe(''), false)
  assert.equal(tokenIsSafe('https://evil/tok'), false)
  assert.equal(tokenIsSafe('ftp://x'), false)
  assert.equal(tokenIsSafe('tok-peerId'), false)
  assert.equal(tokenIsSafe('x-fileKey'), false)
  assert.equal(tokenIsSafe('x-rootKey'), false)
  assert.equal(tokenIsSafe('x-discoverySecret'), false)
  assert.equal(tokenIsSafe('x-writerKey'), false)
})

test('rate limit returns 429', async (t) => {
  const server = createServer({ adminToken: ADMIN })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise((resolve) => server.close(resolve)))
  const port = server.address().port
  const queueId = hex32(6)
  const g = grantBody(queueId)
  await request(port, {
    method: 'POST',
    path: '/v1/grant',
    headers: { 'x-orbits-admin-token': ADMIN },
    body: {
      queueId,
      readCapHash: g.readCapHash,
      depositCapHash: g.depositCapHash,
      quotaBytes: 1024 * 1024,
      expiresAt: Date.now() + 60 * 1000,
    },
  })
  let last = 200
  for (let i = 0; i < 40; i++) {
    const res = await request(port, {
      method: 'POST',
      path: '/v1/blocks',
      body: blockBody(queueId, g.depositCap, [i]),
    })
    last = res.status
    if (res.status === 429) break
  }
  assert.equal(last, 429)
})

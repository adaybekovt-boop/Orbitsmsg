'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const http = require('node:http')
const { createServer } = require('./server.js')

function request(port, { method, path, body }) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { hostname: '127.0.0.1', port, method, path },
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

test('HTTP storage peer grants, rejects plaintext/anonymous, stores ciphertext', async (t) => {
  const server = createServer({ token: 'cap-1' })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise((resolve) => server.close(resolve)))
  const port = server.address().port

  const anon = await request(port, {
    method: 'POST',
    path: '/v1/grant',
    body: { token: '' },
  })
  assert.equal(anon.status, 400)

  const plain = await request(port, {
    method: 'POST',
    path: '/v1/blocks',
    body: {
      token: 'cap-1',
      writerKey: 'w',
      seq: 0,
      b64: Buffer.from([1, 2, 3]).toString('base64'),
      plaintext: 'nope',
    },
  })
  assert.equal(plain.status, 400)

  const put = await request(port, {
    method: 'POST',
    path: '/v1/blocks',
    body: {
      token: 'cap-1',
      writerKey: 'w',
      seq: 0,
      b64: Buffer.from([1, 2, 3]).toString('base64'),
    },
  })
  assert.equal(put.status, 200)

  const got = await request(port, {
    method: 'GET',
    path: '/v1/blocks?token=cap-1&writerKey=w&fromSeq=0',
  })
  assert.equal(got.status, 200)
  const json = JSON.parse(got.body)
  assert.equal(json.blocks.length, 1)
  assert.equal(json.blocks[0].b64, Buffer.from([1, 2, 3]).toString('base64'))

  const st = await request(port, {
    method: 'GET',
    path: '/v1/stats?token=cap-1&writerKey=w',
  })
  assert.equal(st.status, 200)
  const statsBody = JSON.parse(st.body)
  assert.equal(statsBody.pendingCount, 1)
  assert.equal(statsBody.usedBytes, 3)

  const tomb = await request(port, {
    method: 'POST',
    path: '/v1/tombstone',
    body: { token: 'cap-1', writerKey: 'w', seq: 0 },
  })
  assert.equal(tomb.status, 200)
  const after = await request(port, {
    method: 'GET',
    path: '/v1/blocks?token=cap-1&writerKey=w&fromSeq=0',
  })
  assert.equal(JSON.parse(after.body).blocks.length, 0)
})

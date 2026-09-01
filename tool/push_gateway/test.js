'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const http = require('node:http')
const { createPushGateway } = require('./server.js')

function post(port, body) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { hostname: '127.0.0.1', port, method: 'POST', path: '/v1/wake' },
      (res) => {
        const chunks = []
        res.on('data', (c) => chunks.push(c))
        res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }))
      },
    )
    req.on('error', reject)
    req.write(JSON.stringify(body))
    req.end()
  })
}

test('opaque wake gateway rejects plaintext and does not claim deploy', async (t) => {
  const server = createPushGateway()
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise((resolve) => server.close(resolve)))
  const port = server.address().port
  const bad = await post(port, {
    opaqueWakeToken: 'tok',
    collapseId: 'c1',
    protocolVersion: 1,
    text: 'hi',
  })
  assert.equal(bad.status, 400)
  const peer = await post(port, {
    opaqueWakeToken: 'tok',
    collapseId: 'c1',
    protocolVersion: 1,
    peerId: 'ORBIT-AA',
  })
  assert.equal(peer.status, 400)
  const ok = await post(port, {
    opaqueWakeToken: 'tok',
    collapseId: 'c1',
    protocolVersion: 1,
  })
  assert.equal(ok.status, 200)
  const json = JSON.parse(ok.body)
  assert.equal(json.deployed, false)
  assert.equal(server.accepted.length, 1)
})

'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const http = require('node:http')
const { createPushGateway, hasForbiddenKey, tokenIsSafe } = require('./server.js')

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

test('opaque wake gateway rejects fileKey and discoverySecret', async (t) => {
  const server = createPushGateway()
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise((resolve) => server.close(resolve)))
  const port = server.address().port
  const fileKey = await post(port, {
    opaqueWakeToken: 'tok',
    collapseId: 'c1',
    protocolVersion: 1,
    fileKey: 'must-not-relay',
  })
  assert.equal(fileKey.status, 400)
  const discovery = await post(port, {
    opaqueWakeToken: 'tok',
    collapseId: 'c1',
    protocolVersion: 1,
    discoverySecret: 'must-not-relay',
  })
  assert.equal(discovery.status, 400)
  assert.equal(server.accepted.length, 0)
})

test('hasForbiddenKey walks nested objects/arrays and is cycle-safe', () => {
  assert.equal(hasForbiddenKey({ opaqueWakeToken: 'tok' }), false)
  assert.equal(hasForbiddenKey({ meta: { fileKey: 'x' } }), true)
  assert.equal(hasForbiddenKey({ extra: { text: 'hi' } }), true)
  assert.equal(hasForbiddenKey({ extra: { discoverySecret: 'y' } }), true)
  assert.equal(hasForbiddenKey({ items: [{ fileKey: 'x' }] }), true)
  assert.equal(hasForbiddenKey({ note: 'fileKey' }), false)
  const cyclic = { collapseId: 'c1' }
  cyclic.self = cyclic
  assert.equal(hasForbiddenKey(cyclic), false)
  const cyclicForbidden = { extra: {} }
  cyclicForbidden.extra.loop = cyclicForbidden
  cyclicForbidden.extra.discoverySecret = 'y'
  assert.equal(hasForbiddenKey(cyclicForbidden), true)
})

test('opaque wake gateway rejects nested fileKey/text/discoverySecret', async (t) => {
  const server = createPushGateway()
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise((resolve) => server.close(resolve)))
  const port = server.address().port

  const health = await new Promise((resolve, reject) => {
    http
      .get({ hostname: '127.0.0.1', port, path: '/health' }, (res) => {
        const chunks = []
        res.on('data', (c) => chunks.push(c))
        res.on('end', () =>
          resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }),
        )
      })
      .on('error', reject)
  })
  assert.equal(health.status, 200)
  assert.equal(JSON.parse(health.body).deployed, false)

  const nestedFileKey = await post(port, {
    opaqueWakeToken: 'tok',
    collapseId: 'c1',
    protocolVersion: 1,
    meta: { fileKey: 'x' },
  })
  assert.equal(nestedFileKey.status, 400)

  const nestedText = await post(port, {
    opaqueWakeToken: 'tok',
    collapseId: 'c1',
    protocolVersion: 1,
    extra: { text: 'hi' },
  })
  assert.equal(nestedText.status, 400)

  const nestedDiscovery = await post(port, {
    opaqueWakeToken: 'tok',
    collapseId: 'c1',
    protocolVersion: 1,
    extra: { discoverySecret: 'y' },
  })
  assert.equal(nestedDiscovery.status, 400)
  assert.equal(server.accepted.length, 0)

  const ok = await post(port, {
    opaqueWakeToken: 'tok',
    collapseId: 'c1',
    protocolVersion: 1,
  })
  assert.equal(ok.status, 200)
  const json = JSON.parse(ok.body)
  assert.equal(json.deployed, false)
  assert.equal(json.accepted, true)
  assert.equal(server.accepted.length, 1)
})

test('tokenIsSafe rejects empty, URL, and secret-fragment tokens', () => {
  assert.equal(tokenIsSafe(''), false)
  assert.equal(tokenIsSafe('https://evil'), false)
  assert.equal(tokenIsSafe('peerId'), false)
  assert.equal(tokenIsSafe('fileKey'), false)
  assert.equal(tokenIsSafe('rootKey'), false)
  assert.equal(tokenIsSafe('discoverySecret'), false)
  assert.equal(tokenIsSafe('tok'), true)
})

test('opaque wake gateway rejects URL and secret-fragment opaqueWakeToken', async (t) => {
  const server = createPushGateway()
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise((resolve) => server.close(resolve)))
  const port = server.address().port

  const urlToken = await post(port, {
    opaqueWakeToken: 'https://evil',
    collapseId: 'c1',
    protocolVersion: 1,
  })
  assert.equal(urlToken.status, 400)

  const fragmentToken = await post(port, {
    opaqueWakeToken: 'has-fileKey',
    collapseId: 'c1',
    protocolVersion: 1,
  })
  assert.equal(fragmentToken.status, 400)
  assert.equal(server.accepted.length, 0)

  const ok = await post(port, {
    opaqueWakeToken: 'tok',
    collapseId: 'c1',
    protocolVersion: 1,
  })
  assert.equal(ok.status, 200)
  const json = JSON.parse(ok.body)
  assert.equal(json.deployed, false)
  assert.equal(json.accepted, true)
  assert.equal(server.accepted.length, 1)
})

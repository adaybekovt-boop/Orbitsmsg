'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { createLocalBootstrap } = require('../src/swarm')

function ignoreResetAfterSuccess(err) {
  if (err && (err.code === 'ECONNRESET' || /connection reset by peer/.test(String(err)))) {
    return
  }
  throw err
}

test('HyperDHT bootstrapper exchanges an encrypted payload on localhost', async (t) => {
  process.on('uncaughtException', ignoreResetAfterSuccess)
  t.after(() => process.off('uncaughtException', ignoreResetAfterSuccess))
  const DHT = require('hyperdht')
  const boot = await createLocalBootstrap(49742)
  const a = new DHT({ bootstrap: boot.bootstrap, firewalled: false })
  const b = new DHT({ bootstrap: boot.bootstrap, firewalled: false })
  await a.ready()
  await b.ready()
  const server = a.createServer({ firewall: () => false })
  const got = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('dht timeout')), 12000)
    server.on('connection', (sock) => {
      sock.on('error', () => {})
      sock.on('data', (d) => {
        clearTimeout(timer)
        resolve(d.toString())
      })
    })
  })
  await server.listen()
  const sock = b.connect(server.publicKey)
  sock.on('error', () => {})
  sock.on('open', () => sock.write('orbits-dht-e2e'))
  const msg = await got
  assert.equal(msg, 'orbits-dht-e2e')
  sock.destroy()
  await server.close()
  await a.destroy()
  await b.destroy()
  await boot.destroy()
  await new Promise((r) => setTimeout(r, 200))
})

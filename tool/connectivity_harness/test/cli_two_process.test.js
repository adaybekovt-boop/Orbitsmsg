'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { createHash } = require('node:crypto')
const { hashPath } = require('../src/worklet')
const { contactDiscoveryTopic } = require('../src/discovery')
const { createLocalBootstrap } = require('../src/swarm')

const CLI = path.join(__dirname, '..', 'src', 'cli.js')

function spawnCli(args) {
  const child = spawn(process.execPath, [CLI, ...args], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env },
  })
  child.stdoutAcc = ''
  child.stderrAcc = ''
  child.stdout.on('data', (c) => {
    child.stdoutAcc += c.toString()
  })
  child.stderr.on('data', (c) => {
    child.stderrAcc += c.toString()
  })
  return child
}

function waitOutput(child, re, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(
        new Error(
          'cli output timeout matching ' +
            re +
            ' stdout=' +
            child.stdoutAcc.slice(0, 600) +
            ' stderr=' +
            child.stderrAcc.slice(0, 400),
        ),
      )
    }, timeoutMs)
    const check = () => {
      if (re.test(child.stdoutAcc)) {
        clearTimeout(timer)
        child.stdout.off('data', onData)
        resolve(child.stdoutAcc)
      }
    }
    const onData = () => check()
    child.stdout.on('data', onData)
    check()
  })
}

function waitExit(child, timeoutMs) {
  return new Promise((resolve, reject) => {
    if (child.exitCode != null) {
      resolve(child.exitCode)
      return
    }
    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL')
      } catch {
        // already gone
      }
      reject(new Error('cli exit timeout stderr=' + child.stderrAcc.slice(0, 400)))
    }, timeoutMs)
    child.once('exit', (code) => {
      clearTimeout(timer)
      resolve(code)
    })
  })
}

function assertDiagnostics(file) {
  assert.equal(fs.existsSync(file), true, 'missing diagnostics ' + file)
  const diag = JSON.parse(fs.readFileSync(file, 'utf8'))
  assert.equal(diag.lifecycle, 'stopped')
  assert.ok(diag.totals && diag.totals.bytesSent > 0, 'bytesSent: ' + JSON.stringify(diag.totals))
  const peers = diag.peers && typeof diag.peers === 'object' ? Object.values(diag.peers) : []
  assert.ok(peers.length >= 1, 'expected last-known peers in diagnostics')
  for (const peer of peers) {
    assert.equal(peer.authenticated, true)
  }
  return diag
}

test('two-process CLI loopback echo, queued stdin, and 1 MiB send-file', { timeout: 30000 }, async (t) => {
  const secret = path.join(os.tmpdir(), 'orbits-cli-secret.bin')
  const diagA = path.join(os.tmpdir(), 'orbits-cli-a.json')
  const diagB = path.join(os.tmpdir(), 'orbits-cli-b.json')
  const incoming = path.join(os.tmpdir(), 'orbits-cli-incoming-' + process.pid)
  const src = path.join(os.tmpdir(), 'orbits-cli-1m.bin')
  fs.writeFileSync(secret, Buffer.alloc(32, 42))
  fs.mkdirSync(incoming, { recursive: true })
  const chunk = Buffer.alloc(1024 * 1024, 9)
  fs.writeFileSync(src, chunk)
  const digest = hashPath(src).digest
  assert.equal(digest, createHash('sha256').update(chunk).digest('hex'))

  const listen = spawnCli([
    'listen',
    '--backend',
    'loopback',
    '--secret-file',
    secret,
    '--timeout-ms',
    '12000',
    '--diagnostics-out',
    diagA,
    '--incoming-dir',
    incoming,
  ])
  const dialRef = { child: null }
  t.after(() => {
    try {
      listen.kill('SIGKILL')
    } catch {
      // gone
    }
    if (dialRef.child) {
      try {
        dialRef.child.kill('SIGKILL')
      } catch {
        // gone
      }
    }
  })
  const listenOut = await waitOutput(listen, /OK LISTENING /, 5000)
  const m = listenOut.match(/OK LISTENING \S+:(\d+)/)
  assert.ok(m, 'listen printed a port: ' + listenOut)
  const port = m[1]
  const dial = spawnCli([
    'dial',
    '127.0.0.1:' + port,
    '--backend',
    'loopback',
    '--secret-file',
    secret,
    '--timeout-ms',
    '12000',
    '--diagnostics-out',
    diagB,
  ])
  dialRef.child = dial
  dial.stdin.write('echo ping\n')
  await waitOutput(dial, /OK CONNECTED /, 5000)
  await waitOutput(dial, /OK ECHO ping/, 5000)
  await waitOutput(listen, /OK PEER connected /, 5000)
  dial.stdin.write('send-file ' + src + '\n')
  await waitOutput(dial, /OK FILE sent /, 15000)
  const fileLine = await waitOutput(
    listen,
    new RegExp('OK FILE received \\S+ 1048576 sha256=' + digest),
    15000,
  )
  assert.match(fileLine, new RegExp('path=' + incoming.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  dial.stdin.write('shutdown\n')
  await waitOutput(listen, /OK PEER disconnected /, 5000)
  listen.stdin.write('shutdown\n')
  const [listenCode, dialCode] = await Promise.all([waitExit(listen, 8000), waitExit(dial, 8000)])
  assert.equal(dialCode, 0, 'dial stderr=' + dial.stderrAcc)
  assert.equal(listenCode, 0, 'listen stderr=' + listen.stderrAcc)
  assertDiagnostics(diagA)
  assertDiagnostics(diagB)
})

test('--help and -h print usage and exit 0', async () => {
  for (const flag of ['--help', '-h']) {
    const child = spawnCli([flag])
    const code = await waitExit(child, 3000)
    assert.equal(code, 0, flag + ' stderr=' + child.stderrAcc)
    assert.match(child.stdoutAcc, /Usage:/)
    assert.doesNotMatch(child.stderrAcc, /unknown flag/)
  }
})

test('CLI refuses --secret-file shorter than 32 bytes with non-zero exit', async () => {
  const short = path.join(os.tmpdir(), 'orbits-cli-short-secret.bin')
  fs.writeFileSync(short, Buffer.alloc(16, 1))
  const child = spawnCli([
    'listen',
    '--backend',
    'loopback',
    '--secret-file',
    short,
    '--timeout-ms',
    '1000',
  ])
  const code = await waitExit(child, 4000)
  assert.notEqual(code, 0)
  assert.match(child.stderrAcc, /32 bytes|discoverySecret/)
})

test('derived discovery topic is not HASH(peerId)', () => {
  const secret = Buffer.alloc(32, 42)
  const topic = contactDiscoveryTopic(secret)
  const hashedPeer = createHash('sha256').update('HARNEST-CLI').digest()
  assert.notDeepEqual(topic, hashedPeer)
  assert.notEqual(topic.toString('hex'), hashedPeer.toString('hex'))
})

function hyperswarmAvailable() {
  try {
    require('hyperswarm')
    require('hyperdht')
    return true
  } catch {
    return false
  }
}

const skipHs = hyperswarmAvailable() ? false : 'hyperswarm/hyperdht not installed'

test(
  'hyperswarm CLI listen topic is secret-derived, not HASH(peerId)',
  { skip: skipHs, timeout: 20000 },
  async (t) => {
    const local = await createLocalBootstrap()
    t.after(async () => {
      try {
        await local.destroy()
      } catch {
        // ignore
      }
    })
    const boot = local.bootstrap[0]
    assert.equal(boot.host, '127.0.0.1')
    const secret = path.join(os.tmpdir(), 'orbits-cli-hs-secret.bin')
    fs.writeFileSync(secret, Buffer.alloc(32, 7))
    const expected = contactDiscoveryTopic(Buffer.alloc(32, 7)).toString('hex')
    const hashedPeer = createHash('sha256').update('HARNEST-CLI').digest('hex')
    assert.notEqual(expected, hashedPeer)
    const child = spawnCli([
      'listen',
      '--backend',
      'hyperswarm',
      '--secret-file',
      secret,
      '--bootstrap',
      boot.host + ':' + boot.port,
      '--timeout-ms',
      '8000',
    ])
    t.after(() => {
      try {
        child.kill('SIGKILL')
      } catch {
        // gone
      }
    })
    const out = await waitOutput(child, /OK LISTENING hyperswarm TOPIC /, 15000)
    const m = out.match(/TOPIC ([0-9a-f]+)/)
    assert.ok(m)
    assert.equal(m[1], expected)
    assert.notEqual(m[1], hashedPeer)
    child.stdin.write('shutdown\n')
    await waitExit(child, 8000)
  },
)

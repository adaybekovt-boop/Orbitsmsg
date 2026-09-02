'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

function spawnCli(args) {
  const cli = path.join(__dirname, '..', 'src', 'cli.js')
  const child = spawn(process.execPath, [cli, ...args], {
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
            child.stdoutAcc.slice(0, 400) +
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

test('two-process CLI loopback echo exits 0', { timeout: 20000 }, async (t) => {
  const secret = path.join(os.tmpdir(), 'orbits-cli-secret.bin')
  const diagA = path.join(os.tmpdir(), 'orbits-cli-a.json')
  const diagB = path.join(os.tmpdir(), 'orbits-cli-b.json')
  fs.writeFileSync(secret, Buffer.alloc(32, 42))
  const listen = spawnCli([
    'listen',
    '--backend',
    'loopback',
    '--secret-file',
    secret,
    '--timeout-ms',
    '8000',
    '--diagnostics-out',
    diagA,
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
    '8000',
    '--diagnostics-out',
    diagB,
  ])
  dialRef.child = dial
  await waitOutput(dial, /OK CONNECTED /, 5000)
  dial.stdin.write('echo ping\n')
  await waitOutput(dial, /OK ECHO ping/, 5000)
  dial.stdin.write('shutdown\n')
  listen.stdin.write('shutdown\n')
  const [listenCode, dialCode] = await Promise.all([waitExit(listen, 5000), waitExit(dial, 5000)])
  assert.equal(dialCode, 0, 'dial stderr=' + dial.stderrAcc)
  assert.equal(listenCode, 0, 'listen stderr=' + listen.stderrAcc)
  if (fs.existsSync(diagB)) {
    const diag = JSON.parse(fs.readFileSync(diagB, 'utf8'))
    assert.equal(diag.backend, 'loopback')
  }
})

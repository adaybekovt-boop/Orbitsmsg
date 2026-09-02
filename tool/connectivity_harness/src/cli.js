#!/usr/bin/env node
'use strict'

/**
 * Phase 1 connectivity harness CLI. Isolated from the Flutter product.
 * Never accepts a discovery secret on argv. Never fetches remote JS.
 */

const process =
  typeof globalThis.process !== 'undefined'
    ? globalThis.process
    : require('bare-process')

const fs = require('node:fs')
const path = require('node:path')
const { Worklet } = require('./worklet')
const { contactDiscoveryTopic, asSecret } = require('./discovery')

function usage() {
  return [
    'Usage:',
    '  node src/cli.js listen [--backend loopback|hyperswarm] --secret-file <path> [options]',
    '  node src/cli.js dial <host:port|topic-hex> --secret-file <path> [options]',
    '',
    'Options:',
    '  --backend loopback|hyperswarm   default loopback',
    '  --secret-file <path>            32+ raw bytes; never pass the secret on argv',
    '  --timeout-ms <n>                connect timeout (default 10000)',
    '  --diagnostics-out <path>        write diagnostics JSON on exit',
    '  --listen-host <addr>            loopback bind (default 127.0.0.1)',
    '  --bootstrap <host:port>         Hyperswarm bootstrap (repeatable; required for that backend)',
    '',
    'Stdin line protocol after listen/dial:',
    '  echo [text]',
    '  send-file <path>',
    '  resume-file <id> <path>',
    '  diagnostics',
    '  shutdown',
  ].join('\n')
}

function fail(message, code) {
  process.stderr.write(String(message) + '\n')
  process.exit(code == null ? 1 : code)
}

function parseArgs(argv) {
  const out = {
    backend: 'loopback',
    timeoutMs: 10000,
    bootstrap: [],
    listenHost: '127.0.0.1',
    positional: [],
  }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--backend') {
      out.backend = String(argv[++i] || '')
    } else if (a === '--secret-file') {
      out.secretFile = argv[++i]
    } else if (a === '--timeout-ms') {
      out.timeoutMs = Number(argv[++i])
    } else if (a === '--diagnostics-out') {
      out.diagnosticsOut = argv[++i]
    } else if (a === '--listen-host') {
      out.listenHost = String(argv[++i] || '')
    } else if (a === '--bootstrap') {
      out.bootstrap.push(String(argv[++i] || ''))
    } else if (a === '--secret' || a === '--discovery-secret' || a === '--discoverySecret') {
      throw new Error('refusing secret on argv; use --secret-file')
    } else if (a.startsWith('--')) {
      throw new Error('unknown flag ' + a)
    } else {
      out.positional.push(a)
    }
  }
  if (out.backend !== 'loopback' && out.backend !== 'hyperswarm') {
    throw new Error('backend must be loopback or hyperswarm')
  }
  return out
}

function readSecretFile(filePath) {
  if (!filePath) throw new Error('missing --secret-file')
  if (String(filePath).includes('://')) throw new Error('secret-file refuses :// path')
  const resolved = path.resolve(filePath)
  const buf = fs.readFileSync(resolved)
  return asSecret(buf)
}

function parseBootstrap(entries) {
  const out = []
  for (const raw of entries) {
    if (!raw) continue
    if (String(raw).includes('://')) throw new Error('bootstrap refuses ://')
    const idx = raw.lastIndexOf(':')
    if (idx <= 0) throw new Error('bootstrap must be host:port')
    const host = raw.slice(0, idx)
    const port = Number(raw.slice(idx + 1))
    if (!host || !Number.isFinite(port)) throw new Error('bootstrap must be host:port')
    out.push({ host, port })
  }
  return out
}

function firstPeer(worklet) {
  const id = Array.from(worklet._peers.keys())[0]
  if (!id) throw new Error('no peer connected')
  return id
}

function waitEvent(worklet, name, pred, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(name + ' timeout')), timeoutMs)
    if (typeof timer.unref === 'function') timer.unref()
    const prev = worklet._emit
    worklet._emit = (ev, payload) => {
      prev(ev, payload)
      if (ev === name && (!pred || pred(payload))) {
        clearTimeout(timer)
        worklet._emit = prev
        resolve(payload)
      }
    }
  })
}

async function writeDiagnostics(worklet, dest) {
  if (!dest) return
  if (String(dest).includes('://')) throw new Error('diagnostics-out refuses :// path')
  fs.writeFileSync(path.resolve(dest), JSON.stringify(worklet.diagnostics(), null, 2))
}

async function main() {
  let args
  try {
    args = parseArgs(process.argv.slice(2))
  } catch (err) {
    process.stderr.write(usage() + '\n')
    fail(err.message)
  }
  const cmd = args.positional[0]
  if (!cmd || cmd === '-h' || cmd === '--help' || cmd === 'help') {
    process.stdout.write(usage() + '\n')
    process.exit(cmd && cmd !== 'help' && cmd !== '-h' && cmd !== '--help' ? 1 : 0)
  }
  if (cmd !== 'listen' && cmd !== 'dial') {
    fail('unknown command ' + cmd + '\n' + usage())
  }

  let secret
  try {
    secret = readSecretFile(args.secretFile)
  } catch (err) {
    fail(err.message)
  }

  if (args.diagnosticsOut && String(args.diagnosticsOut).includes('://')) {
    fail('diagnostics-out refuses :// path')
  }
  if (args.listenHost && String(args.listenHost).includes('://')) {
    fail('listen-host refuses :// path')
  }

  const bootstrap = parseBootstrap(args.bootstrap)
  if (args.backend === 'hyperswarm' && bootstrap.length === 0) {
    fail('hyperswarm backend requires --bootstrap host:port; refusing public DHT default')
  }

  const worklet = new Worklet({ backend: args.backend, harnessAuth: 'local' })
  let exiting = false
  const shutdown = async (code) => {
    if (exiting) return
    exiting = true
    try {
      await writeDiagnostics(worklet, args.diagnosticsOut)
    } catch (err) {
      process.stderr.write(String(err.message || err) + '\n')
    }
    try {
      await worklet.stop()
    } catch {
      // already stopped
    }
    process.exit(code)
  }

  process.on('SIGINT', () => {
    shutdown(0).catch(() => process.exit(1))
  })
  process.on('SIGTERM', () => {
    shutdown(0).catch(() => process.exit(1))
  })

  try {
    await worklet.start({
      peerId: 'HARNEST-CLI',
      discoverySecret: secret,
      diagnosticsEnabled: true,
      listenHost: args.listenHost,
      bootstrap,
    })
    await worklet.publish({ deviceId: 'cli' })
  } catch (err) {
    process.stderr.write(String(err.message || err) + '\n')
    await shutdown(1)
    return
  }

  const topicHex = worklet._topic ? worklet._topic.toString('hex') : ''

  try {
    if (cmd === 'listen') {
      const host = worklet._loop.host || args.listenHost || '127.0.0.1'
      const port = worklet._loop.port || 0
      process.stdout.write('OK LISTENING ' + host + ':' + port + ' TOPIC ' + topicHex + '\n')
    } else {
      const target = args.positional[1]
      if (!target) throw new Error('dial needs host:port or topic-hex')
      if (target.includes('://')) throw new Error('dial refuses :// target')
      const hostPort = target.match(/^([^:]+):(\d+)$/)
      if (hostPort) {
        const host = hostPort[1]
        const port = Number(hostPort[2])
        await worklet.connect({ host, port, timeoutMs: args.timeoutMs })
      } else if (/^[0-9a-fA-F]{64}$/.test(target)) {
        const expected = contactDiscoveryTopic(secret).toString('hex')
        if (target.toLowerCase() !== expected) {
          throw new Error('topic does not match secret-file (refusing HASH(peerId) or mismatched topic)')
        }
        await waitEvent(worklet, 'connected', null, args.timeoutMs)
      } else {
        throw new Error('dial target must be host:port or 64-char topic hex')
      }
      const peerId = Array.from(worklet._peers.keys())[0] || 'pending'
      process.stdout.write('OK CONNECTED ' + peerId + ' TOPIC ' + topicHex + '\n')
    }
  } catch (err) {
    process.stderr.write(String(err.message || err) + '\n')
    await shutdown(1)
    return
  }

  let chain = Promise.resolve()
  let buf = ''
  const handleLine = async (line) => {
    const trimmed = line.replace(/\r$/, '').trim()
    if (!trimmed) return
    const parts = trimmed.split(/\s+/)
    const c = parts[0]
    try {
      if (c === 'echo') {
        const text = parts.slice(1).join(' ') || 'ping'
        const peerId = firstPeer(worklet)
        const reply = waitEvent(
          worklet,
          'frame',
          (p) => p && p.body && p.body.type === 'harness-echo-reply',
          args.timeoutMs,
        )
        await worklet.send(peerId, 'message', {
          type: 'harness-echo',
          id: 'cli-' + Date.now(),
          text,
        })
        const got = await reply
        process.stdout.write('OK ECHO ' + got.body.text + '\n')
      } else if (c === 'send-file') {
        const filePath = parts.slice(1).join(' ')
        if (!filePath) throw new Error('send-file needs a path')
        if (filePath.includes('://')) throw new Error('send-file refuses :// path')
        const peerId = firstPeer(worklet)
        await worklet.sendFile(peerId, { path: filePath })
        process.stdout.write('OK FILE sent ' + filePath + '\n')
      } else if (c === 'resume-file') {
        const id = parts[1]
        const filePath = parts.slice(2).join(' ')
        if (!id || !filePath) throw new Error('resume-file needs id and path')
        if (id.includes('://') || filePath.includes('://')) {
          throw new Error('resume-file refuses :// path')
        }
        const peerId = firstPeer(worklet)
        await worklet.sendFile(peerId, { path: filePath, id })
        process.stdout.write('OK FILE resume ' + id + '\n')
      } else if (c === 'diagnostics') {
        process.stdout.write('OK DIAGNOSTICS ' + JSON.stringify(worklet.diagnostics()) + '\n')
      } else if (c === 'shutdown') {
        process.stdout.write('OK SHUTDOWN\n')
        await shutdown(0)
      } else {
        process.stdout.write('ERR unknown command ' + c + '\n')
      }
    } catch (err) {
      process.stdout.write('ERR ' + String(err.message || err) + '\n')
    }
  }

  process.stdin.on('data', (chunk) => {
    buf += chunk.toString('utf8')
    for (;;) {
      const i = buf.indexOf('\n')
      if (i < 0) break
      const line = buf.slice(0, i)
      buf = buf.slice(i + 1)
      chain = chain.then(() => handleLine(line)).catch((err) => {
        process.stdout.write('ERR ' + String(err.message || err) + '\n')
      })
    }
  })
  process.stdin.on('end', () => {
    if (!exiting) shutdown(0).catch(() => process.exit(1))
  })
}

if (require.main === module) {
  main().catch((err) => {
    process.stderr.write(String(err && err.message ? err.message : err) + '\n')
    process.exit(1)
  })
}

module.exports = { parseArgs, readSecretFile, parseBootstrap, usage }

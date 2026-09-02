#!/usr/bin/env node
'use strict'

/**
 * Phase 1 connectivity harness CLI. Isolated from the Flutter product.
 * Never accepts a discovery secret on argv. Never fetches remote JS.
 *
 * Hyperswarm: the discovery topic is always
 * HASH("orbits-contact-discovery-v1" || secret-file bytes).
 * `dial` ignores an optional host:port / topic-hex argument; it never
 * joins HASH(peerId) or an argv hex that is not the derived topic.
 */

const process =
  typeof globalThis.process !== 'undefined'
    ? globalThis.process
    : require('bare-process')

const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const { Worklet } = require('./worklet')
const { contactDiscoveryTopic, asSecret } = require('./discovery')

function usage() {
  return [
    'Usage:',
    '  node src/cli.js listen [--backend loopback|hyperswarm] --secret-file <path> [options]',
    '  node src/cli.js dial [host:port] --secret-file <path> [options]',
    '',
    'Options:',
    '  --backend loopback|hyperswarm   default loopback',
    '  --secret-file <path>            32+ raw bytes; never pass the secret on argv',
    '  --timeout-ms <n>                connect / queued-command timeout (default 10000)',
    '  --diagnostics-out <path>        write diagnostics JSON after stop (lifecycle stopped)',
    '  --listen-host <addr>            loopback bind (default 127.0.0.1)',
    '  --incoming-dir <path>           received files (default os.tmpdir()/orbits-harness-incoming)',
    '  --bootstrap <host:port>         Hyperswarm bootstrap (repeatable; required for that backend)',
    '  -h, --help                      print this help and exit 0',
    '',
    'Hyperswarm: topic is always derived from --secret-file. The dial target',
    'is optional and ignored (never used as a raw topic).',
    '',
    'Stdin lines are queued until a peer is connected and authenticated,',
    'then run in order. If no peer is ready after --timeout-ms:',
    '  ERR NOT_CONNECTED <cmd>  (exit non-zero; commands are never dropped silently)',
    '',
    'Stdin line protocol:',
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

function wantsHelp(argv) {
  return argv.some((a) => a === '--help' || a === '-h' || a === 'help')
}

function parseArgs(argv) {
  const out = {
    backend: 'loopback',
    timeoutMs: 10000,
    bootstrap: [],
    listenHost: '127.0.0.1',
    incomingDir: path.join(os.tmpdir(), 'orbits-harness-incoming'),
    positional: [],
  }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--help' || a === '-h' || a === 'help') {
      out.help = true
    } else if (a === '--backend') {
      out.backend = String(argv[++i] || '')
    } else if (a === '--secret-file') {
      out.secretFile = argv[++i]
    } else if (a === '--timeout-ms') {
      out.timeoutMs = Number(argv[++i])
    } else if (a === '--diagnostics-out') {
      out.diagnosticsOut = argv[++i]
    } else if (a === '--listen-host') {
      out.listenHost = String(argv[++i] || '')
    } else if (a === '--incoming-dir') {
      out.incomingDir = String(argv[++i] || '')
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
  for (const [id, peer] of worklet._peers) {
    if (peer && peer.authenticated) return id
  }
  const id = Array.from(worklet._peers.keys())[0]
  if (!id) throw new Error('no peer connected')
  return id
}

function hasReadyPeer(worklet) {
  for (const peer of worklet._peers.values()) {
    if (peer && peer.authenticated) return true
  }
  return false
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

function writeDiagnosticsSnapshot(snapshot, dest) {
  if (!dest) return
  if (String(dest).includes('://')) throw new Error('diagnostics-out refuses :// path')
  fs.writeFileSync(path.resolve(dest), JSON.stringify(snapshot, null, 2))
}

function placeIncoming(srcPath, incomingDir) {
  if (!srcPath || String(srcPath).includes('://')) return srcPath
  const destRoot = incomingDir || path.join(os.tmpdir(), 'orbits-harness-incoming')
  if (String(destRoot).includes('://')) throw new Error('incoming-dir refuses :// path')
  fs.mkdirSync(destRoot, { recursive: true })
  const dest = path.join(destRoot, path.basename(srcPath))
  if (path.resolve(srcPath) !== path.resolve(dest)) {
    fs.copyFileSync(srcPath, dest)
  }
  return dest
}

async function main() {
  const rawArgv = process.argv.slice(2)
  if (wantsHelp(rawArgv)) {
    process.stdout.write(usage() + '\n')
    process.exit(0)
  }

  let args
  try {
    args = parseArgs(rawArgv)
  } catch (err) {
    process.stderr.write(usage() + '\n')
    fail(err.message)
  }
  const cmd = args.positional[0]
  if (!cmd) {
    process.stdout.write(usage() + '\n')
    process.exit(0)
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
  if (args.incomingDir && String(args.incomingDir).includes('://')) {
    fail('incoming-dir refuses :// path')
  }

  const bootstrap = parseBootstrap(args.bootstrap)
  if (args.backend === 'hyperswarm' && bootstrap.length === 0) {
    fail('hyperswarm backend requires --bootstrap host:port; refusing public DHT default')
  }

  fs.mkdirSync(args.incomingDir, { recursive: true })

  let exiting = false
  let worklet = null
  let lastPeers = {}
  let lastTotals = { bytesSent: 0, bytesReceived: 0, connections: 0 }
  const pending = []
  let chain = Promise.resolve()
  let readyTimer = null
  let stdinEnded = false

  const shutdown = async (code) => {
    if (exiting) return
    exiting = true
    if (readyTimer) {
      clearTimeout(readyTimer)
      readyTimer = null
    }
    let snapshot = {
      lifecycle: 'stopped',
      backend: args.backend,
      peers: {},
      totals: { bytesSent: 0, bytesReceived: 0, connections: 0 },
    }
    if (worklet) {
      try {
        snapshot = worklet.diagnostics()
        if (!snapshot.peers || Object.keys(snapshot.peers).length === 0) {
          snapshot.peers = lastPeers
        }
        if (!snapshot.totals || !snapshot.totals.bytesSent) {
          snapshot.totals = lastTotals
        }
      } catch {
        snapshot.peers = lastPeers
        snapshot.totals = lastTotals
      }
      try {
        await worklet.stop()
      } catch {
        // already stopped
      }
      snapshot = { ...snapshot, lifecycle: 'stopped' }
    }
    try {
      writeDiagnosticsSnapshot(snapshot, args.diagnosticsOut)
    } catch (err) {
      process.stderr.write(String(err.message || err) + '\n')
    }
    process.exit(code)
  }

  process.on('SIGINT', () => {
    shutdown(0).catch(() => process.exit(1))
  })
  process.on('SIGTERM', () => {
    shutdown(0).catch(() => process.exit(1))
  })

  function rememberPeers() {
    if (!worklet) return
    try {
      const d = worklet.diagnostics()
      if (d.peers && Object.keys(d.peers).length > 0) lastPeers = d.peers
      if (d.totals) lastTotals = d.totals
    } catch {
      // ignore
    }
  }

  function failQueued(reason) {
    while (pending.length) {
      const line = pending.shift()
      const name = line.trim().split(/\s+/)[0] || line
      process.stdout.write('ERR ' + reason + ' ' + name + '\n')
    }
  }

  function startReadyTimer() {
    if (readyTimer || exiting) return
    readyTimer = setTimeout(() => {
      readyTimer = null
      failQueued('NOT_CONNECTED')
      shutdown(1).catch(() => process.exit(1))
    }, args.timeoutMs)
    if (readyTimer && typeof readyTimer.unref === 'function') readyTimer.unref()
  }

  function drainPending() {
    if (!worklet || !hasReadyPeer(worklet)) return
    if (readyTimer) {
      clearTimeout(readyTimer)
      readyTimer = null
    }
    while (pending.length) {
      const line = pending.shift()
      chain = chain.then(() => handleLine(line)).catch((err) => {
        process.stdout.write('ERR ' + String(err.message || err) + '\n')
      })
    }
    chain = chain.then(() => {
      if (stdinEnded && !exiting) return shutdown(0)
    })
  }

  const NEEDS_PEER = new Set(['echo', 'send-file', 'resume-file'])

  function enqueue(line) {
    const trimmed = line.replace(/\r$/, '').trim()
    if (!trimmed) return
    const name = trimmed.split(/\s+/)[0]
    const pendingNeedsPeer = pending.some((l) => NEEDS_PEER.has(l.split(/\s+/)[0]))
    if (!NEEDS_PEER.has(name) && !pendingNeedsPeer) {
      chain = chain.then(() => handleLine(trimmed)).catch((err) => {
        process.stdout.write('ERR ' + String(err.message || err) + '\n')
      })
      return
    }
    pending.push(trimmed)
    if (worklet && hasReadyPeer(worklet)) drainPending()
    else if (NEEDS_PEER.has(name)) startReadyTimer()
  }

  async function handleLine(line) {
    const trimmed = line.replace(/\r$/, '').trim()
    if (!trimmed) return
    const parts = trimmed.split(/\s+/)
    const c = parts[0]
    try {
      if (c === 'echo') {
        if (!hasReadyPeer(worklet)) {
          process.stdout.write('ERR NOT_CONNECTED echo\n')
          await shutdown(1)
          return
        }
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
        rememberPeers()
        process.stdout.write('OK ECHO ' + got.body.text + '\n')
      } else if (c === 'send-file') {
        if (!hasReadyPeer(worklet)) {
          process.stdout.write('ERR NOT_CONNECTED send-file\n')
          await shutdown(1)
          return
        }
        const filePath = parts.slice(1).join(' ')
        if (!filePath) throw new Error('send-file needs a path')
        if (filePath.includes('://')) throw new Error('send-file refuses :// path')
        const peerId = firstPeer(worklet)
        await worklet.sendFile(peerId, { path: filePath })
        rememberPeers()
        process.stdout.write('OK FILE sent ' + filePath + '\n')
      } else if (c === 'resume-file') {
        if (!hasReadyPeer(worklet)) {
          process.stdout.write('ERR NOT_CONNECTED resume-file\n')
          await shutdown(1)
          return
        }
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

  worklet = new Worklet({
    backend: args.backend,
    harnessAuth: 'local',
    emit: (name, payload) => {
      worklet.events.push({ name, payload })
      if (name === 'connected') {
        const pathName = (payload && payload.path) || 'unknown'
        process.stdout.write(
          'OK PEER connected ' + payload.peerId + ' path=' + pathName + '\n',
        )
        rememberPeers()
        drainPending()
      } else if (name === 'authenticated') {
        rememberPeers()
        drainPending()
      } else if (name === 'disconnected') {
        process.stdout.write(
          'OK PEER disconnected ' +
            payload.peerId +
            ' reason=' +
            (payload.reason || 'closed') +
            '\n',
        )
      } else if (
        name === 'frame' &&
        payload &&
        payload.body &&
        payload.body.type === 'harness-file-received'
      ) {
        const body = payload.body
        let dest = body.path
        try {
          dest = placeIncoming(body.path, args.incomingDir)
        } catch {
          dest = body.path
        }
        process.stdout.write(
          'OK FILE received ' +
            body.id +
            ' ' +
            body.size +
            ' sha256=' +
            body.sha256 +
            ' path=' +
            dest +
            '\n',
        )
        rememberPeers()
      }
    },
  })

  let buf = ''
  process.stdin.on('data', (chunk) => {
    buf += chunk.toString('utf8')
    for (;;) {
      const i = buf.indexOf('\n')
      if (i < 0) break
      const line = buf.slice(0, i)
      buf = buf.slice(i + 1)
      enqueue(line)
    }
  })
  process.stdin.on('end', () => {
    if (buf.trim()) enqueue(buf)
    buf = ''
    stdinEnded = true
    if (!pending.length && !exiting) {
      chain = chain.then(() => shutdown(0))
    }
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
      if (args.backend === 'hyperswarm') {
        process.stdout.write('OK LISTENING hyperswarm TOPIC ' + topicHex + '\n')
      } else {
        const host = worklet._loop.host || args.listenHost || '127.0.0.1'
        const port = worklet._loop.port || 0
        process.stdout.write('OK LISTENING ' + host + ':' + port + ' TOPIC ' + topicHex + '\n')
      }
    } else if (args.backend === 'hyperswarm') {
      // Target on argv is optional and ignored. publish() already joined
      // HASH("orbits-contact-discovery-v1" || secret).
      const target = args.positional[1]
      if (target && target.includes('://')) throw new Error('dial refuses :// target')
      await waitEvent(worklet, 'connected', null, args.timeoutMs)
      const peerId = Array.from(worklet._peers.keys())[0] || 'pending'
      process.stdout.write('OK CONNECTED ' + peerId + ' TOPIC ' + topicHex + '\n')
    } else {
      const target = args.positional[1]
      if (!target) throw new Error('loopback dial needs host:port')
      if (target.includes('://')) throw new Error('dial refuses :// target')
      const hostPort = target.match(/^([^:]+):(\d+)$/)
      if (!hostPort) throw new Error('loopback dial target must be host:port')
      await worklet.connect({
        host: hostPort[1],
        port: Number(hostPort[2]),
        timeoutMs: args.timeoutMs,
      })
      const peerId = Array.from(worklet._peers.keys())[0] || 'pending'
      process.stdout.write('OK CONNECTED ' + peerId + ' TOPIC ' + topicHex + '\n')
    }
  } catch (err) {
    process.stderr.write(String(err.message || err) + '\n')
    failQueued('NOT_CONNECTED')
    await shutdown(1)
    return
  }

  drainPending()
}

if (require.main === module) {
  main().catch((err) => {
    process.stderr.write(String(err && err.message ? err.message : err) + '\n')
    process.exit(1)
  })
}

module.exports = {
  parseArgs,
  readSecretFile,
  parseBootstrap,
  usage,
  wantsHelp,
  contactDiscoveryTopic,
}

'use strict'

/**
 * Headless worklet. Runs under Node for CI and under Bare when the Bare
 * stdlib is installed next to this tree. Does not load remote executable JS.
 *
 * Bare 1.31 has no `process` global. Load `bare-process` only then so Node
 * CI does not need the native addon. `node:fs` and friends resolve through
 * package.json import maps on Bare and stay Node builtins on Node.
 */
const process =
  typeof globalThis.process !== 'undefined'
    ? globalThis.process
    : require('bare-process')

const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const { createHash } = require('node:crypto')
const { encodeMux, MuxDecoder } = require('./mux')
const { contactDiscoveryTopic } = require('./discovery')
const { LoopbackBackend } = require('./loopback')
const { REQUEST, RESPONSE, EVENT, encode, Decoder } = require('./ipc')
const { CorestoreJournal } = require('./corestore_journal')

const FILE_CHUNK = 64 * 1024

function localJournalDir(p) {
  if (typeof p !== 'string') return ''
  const t = p.trim()
  if (!t || t.includes('://')) return ''
  return t
}

function safeFileName(raw) {
  let name = String(raw || 'file').replace(/\\/g, '/').split('/').pop()
  name = name.replace(/[\x00-\x1f\\/:*?"<>|]/g, '_').trim()
  if (!name || name === '.' || name === '..') return 'file'
  return name.slice(0, 200)
}

function nextContiguousOffset(ranges) {
  if (!ranges.length) return 0
  const sorted = ranges.slice().sort((a, b) => a[0] - b[0])
  let pos = 0
  for (const r of sorted) {
    if (r[0] > pos) return pos
    if (r[1] > pos) pos = r[1]
  }
  return pos
}

function addRange(ranges, start, length) {
  if (length <= 0) return ranges
  ranges.push([start, start + length])
  ranges.sort((a, b) => a[0] - b[0])
  const merged = []
  for (const r of ranges) {
    if (!merged.length || r[0] > merged[merged.length - 1][1]) merged.push(r)
    else if (r[1] > merged[merged.length - 1][1]) merged[merged.length - 1][1] = r[1]
  }
  ranges.length = 0
  for (const r of merged) ranges.push(r)
  return ranges
}

// Stream a file for hashing. Never load the whole blob into one buffer.
function hashPath(filePath) {
  const hash = createHash('sha256')
  const fd = fs.openSync(filePath, 'r')
  try {
    const buf = Buffer.alloc(FILE_CHUNK)
    let size = 0
    for (;;) {
      const n = fs.readSync(fd, buf, 0, buf.length, size)
      if (!n) break
      hash.update(buf.subarray(0, n))
      size += n
    }
    return { digest: hash.digest('hex'), size }
  } finally {
    fs.closeSync(fd)
  }
}

class Worklet {
  constructor(opts = {}) {
    this.backend = opts.backend || 'loopback'
    this._loop = new LoopbackBackend()
    this._swarm = null
    this._peers = new Map()
    this._started = false
    this._suspended = false
    this._config = null
    this._topic = null
    this.events = []
    this._journal = new CorestoreJournal('local-device')
    this._files = new Map()
    this._resumeOffsets = new Map()
    this._resumeWaiters = new Map()
    this.fileSendBudget = null
    this._emit = opts.emit || ((name, payload) => this.events.push({ name, payload }))
  }

  async start(config) {
    this._config = config
    this._started = true
    try {
      const journalDir = localJournalDir(config && config.journalDir)
      await this._journal.useCorestoreIfPresent(journalDir || undefined)
    } catch {
      this._journal.backend = 'memory'
    }
    if (this.backend === 'loopback') {
      await this._loop.listen()
      this._loop.on('connection', (sock, info) => this._onConn(sock, info))
    } else {
      const { createHyperswarmBackend } = require('./swarm')
      const swarmOpts = {
        bootstrap: config.bootstrap,
        keyPair: config.keyPair,
        firewall: config.firewall,
        relayForced: Boolean(config.relayForced),
        relayThrough: config.relayThrough,
      }
      if (config.seed) {
        swarmOpts.seed = Buffer.isBuffer(config.seed)
          ? config.seed
          : Buffer.from(config.seed)
      }
      this._swarm = await createHyperswarmBackend(swarmOpts)
      this._swarm.onConnection((sock, info) => this._onConn(sock, info))
    }
    this._emit('started', {
      backend: this.backend,
      port: this._loop.port,
      noisePublicKey: this.noisePublicKeyHex(),
      journalBackend: this._journal.backend,
    })
  }

  noisePublicKeyHex() {
    const kp = this._swarm && this._swarm.swarm && this._swarm.swarm.keyPair
    return kp && kp.publicKey ? Buffer.from(kp.publicKey).toString('hex') : null
  }

  async publish(binding) {
    const secret = Buffer.from(this._config.discoverySecret)
    this._topic = contactDiscoveryTopic(secret)
    if (this._swarm) await this._swarm.join(this._topic)
    this._emit('published', { topicHex: this._topic.toString('hex'), binding })
  }

  async unpublish() {
    if (this._swarm && this._topic) await this._swarm.leave(this._topic)
  }

  async connect(peer) {
    if (this._suspended) throw new Error('suspended')
    if (this.backend === 'loopback') {
      if (peer.port == null) throw new Error('loopback connect needs port')
      await this._loop.connect(peer.port)
    } else if (this._swarm && peer.noisePublicKey) {
      this._swarm.swarm.joinPeer(Buffer.from(peer.noisePublicKey, 'hex'))
    }
  }

  async send(peerId, channel, frame) {
    if (this._suspended) throw new Error('suspended')
    const peer = this._peers.get(peerId)
    if (!peer) throw new Error('not connected: ' + peerId)
    const payload = Buffer.isBuffer(frame) ? frame : Buffer.from(JSON.stringify(frame))
    peer.socket.write(encodeMux(channel, payload))
  }

  async sendFile(peerId, file) {
    // Stream from a path. Never take a Dart Uint8List over IPC.
    if (!file || typeof file.path !== 'string' || file.path.length === 0) {
      throw new Error('sendFile needs a path')
    }
    if (String(file.path).includes('://')) {
      throw new Error('sendFile refuses remote path')
    }
    if (file.bytes != null) {
      throw new Error('sendFile takes a path, not bytes')
    }
    if (file.fileKey != null || file.fileKeyB64 != null) {
      throw new Error('sendFile refuses fileKey')
    }
    if (file.protocol === 'attach-chunk') {
      await this._sendAttachChunk(peerId, file)
      return
    }
    const { digest, size } = hashPath(file.path)
    const id = digest.slice(0, 16)
    const resumeOffset = Number(file.resumeOffset) || 0
    if (resumeOffset < 0 || resumeOffset > size) {
      throw new Error('sendFile resumeOffset out of range')
    }
    await this.send(peerId, 'attachment', {
      type: 'harness-file-start',
      id,
      name: file.fileName || path.basename(file.path),
      size,
      sha256: digest,
    })
    const agreed = await this._awaitResume(id, resumeOffset)
    let offset = resumeOffset > agreed ? resumeOffset : agreed
    const startOffset = offset
    const fd = fs.openSync(file.path, 'r')
    try {
      const buf = Buffer.alloc(FILE_CHUNK)
      while (offset < size) {
        if (this.fileSendBudget != null && offset - startOffset >= this.fileSendBudget) {
          throw new Error('file-send interrupted')
        }
        const n = fs.readSync(fd, buf, 0, buf.length, offset)
        if (!n) break
        await this.send(peerId, 'attachment', {
          type: 'harness-file-chunk',
          id,
          offset,
          b64: buf.subarray(0, n).toString('base64'),
        })
        offset += n
      }
    } finally {
      fs.closeSync(fd)
      this._resumeWaiters.delete(id)
    }
    await this.send(peerId, 'attachment', { type: 'harness-file-end', id })
  }

  async _sendAttachChunk(peerId, file) {
    const fileId = typeof file.fileId === 'string' ? file.fileId : ''
    if (!fileId) throw new Error('attach-chunk needs fileId')
    let offset = Number(file.resumeOffset) || 0
    const size = fs.statSync(file.path).size
    if (offset < 0 || offset > size) {
      throw new Error('sendFile resumeOffset out of range')
    }
    offset = Math.floor(offset / FILE_CHUNK) * FILE_CHUNK
    const fd = fs.openSync(file.path, 'r')
    try {
      const buf = Buffer.alloc(FILE_CHUNK)
      const startOffset = offset
      while (offset < size) {
        if (this.fileSendBudget != null && offset - startOffset >= this.fileSendBudget) {
          throw new Error('file-send interrupted')
        }
        const n = fs.readSync(fd, buf, 0, buf.length, offset)
        if (!n) break
        const ct = buf.subarray(0, n)
        const hash = createHash('sha256').update(ct).digest('hex')
        await this.send(peerId, 'attachment', {
          type: 'attach-chunk',
          fileId,
          index: Math.floor(offset / FILE_CHUNK),
          offset,
          hash,
          b64: ct.toString('base64'),
        })
        offset += n
      }
    } finally {
      fs.closeSync(fd)
    }
  }

  async suspend() {
    this._suspended = true
    if (this._swarm) await this._swarm.suspend()
    else await this._loop.suspend()
    this._emit('suspended', {})
  }

  async resume() {
    this._suspended = false
    if (this._swarm) await this._swarm.resume()
    else await this._loop.resume()
    this._emit('resumed', {})
  }

  async refreshNetwork() {
    if (this._swarm) await this._swarm.refresh()
    this._emit('networkChanged', { detail: this.backend })
  }

  async stop() {
    for (const peer of this._peers.values()) peer.socket.destroy()
    this._peers.clear()
    for (const incoming of this._files.values()) {
      try {
        fs.closeSync(incoming.fd)
      } catch {
        // already closed
      }
    }
    this._files.clear()
    if (this._swarm) await this._swarm.destroy()
    await this._loop.destroy()
    try {
      await this._journal.close()
    } catch {
      // journal already closed
    }
    this._started = false
  }

  _onConn(socket, info) {
    const peerId = info.id || info.publicKey.toString('hex')
    const decoder = new MuxDecoder()
    this._peers.set(peerId, { socket, info, decoder })
    this._emit('connected', { peerId, path: info.path || 'unknown' })
    this._emit('pathChanged', { peerId, path: info.path || 'direct' })
    socket.on('data', (chunk) => {
      for (const frame of decoder.add(chunk)) {
        this._onFrame(peerId, frame.channel, frame.payload)
      }
    })
    socket.on('error', () => {})
    socket.on('close', () => {
      this._peers.delete(peerId)
      this._emit('disconnected', { peerId })
    })
  }

  _onFrame(peerId, channel, payload) {
    const frameB64 = payload.toString('base64')
    let body
    try {
      body = JSON.parse(payload.toString('utf8'))
    } catch {
      this._emit('frame', { peerId, channel, frameB64 })
      return
    }
    if (channel === 'message' && body.type === 'harness-echo') {
      this.send(peerId, 'message', {
        type: 'harness-echo-reply',
        id: body.id,
        text: body.text,
      }).catch(() => {})
    }
    if (channel === 'attachment') {
      this._handleIncomingFile(peerId, body)
    }
    this._emit('frame', { peerId, channel, body, frameB64 })
  }

  _awaitResume(id, fallback) {
    if (this._resumeOffsets.has(id)) {
      const n = this._resumeOffsets.get(id)
      this._resumeOffsets.delete(id)
      return Promise.resolve(n > fallback ? n : fallback)
    }
    return new Promise((resolve) => {
      const t = setTimeout(() => {
        this._resumeWaiters.delete(id)
        resolve(fallback)
      }, 2000)
      this._resumeWaiters.set(id, (n) => {
        clearTimeout(t)
        resolve(n > fallback ? n : fallback)
      })
    })
  }

  _onResume(id, offset) {
    const waiter = this._resumeWaiters.get(id)
    if (waiter) {
      this._resumeWaiters.delete(id)
      waiter(offset)
      return
    }
    this._resumeOffsets.set(id, offset)
  }

  _handleIncomingFile(peerId, body) {
    const type = body && body.type
    const id = body && body.id
    if (type === 'harness-file-resume') {
      if (id) this._onResume(id, Number(body.offset) || 0)
      return
    }
    if (type === 'harness-file-start') {
      const digest = body.sha256 || ''
      let incoming = this._files.get(id)
      if (!incoming || incoming.sha256 !== digest) {
        if (incoming) {
          try {
            fs.closeSync(incoming.fd)
          } catch {
            // already closed
          }
        }
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-harness-'))
        const filePath = path.join(dir, safeFileName(body.name || id))
        const fd = fs.openSync(filePath, 'w+')
        incoming = {
          id,
          name: safeFileName(body.name || id),
          size: Number(body.size) || 0,
          sha256: digest,
          path: filePath,
          fd,
          ranges: [],
        }
        this._files.set(id, incoming)
      }
      this.send(peerId, 'attachment', {
        type: 'harness-file-resume',
        id,
        offset: nextContiguousOffset(incoming.ranges),
      }).catch(() => {})
      return
    }
    if (type === 'harness-file-chunk') {
      const incoming = this._files.get(id)
      if (!incoming) return
      const buf = Buffer.from(body.b64 || '', 'base64')
      const offset = Number(body.offset) || 0
      fs.writeSync(incoming.fd, buf, 0, buf.length, offset)
      addRange(incoming.ranges, offset, buf.length)
      return
    }
    if (type === 'harness-file-end') {
      const incoming = this._files.get(id)
      if (!incoming) return
      try {
        fs.fsyncSync(incoming.fd)
        fs.closeSync(incoming.fd)
      } catch {
        // already closed
      }
      if (nextContiguousOffset(incoming.ranges) < incoming.size) {
        incoming.fd = fs.openSync(incoming.path, 'r+')
        return
      }
      const hashed = hashPath(incoming.path)
      this._files.delete(id)
      if (incoming.sha256 && hashed.digest !== incoming.sha256) {
        this._emit('error', { code: 'file-hash', message: 'attachment hash mismatch' })
        return
      }
      this._emit('frame', {
        peerId,
        channel: 'attachment',
        body: {
          type: 'harness-file-received',
          id,
          path: incoming.path,
          size: hashed.size,
          sha256: hashed.digest,
        },
      })
    }
  }
}

async function handleIpcRequest(worklet, body) {
  const method = body.method
  const params = body.params || {}
  switch (method) {
    case 'start':
      await worklet.start(params)
      return {
        port: worklet._loop.port,
        backend: worklet.backend,
        noisePublicKey: worklet.noisePublicKeyHex(),
        journalBackend: worklet._journal.backend,
      }
    case 'stop':
      await worklet.stop()
      return {}
    case 'publish':
      await worklet.publish(params.binding)
      return {}
    case 'unpublish':
      await worklet.unpublish()
      return {}
    case 'connect':
      await worklet.connect(params)
      return {}
    case 'send':
      await worklet.send(
        params.peerId,
        params.channel,
        params.frameB64 ? Buffer.from(params.frameB64, 'base64') : params.frame,
      )
      return {}
    case 'sendFile':
      await worklet.sendFile(params.peerId, params.file)
      return {}
    case 'suspend':
      await worklet.suspend()
      return {}
    case 'resume':
      await worklet.resume()
      return {}
    case 'refreshNetwork':
      await worklet.refreshNetwork()
      return {}
    case 'journal.append':
      return await worklet._journal.append(params)
    case 'journal.list':
      return { blocks: worklet._journal.list() }
    default:
      throw new Error('unknown method ' + method)
  }
}

if (require.main === module) {
  const worklet = new Worklet({
    backend: process.env.ORBITS_HARNESS_BACKEND || 'loopback',
    emit: (name, payload) => {
      process.stdout.write(encode(EVENT, { name, payload }))
    },
  })
  const decoder = new Decoder()
  process.stdin.on('data', async (chunk) => {
    for (const msg of decoder.add(chunk)) {
      if (msg.type !== REQUEST) continue
      try {
        const result = await handleIpcRequest(worklet, msg.body)
        process.stdout.write(encode(RESPONSE, { id: msg.body.id, ok: true, result }))
      } catch (err) {
        process.stdout.write(
          encode(RESPONSE, { id: msg.body.id, ok: false, error: String(err.message || err) }),
        )
      }
    }
  })
}

module.exports = { Worklet, handleIpcRequest, hashPath, FILE_CHUNK }

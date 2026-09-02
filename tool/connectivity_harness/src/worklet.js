'use strict'

/**
 * Headless worklet. Runs under Node for CI and under Bare when embedded.
 * Does not load remote executable JS.
 */

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { createHash } = require('node:crypto')
const { encodeMux, MuxDecoder } = require('./mux')
const { contactDiscoveryTopic } = require('./discovery')
const { LoopbackBackend } = require('./loopback')
const { REQUEST, RESPONSE, EVENT, encode, Decoder } = require('./ipc')
const { CorestoreJournal } = require('./corestore_journal')

const FILE_CHUNK = 64 * 1024

function osTmp() {
  return os.tmpdir()
}

function persistTransferState(statePath, state) {
  fs.mkdirSync(path.dirname(statePath), { recursive: true })
  const tmp = statePath + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(state))
  fs.renameSync(tmp, statePath)
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
    this._emit = opts.emit || ((name, payload) => this.events.push({ name, payload }))
  }

  async start(config) {
    this._config = config
    this._started = true
    if (this.backend === 'loopback') {
      await this._loop.listen()
      this._loop.on('connection', (sock, info) => this._onConn(sock, info))
    } else {
      const { createHyperswarmBackend } = require('./swarm')
      this._swarm = await createHyperswarmBackend(config)
      this._swarm.onConnection((sock, info) => this._onConn(sock, info))
    }
    this._emit('started', { backend: this.backend, port: this._loop.port })
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
    if (!file || typeof file.path !== 'string' || file.path.length === 0) {
      throw new Error('path required')
    }
    if (file.path.includes('\0') || file.path.includes('..')) {
      throw new Error('path traversal')
    }
    const resolved = path.resolve(file.path)
    let lst
    try {
      lst = fs.lstatSync(resolved)
    } catch {
      throw new Error('file missing')
    }
    if (lst.isSymbolicLink()) throw new Error('symlink rejected')
    if (!lst.isFile()) throw new Error('not a regular file')
    if (file.sizeBytes != null && Number(file.sizeBytes) !== lst.size) {
      throw new Error('size mismatch')
    }
    if (lst.size > 50 * 1024 * 1024) throw new Error('oversized')
    const resumeFrom = Number(file.resumeOffset || 0)
    if (!Number.isInteger(resumeFrom) || resumeFrom < 0 || resumeFrom > lst.size) {
      throw new Error('malformed offset')
    }
    const id =
      file.transferId ||
      createHash('sha256').update(resolved + ':' + lst.size).digest('hex').slice(0, 16)
    const statePath = file.resumeStatePath || path.join(osTmp(), 'orbits-transfers', id + '.json')
    const hash = createHash('sha256')
    const fd = fs.openSync(resolved, 'r')
    this._sendFileFd = fd
    this._sendFileBytesRead = 0
    this._sendFilePeakBuffer = FILE_CHUNK
    this._cancelledTransfers = this._cancelledTransfers || new Set()
    try {
      const prefixBuf = Buffer.alloc(FILE_CHUNK)
      let hashed = 0
      while (hashed < resumeFrom) {
        const n = fs.readSync(fd, prefixBuf, 0, Math.min(FILE_CHUNK, resumeFrom - hashed), hashed)
        if (n <= 0) break
        hash.update(prefixBuf.subarray(0, n))
        hashed += n
      }
      if (resumeFrom === 0) {
        await this.send(peerId, 'attachment', {
          type: 'harness-file-start',
          id,
          name: file.fileName || path.basename(resolved),
          size: lst.size,
        })
      }
      const buf = Buffer.alloc(FILE_CHUNK)
      let offset = resumeFrom
      while (offset < lst.size) {
        if (this._cancelledTransfers.has(id)) throw new Error('cancelled')
        const live = fs.lstatSync(resolved)
        if (live.size !== lst.size || Number(live.mtimeMs) !== Number(lst.mtimeMs)) {
          throw new Error('file mutated')
        }
        const n = fs.readSync(fd, buf, 0, FILE_CHUNK, offset)
        if (n <= 0) break
        const chunk = buf.subarray(0, n)
        hash.update(chunk)
        this._sendFileBytesRead += n
        const peer = this._peers.get(peerId)
        if (peer && peer.socket && peer.socket.writableNeedDrain) {
          await new Promise((resolve) => peer.socket.once('drain', resolve))
        }
        const chunkHash = createHash('sha256').update(chunk).digest('hex')
        await this.send(peerId, 'attachment', {
          type: 'harness-file-chunk',
          id,
          offset,
          sha256: chunkHash,
          b64: chunk.toString('base64'),
        })
        offset += n
        await new Promise((resolve) => setImmediate(resolve))
        persistTransferState(statePath, {
          id,
          path: resolved,
          size: lst.size,
          mtimeMs: lst.mtimeMs,
          offset,
        })
      }
      const digest = hash.digest('hex')
      await this.send(peerId, 'attachment', {
        type: 'harness-file-end',
        id,
        sha256: digest,
      })
      try {
        fs.unlinkSync(statePath)
      } catch {
        // already gone
      }
    } finally {
      if (this._sendFileFd != null) {
        try {
          fs.closeSync(this._sendFileFd)
        } catch {
          // already closed by cancel
        }
        this._sendFileFd = null
      }
    }
  }

  cancelFile(transferId) {
    this._cancelledTransfers = this._cancelledTransfers || new Set()
    this._cancelledTransfers.add(transferId)
    if (this._sendFileFd != null) {
      try {
        fs.closeSync(this._sendFileFd)
      } catch {
        // already closed
      }
      this._sendFileFd = null
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
    if (this._swarm) await this._swarm.destroy()
    await this._loop.destroy()
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
    this._emit('frame', { peerId, channel, body, frameB64 })
  }
}

async function handleIpcRequest(worklet, body) {
  const method = body.method
  const params = body.params || {}
  switch (method) {
    case 'start':
      await worklet.start(params)
      return { port: worklet._loop.port }
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
    case 'cancelFile':
      worklet.cancelFile(params.transferId)
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
      return worklet._journal.append(params)
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

module.exports = { Worklet, handleIpcRequest }

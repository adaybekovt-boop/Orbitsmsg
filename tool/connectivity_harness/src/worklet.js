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
const { createHash } = require('node:crypto')
const { encodeMux, MuxDecoder } = require('./mux')
const { contactDiscoveryTopic } = require('./discovery')
const { LoopbackBackend } = require('./loopback')
const { REQUEST, RESPONSE, EVENT, encode, Decoder } = require('./ipc')
const { CorestoreJournal } = require('./corestore_journal')

const FILE_CHUNK = 64 * 1024

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
    try {
      await this._journal.useCorestoreIfPresent()
    } catch {
      this._journal.backend = 'memory'
    }
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
    const bytes = fs.readFileSync(file.path)
    const digest = createHash('sha256').update(bytes).digest('hex')
    const id = digest.slice(0, 16)
    await this.send(peerId, 'attachment', {
      type: 'harness-file-start',
      id,
      name: file.fileName || path.basename(file.path),
      size: bytes.length,
      sha256: digest,
    })
    for (let offset = 0; offset < bytes.length; offset += FILE_CHUNK) {
      const chunk = bytes.subarray(offset, offset + FILE_CHUNK)
      await this.send(peerId, 'attachment', {
        type: 'harness-file-chunk',
        id,
        offset,
        b64: chunk.toString('base64'),
      })
    }
    await this.send(peerId, 'attachment', { type: 'harness-file-end', id })
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

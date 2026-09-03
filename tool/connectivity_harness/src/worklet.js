'use strict'

/**
 * Headless worklet. Runs under Node for CI and under Bare when embedded.
 * Does not load remote executable JS.
 */

const { fs, os, path, crypto, process, ipcChannel, isBare } = require('./bare_compat')
const { createHash } = crypto
const { encodeMux, MuxDecoder } = require('./mux')
const { contactDiscoveryTopic } = require('./discovery')
const { LoopbackBackend } = require('./loopback')
const { REQUEST, RESPONSE, EVENT, encode, Decoder } = require('./ipc')
const { openJournal } = require('./corestore_journal')

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

function parseWorkletArgv(argv) {
  const out = { backend: null, storage: null }
  for (const raw of argv || []) {
    const a = String(raw)
    if (a.startsWith('--backend=')) out.backend = a.slice('--backend='.length)
    if (a.startsWith('--storage=')) out.storage = a.slice('--storage='.length)
  }
  return out
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
    this._journal = null
    this._dht = null
    this._dhtServer = null
    this._bootstrapper = null
    this._dhtSockets = []
    this._connWaiters = []
    this._pendingPeerId = null
    this._argvStorage = opts.storageDir || null
    this._emit = opts.emit || ((name, payload) => this.events.push({ name, payload }))
  }

  async start(config) {
    this._config = config || {}
    if (config && typeof config.backend === 'string' && config.backend.length > 0) {
      this.backend = config.backend
    }
    this._started = true
    const storageDir =
      config.storageDir ||
      this._argvStorage ||
      (isBare || config.requireRealCorestore
        ? path.join(os.tmpdir(), 'orbits-corestore', config.peerId || 'local')
        : undefined)
    this._journal = await openJournal({
      writerDeviceId: config.writerDeviceId || config.peerId || 'local-device',
      storageDir,
      requireReal: config.requireRealCorestore === true || isBare,
    })
    if (this.backend === 'loopback') {
      await this._loop.listen()
      this._loop.on('connection', (sock, info) => this._onConn(sock, info))
    } else if (this.backend === 'hyperswarm') {
      const { createHyperswarmBackend } = require('./swarm')
      this._swarm = await createHyperswarmBackend(config)
      this._swarm.onConnection((sock, info) => this._onConn(sock, info))
    } else {
      throw new Error('unknown backend ' + this.backend)
    }
    this._emit('started', {
      backend: this.backend,
      port: this._loop.port,
      noisePublicKey: this.noisePublicKey(),
    })
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
    if (!this._started) throw new Error('not started')
    if (peer && peer.peerId) this._pendingPeerId = String(peer.peerId)
    if (this.backend === 'loopback') {
      if (peer.port == null) throw new Error('loopback connect needs port')
      await this._loop.connect(peer.port)
      return { peerId: this._firstPeerId() }
    }
    if (!this._swarm) throw new Error('swarm not started')
    if (peer && peer.noisePublicKey) {
      const key = Buffer.from(String(peer.noisePublicKey), 'hex')
      if (key.length !== 32) throw new Error('noisePublicKey must be 32 bytes hex')
      this._swarm.swarm.joinPeer(key)
    } else if (!this._topic) {
      throw new Error('publish or noisePublicKey required before connect')
    }
    if (this._peers.size > 0) return { peerId: this._firstPeerId() }
    const timeoutMs = Number(peer && peer.timeoutMs) || 45000
    const peerId = await new Promise((resolve, reject) => {
      const waiter = {
        resolve: (id) => {
          clearTimeout(timer)
          resolve(id)
        },
      }
      const timer = setTimeout(() => {
        this._connWaiters = this._connWaiters.filter((w) => w !== waiter)
        reject(new Error('connect timeout'))
      }, timeoutMs)
      this._connWaiters.push(waiter)
      if (this._peers.size > 0) {
        this._connWaiters = this._connWaiters.filter((w) => w !== waiter)
        waiter.resolve(this._firstPeerId())
      }
    })
    return { peerId }
  }

  async disconnect(peerId) {
    const id = String(peerId || '')
    const peer = this._peers.get(id)
    if (!peer) return
    try {
      peer.socket.destroy()
    } catch {
      // already closed
    }
    this._peers.delete(id)
    this._emit('disconnected', { peerId: id })
  }

  _firstPeerId() {
    return this._peers.keys().next().value || null
  }

  _announceIdentity(peerId) {
    const localId = this._config && this._config.peerId
    if (!localId) return
    const peer = this._peers.get(peerId)
    if (!peer || !peer.socket) return
    try {
      peer.socket.write(
        encodeMux(
          'control',
          Buffer.from(
            JSON.stringify({ type: 'orbits-identity', peerId: localId }),
            'utf8',
          ),
        ),
      )
    } catch {
      // peer already closed
    }
  }

  _remapPeer(fromId, toId) {
    if (!fromId || !toId || fromId === toId) return toId
    if (this._peers.has(toId)) return toId
    const rec = this._peers.get(fromId)
    if (!rec) return toId
    this._peers.delete(fromId)
    this._peers.set(toId, rec)
    this._emit('disconnected', { peerId: fromId })
    this._emit('connected', { peerId: toId, path: (rec.info && rec.info.path) || 'unknown' })
    return toId
  }

  noisePublicKey() {
    const key = this._swarm && this._swarm.swarm && this._swarm.swarm.keyPair
    return key && key.publicKey ? key.publicKey.toString('hex') : null
  }

  async dhtBootstrap(params = {}) {
    const DHT = require('hyperdht')
    if (this._bootstrapper) {
      const addr = this._bootstrapper.address()
      return { bootstrap: [{ host: '127.0.0.1', port: addr.port }] }
    }
    const bindPort = Number(params.port)
    if (!Number.isInteger(bindPort) || bindPort <= 0) {
      throw new Error('dht.bootstrap needs a positive port')
    }
    if (typeof DHT.bootstrapper === 'function') {
      this._bootstrapper = DHT.bootstrapper(bindPort, '127.0.0.1')
    } else {
      this._bootstrapper = new DHT({
        ephemeral: false,
        bootstrap: [],
        host: '127.0.0.1',
        firewalled: false,
      })
    }
    await this._bootstrapper.ready()
    const addr = this._bootstrapper.address()
    return { bootstrap: [{ host: '127.0.0.1', port: addr.port }] }
  }

  async dhtListen(params = {}) {
    const DHT = require('hyperdht')
    if (!this._dht) {
      this._dht = new DHT({
        bootstrap: params.bootstrap,
        firewalled: params.firewalled === true,
      })
      await this._dht.ready()
    }
    this._dhtServer = this._dht.createServer({ firewall: () => false })
    this._dhtServer.on('connection', (sock) => {
      sock.on('error', () => {})
      this._dhtSockets.push(sock)
      this._emit('dht.connection', {
        publicKey: sock.remotePublicKey && sock.remotePublicKey.toString('hex'),
      })
      sock.on('data', (chunk) => {
        this._emit('dht.data', { text: chunk.toString(), bytes: chunk.length })
      })
    })
    await this._dhtServer.listen()
    return { publicKey: this._dhtServer.publicKey.toString('hex') }
  }

  async dhtConnect(params = {}) {
    const DHT = require('hyperdht')
    if (!this._dht) {
      this._dht = new DHT({
        bootstrap: params.bootstrap,
        firewalled: params.firewalled === true,
      })
      await this._dht.ready()
    }
    if (!params.publicKey) throw new Error('dht.connect needs publicKey')
    const sock = this._dht.connect(Buffer.from(params.publicKey, 'hex'))
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('dht connect timeout')), 12000)
      sock.on('error', (err) => {
        clearTimeout(timer)
        reject(err)
      })
      sock.on('open', () => {
        clearTimeout(timer)
        resolve()
      })
    })
    sock.on('error', () => {})
    this._dhtSockets.push(sock)
    if (params.payload) sock.write(params.payload)
    return { ok: true }
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
    for (const sock of this._dhtSockets) {
      try {
        sock.destroy()
      } catch {
        // already closed
      }
    }
    this._dhtSockets = []
    if (this._dhtServer) {
      await this._dhtServer.close()
      this._dhtServer = null
    }
    if (this._dht) {
      await this._dht.destroy()
      this._dht = null
    }
    if (this._bootstrapper) {
      await this._bootstrapper.destroy()
      this._bootstrapper = null
    }
    if (this._swarm) await this._swarm.destroy()
    await this._loop.destroy()
    if (this._journal && typeof this._journal.close === 'function') {
      await this._journal.close()
    }
    this._started = false
  }

  _onConn(socket, info) {
    const noise =
      info && info.publicKey
        ? Buffer.isBuffer(info.publicKey)
          ? info.publicKey.toString('hex')
          : String(info.publicKey)
        : null
    const assigned = this._pendingPeerId
    this._pendingPeerId = null
    const peerId = assigned || info.id || noise
    const decoder = new MuxDecoder()
    this._peers.set(peerId, { socket, info, decoder, noise })
    this._emit('connected', { peerId, path: (info && info.path) || 'unknown' })
    this._emit('pathChanged', { peerId, path: (info && info.path) || 'direct' })
    const waiters = this._connWaiters.splice(0)
    for (const waiter of waiters) waiter.resolve(peerId)
    socket.on('data', (chunk) => {
      const currentId = this._idForSocket(socket) || peerId
      for (const frame of decoder.add(chunk)) {
        this._onFrame(currentId, frame.channel, frame.payload)
      }
    })
    socket.on('close', () => {
      const currentId = this._idForSocket(socket) || peerId
      this._peers.delete(currentId)
      this._emit('disconnected', { peerId: currentId })
    })
    this._announceIdentity(peerId)
  }

  _idForSocket(socket) {
    for (const [id, rec] of this._peers) {
      if (rec.socket === socket) return id
    }
    return null
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
    if (channel === 'control' && body && body.type === 'orbits-identity' && body.peerId) {
      const looksNoise = /^[0-9a-f]{64}$/i.test(String(peerId))
      if (looksNoise || this.backend === 'hyperswarm') {
        peerId = this._remapPeer(peerId, String(body.peerId))
      }
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
      return { port: worklet._loop.port, noisePublicKey: worklet.noisePublicKey() }
    case 'dht.bootstrap':
      return await worklet.dhtBootstrap(params)
    case 'dht.listen':
      return await worklet.dhtListen(params)
    case 'dht.connect':
      return await worklet.dhtConnect(params)
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
      return await worklet.connect(params)
    case 'disconnect':
      await worklet.disconnect(params.peerId)
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
      return await worklet._journal.append(params)
    case 'journal.list':
      return { blocks: await worklet._journal.list() }
    case 'runtime.info':
      return {
        runtime: isBare ? 'bare' : 'node',
        backend: worklet.backend,
        journal: worklet._journal && worklet._journal.backend,
        version: 'orbits-bare-ipc-v1',
        started: worklet._started === true,
        suspended: worklet._suspended === true,
        published: Boolean(worklet._topic),
        peerCount: worklet._peers.size,
        noisePublicKey: worklet.noisePublicKey(),
      }
    default:
      throw new Error('unknown method ' + method)
  }
}

function isMain() {
  if (typeof require !== 'undefined' && require.main === module) return true
  if (isBare && process.argv && process.argv[1] && String(process.argv[1]).endsWith('worklet.js')) {
    return true
  }
  return false
}

if (isMain()) {
  const argv = parseWorkletArgv((process.argv || []).slice(1))
  const envBackend = process.env && process.env.ORBITS_HARNESS_BACKEND
  const backend = argv.backend || envBackend || (isBare ? 'hyperswarm' : 'loopback')
  const channel = ipcChannel()
  const worklet = new Worklet({
    backend,
    storageDir: argv.storage || undefined,
    emit: (name, payload) => {
      channel.write(encode(EVENT, { name, payload }))
    },
  })
  const decoder = new Decoder()
  channel.onData(async (chunk) => {
    for (const msg of decoder.add(chunk)) {
      if (msg.type !== REQUEST) continue
      try {
        const result = await handleIpcRequest(worklet, msg.body)
        channel.write(encode(RESPONSE, { id: msg.body.id, ok: true, result }))
      } catch (err) {
        channel.write(
          encode(RESPONSE, { id: msg.body.id, ok: false, error: String(err.message || err) }),
        )
      }
    }
  })
}

module.exports = { Worklet, handleIpcRequest, parseWorkletArgv }

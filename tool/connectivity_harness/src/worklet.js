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
const incomingPaths = require('./incoming_paths')

const AUTH_IDENTITY_PENDING = 'identity-pending'
const AUTH_AUTHENTICATED = 'authenticated'
const AUTH_REJECTED = 'rejected'
const PRE_AUTH_TYPES = new Set(['orbits-identity'])
const HARNESS_FILE_TYPES = new Set([
  'harness-file-start',
  'harness-file-chunk',
  'harness-file-end',
])

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

function noiseSeedToBuffer(raw) {
  if (raw == null) return null
  if (Buffer.isBuffer(raw)) return raw.length === 32 ? raw : null
  if (Array.isArray(raw)) return raw.length === 32 ? Buffer.from(raw) : null
  if (typeof raw === 'string' && /^[0-9a-f]+$/i.test(raw) && raw.length === 64) {
    return Buffer.from(raw, 'hex')
  }
  return null
}

function secretToBuffer(raw) {
  if (raw == null) throw new Error('secret must not be empty')
  if (Buffer.isBuffer(raw)) {
    if (raw.length === 0) throw new Error('secret must not be empty')
    return raw
  }
  if (Array.isArray(raw)) {
    if (raw.length === 0) throw new Error('secret must not be empty')
    return Buffer.from(raw)
  }
  if (typeof raw === 'string') {
    if (raw.length === 0) throw new Error('secret must not be empty')
    if (/^[0-9a-f]+$/i.test(raw) && raw.length % 2 === 0) {
      return Buffer.from(raw, 'hex')
    }
    return Buffer.from(raw, 'utf8')
  }
  throw new Error('malformed discoverySecret')
}

class Worklet {
  constructor(opts = {}) {
    this.backend = opts.backend || 'loopback'
    this._loop = new LoopbackBackend()
    this._swarm = null
    this._connections = new Set()
    this._peers = new Map()
    this._started = false
    this._suspended = false
    this._config = null
    this._publishedTopic = null
    this._publishedDiscovery = null
    this._peerTopics = new Map()
    this._discoveryHandles = new Map()
    this.events = []
    this._journal = null
    this._dht = null
    this._dhtServer = null
    this._bootstrapper = null
    this._dhtSockets = []
    this._connWaiters = []
    this._argvStorage = opts.storageDir || null
    this._emit = opts.emit || ((name, payload) => this.events.push({ name, payload }))
    this.allowHarnessFiles =
      opts.allowHarnessFiles === true ||
      (process.env && process.env.ORBITS_HARNESS_FILES === '1')
    this._incomingRoot = null
    this._authWaiters = new Map()
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
    this._incomingBase =
      storageDir ||
      path.join(osTmp(), 'orbits-incoming-root', config.peerId || 'local')
    this._incomingRoot = incomingPaths.incomingRoot(this._incomingBase)
    this._noiseSeed = noiseSeedToBuffer(config.noiseSeed)
    if (this.backend === 'loopback') {
      await this._loop.listen()
      this._loop.on('connection', (sock, info) => this._onConn(sock, info))
    } else if (this.backend === 'hyperswarm') {
      const { createHyperswarmBackend } = require('./swarm')
      const swarmOpts = { ...config }
      if (this._noiseSeed) {
        try {
          const hc = require('hypercore-crypto')
          swarmOpts.keyPair = hc.keyPair(this._noiseSeed)
        } catch {
          swarmOpts.seed = this._noiseSeed
        }
      }
      this._swarm = await createHyperswarmBackend(swarmOpts)
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
    this._localBinding = binding || null
    const secret = secretToBuffer(this._config.discoverySecret)
    const topic = contactDiscoveryTopic(secret)
    this._publishedTopic = topic
    const topicHex = topic.toString('hex')
    if (this._swarm) {
      let handle = this._discoveryHandles.get(topicHex)
      if (!handle) {
        handle = await this._swarm.join(topic)
        this._discoveryHandles.set(topicHex, handle)
      }
      this._publishedDiscovery = handle
    }
    this._emit('published', { topicHex, binding })
  }

  async unpublish() {
    this._localBinding = null
    if (!this._publishedTopic) return
    const topicBuf = this._publishedTopic
    const pubHex = topicBuf.toString('hex')
    this._publishedTopic = null
    this._publishedDiscovery = null

    if (!this._peerTopicsHasTopic(pubHex) && this._swarm) {
      await this._swarm.leave(topicBuf)
      const handle = this._discoveryHandles.get(pubHex)
      if (handle && typeof handle.destroy === 'function') {
        try { await handle.destroy() } catch {}
      }
      this._discoveryHandles.delete(pubHex)
    }
  }

  _peerTopicsHasTopic(topicHex) {
    for (const hex of this._peerTopics.values()) {
      if (hex === topicHex) return true
    }
    return false
  }

  async connect(peer = {}) {
    if (this._suspended) throw new Error('suspended')
    if (!this._started) throw new Error('not started')

    const targetPeerId = peer && peer.peerId ? String(peer.peerId) : null

    if (this.backend === 'loopback') {
      if (peer.port == null) throw new Error('loopback connect needs port')
      await this._loop.connect(peer.port)
      const existing = targetPeerId ? this._peers.get(targetPeerId) : null
      if (existing && this._isTransportUp(existing)) {
        return { peerId: targetPeerId }
      }
    } else if (this.backend === 'hyperswarm') {
      if (!this._swarm) throw new Error('swarm not started')
      let topicJoined = false
      if (peer && peer.discoverySecret) {
        const topic = contactDiscoveryTopic(secretToBuffer(peer.discoverySecret))
        const topicHex = topic.toString('hex')
        if (targetPeerId) {
          this._peerTopics.set(targetPeerId, topicHex)
        }
        if (!this._discoveryHandles.has(topicHex)) {
          const handle = await this._swarm.join(topic)
          this._discoveryHandles.set(topicHex, handle)
        }
        topicJoined = true
      }
      if (peer && peer.noisePublicKey) {
        const key = Buffer.from(String(peer.noisePublicKey), 'hex')
        if (key.length !== 32) throw new Error('noisePublicKey must be 32 bytes hex')
        this._swarm.swarm.joinPeer(key)
      } else if (!topicJoined && !this._publishedTopic) {
        throw new Error('publish or noisePublicKey required before connect')
      }
    } else {
      throw new Error('unknown backend ' + this.backend)
    }

    if (targetPeerId && this._peers.has(targetPeerId)) {
      const existing = this._peers.get(targetPeerId)
      if (this._isTransportUp(existing)) {
        return { peerId: targetPeerId }
      }
    }

    if (!targetPeerId && this._peers.size > 0) {
      return { peerId: this._firstPeerId() }
    }

    const timeoutMs = Number(peer && peer.timeoutMs) || 45000
    return new Promise((resolve, reject) => {
      let timer = null
      const waiter = {
        targetPeerId,
        resolve: (id) => {
          if (timer) clearTimeout(timer)
          this._removeWaiter(waiter)
          resolve({ peerId: id })
        },
        reject: (err) => {
          if (timer) clearTimeout(timer)
          this._removeWaiter(waiter)
          reject(err)
        },
      }
      timer = setTimeout(() => {
        waiter.reject(new Error('connect timeout'))
      }, timeoutMs)
      this._connWaiters.push(waiter)
    })
  }

  _removeWaiter(waiter) {
    this._connWaiters = this._connWaiters.filter((w) => w !== waiter)
  }

  async disconnect(peerId) {
    const id = String(peerId || '')
    const connRecord = this._peers.get(id)
    if (connRecord) {
      this._handlePeerDisconnect(connRecord, null)
    }

    if (this._peerTopics.has(id)) {
      const topicHex = this._peerTopics.get(id)
      this._peerTopics.delete(id)
      const isPubTopic = this._publishedTopic && this._publishedTopic.toString('hex') === topicHex
      const otherPeerUses = this._peerTopicsHasTopic(topicHex)
      if (!isPubTopic && !otherPeerUses && this._swarm) {
        const topicBuf = Buffer.from(topicHex, 'hex')
        await this._swarm.leave(topicBuf)
        const handle = this._discoveryHandles.get(topicHex)
        if (handle && typeof handle.destroy === 'function') {
          try { await handle.destroy() } catch {}
        }
        this._discoveryHandles.delete(topicHex)
      }
    }
  }

  _firstPeerId() {
    return this._peers.keys().next().value || null
  }

  noisePublicKey() {
    const key = this._swarm && this._swarm.swarm && this._swarm.swarm.keyPair
    if (key && key.publicKey) return key.publicKey.toString('hex')
    if (this._noisePublicHex) return this._noisePublicHex
    if (this._noiseSeed) {
      try {
        const hc = require('hypercore-crypto')
        this._noisePublicHex = hc.keyPair(this._noiseSeed).publicKey.toString('hex')
        return this._noisePublicHex
      } catch {
        this._noisePublicHex = createHash('sha256').update(this._noiseSeed).digest('hex')
        return this._noisePublicHex
      }
    }
    return null
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
    if (peer.authState !== AUTH_AUTHENTICATED && channel !== 'control') {
      throw new Error('application traffic before authorization')
    }
    const payload = Buffer.isBuffer(frame) ? frame : Buffer.from(JSON.stringify(frame))
    peer.socket.write(encodeMux(channel, payload))
  }

  async authorize(peerId) {
    const peer = this._requirePeer(peerId)
    if (peer.authState === AUTH_REJECTED) throw new Error('peer already rejected')
    peer.authState = AUTH_AUTHENTICATED
    this._resolveAuthWaiter(peer, true)
    this._emitAuthenticated(peer)
    return { peerId: peer.logicalPeerId || String(peerId), authorized: true }
  }

  async deny(peerId) {
    const peer = this._requirePeer(peerId)
    peer.authState = AUTH_REJECTED
    this._resolveAuthWaiter(peer, false)
    this._emit('rejected', { peerId: peer.logicalPeerId || String(peerId) })
    this._handlePeerDisconnect(peer, new Error('authorization denied'))
    return { peerId: String(peerId), authorized: false }
  }

  _requirePeer(peerId) {
    const peer = this._peers.get(String(peerId))
    if (!peer) throw new Error('unknown peer ' + peerId)
    return peer
  }

  _isTransportUp(existing) {
    return Boolean(
      existing &&
        existing.socket &&
        !existing.socket.destroyed &&
        !existing.closed &&
        existing.authState !== AUTH_REJECTED,
    )
  }

  _resolveAuthWaiter(peer, authorized) {
    const id = peer.logicalPeerId || peer.alias
    const waiter = id && this._authWaiters.get(id)
    if (!waiter) return
    this._authWaiters.delete(id)
    waiter(authorized)
  }

  async sendFile(peerId, file) {
    const peer = this._peers.get(peerId)
    if (!peer || peer.authState !== AUTH_AUTHENTICATED) {
      throw new Error('application traffic before authorization')
    }
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
    // 1. Reject all pending connection waiters
    const waiters = this._connWaiters.splice(0)
    for (const w of waiters) {
      try {
        w.reject(new Error('worklet stopped'))
      } catch {}
    }

    // 2. Destroy and cleanup all active peer connections
    for (const connRecord of Array.from(this._connections)) {
      this._handlePeerDisconnect(connRecord, null)
    }
    this._connections.clear()
    this._peers.clear()

    // 3. Destroy all DHT sockets
    for (const sock of this._dhtSockets) {
      try {
        sock.destroy()
      } catch {}
    }
    this._dhtSockets = []

    // 4. Destroy DHT server
    if (this._dhtServer) {
      await this._dhtServer.close()
      this._dhtServer = null
    }

    // 5. Destroy DHT instance
    if (this._dht) {
      await this._dht.destroy()
      this._dht = null
    }

    // 6. Destroy bootstrapper
    if (this._bootstrapper) {
      await this._bootstrapper.destroy()
      this._bootstrapper = null
    }

    // 7. Destroy all discovery handles exactly once
    for (const [topicHex, handle] of this._discoveryHandles) {
      if (handle && typeof handle.destroy === 'function') {
        try { await handle.destroy() } catch {}
      }
    }
    this._discoveryHandles.clear()
    this._publishedTopic = null
    this._publishedDiscovery = null
    this._peerTopics.clear()

    // 8. Destroy swarm and loopback
    if (this._swarm) {
      if (typeof this._swarm.destroy === 'function') {
        await this._swarm.destroy()
      }
      this._swarm = null
    }
    await this._loop.destroy()

    // 9. Close journal
    if (this._journal && typeof this._journal.close === 'function') {
      await this._journal.close()
      this._journal = null
    }

    // 10. Clean up incoming partial files
    if (this._incomingFiles) {
      for (const incoming of this._incomingFiles.values()) {
        try { fs.closeSync(incoming.fd) } catch {}
        try { fs.unlinkSync(incoming.path) } catch {}
      }
      this._incomingFiles.clear()
    }

    // 11. Clean up outgoing file transfer fd
    if (this._sendFileFd) {
      try { fs.closeSync(this._sendFileFd) } catch {}
      this._sendFileFd = null
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

    const decoder = new MuxDecoder()
    const connRecord = {
      socket,
      info,
      decoder,
      noise,
      logicalPeerId: null,
      authState: AUTH_IDENTITY_PENDING,
      emittedConnected: false,
      emittedAuthenticated: false,
      closed: false,
    }
    this._connections.add(connRecord)

    // Wire socket error handling (F-02)
    socket.on('error', (err) => {
      // NoiseSecretStream or Bare socket error on remote close (ECONNRESET, etc.)
      this._handlePeerDisconnect(connRecord, err)
    })

    socket.on('close', () => {
      try { decoder.close() } catch {}
      this._handlePeerDisconnect(connRecord, null)
    })

    socket.on('data', (chunk) => {
      if (connRecord.closed) return
      let frames
      try {
        frames = decoder.add(chunk)
      } catch (err) {
        // Bad mux chunk
        try { decoder.close() } catch {}
        this._handlePeerDisconnect(connRecord, err)
        return
      }
      for (const frame of frames) {
        this._onFrame(connRecord, frame.channel, frame.payload)
      }
    })

    // Loopback may alias the socket, but application traffic stays gated.
    if (this.backend === 'loopback' && info && info.id) {
      connRecord.alias = info.id
      this._peers.set(info.id, connRecord)
      connRecord.authState = AUTH_IDENTITY_PENDING
      this._emit('identity-pending', {
        peerId: info.id,
        path: (info && info.path) || 'unknown',
      })
    }

    // Always announce our own identity immediately on connect
    this._announceIdentityToConn(connRecord)
  }

  _announceIdentityToConn(connRecord) {
    const localId = this._config && this._config.peerId
    if (!localId || connRecord.closed || !connRecord.socket) return
    const binding = this._localBinding || null
    const logical =
      (binding && (binding.ownerPeerId || binding.peerId)) || localId
    const msg = {
      type: 'orbits-identity',
      peerId: logical,
      noisePublicKey: this.noisePublicKey(),
      binding,
    }
    try {
      connRecord.socket.write(
        encodeMux(
          'control',
          Buffer.from(JSON.stringify(msg), 'utf8'),
        ),
      )
    } catch {
      // socket already closed
    }
  }

  _assignLogicalPeer(connRecord, logicalPeerId, binding = null) {
    if (connRecord.closed) return
    if (connRecord.logicalPeerId === logicalPeerId && !binding) return

    connRecord.logicalPeerId = logicalPeerId
    connRecord.binding = binding || connRecord.binding || null
    if (connRecord.authState !== AUTH_AUTHENTICATED) {
      connRecord.authState = AUTH_IDENTITY_PENDING
    }
    this._peers.set(logicalPeerId, connRecord)

    this._emit('identity-pending', {
      peerId: logicalPeerId,
      binding: connRecord.binding,
      connectionNoisePublicKey: connRecord.noise || null,
    })

    // Connect waiters resolve once identity is known. Application
    // traffic still waits for authorize().
    for (let i = this._connWaiters.length - 1; i >= 0; i--) {
      const waiter = this._connWaiters[i]
      if (!waiter.targetPeerId || waiter.targetPeerId === logicalPeerId) {
        this._connWaiters.splice(i, 1)
        waiter.resolve(logicalPeerId)
      }
    }
  }

  _emitAuthenticated(connRecord) {
    const logicalPeerId = connRecord.logicalPeerId || connRecord.alias
    if (!logicalPeerId || connRecord.closed) return
    if (!connRecord.emittedAuthenticated && connRecord.binding) {
      connRecord.emittedAuthenticated = true
      this._emit('authenticated', {
        peerId: logicalPeerId,
        binding: connRecord.binding,
        connectionNoisePublicKey: connRecord.noise || null,
      })
    }
    if (!connRecord.emittedConnected) {
      connRecord.emittedConnected = true
      this._emit('connected', {
        peerId: logicalPeerId,
        path: (connRecord.info && connRecord.info.path) || 'unknown',
      })
      this._emit('pathChanged', {
        peerId: logicalPeerId,
        path: (connRecord.info && connRecord.info.path) || 'direct',
      })
    }
  }

  _handlePeerDisconnect(connRecord, err) {
    if (connRecord.closed) return
    connRecord.closed = true

    this._connections.delete(connRecord)

    try {
      if (connRecord.decoder && typeof connRecord.decoder.close === 'function') {
        connRecord.decoder.close()
      }
    } catch {}
    try {
      connRecord.socket.destroy()
    } catch {}

    if (connRecord.alias) {
      this._peers.delete(connRecord.alias)
    }

    const logicalId = connRecord.logicalPeerId
    if (logicalId) {
      if (this._peers.get(logicalId) === connRecord) {
        this._peers.delete(logicalId)
      }
      if (connRecord.emittedConnected) {
        connRecord.emittedConnected = false
        this._emit('disconnected', { peerId: logicalId })
      }

      // Reject any pending waiters specifically targeted at this peer (F-07)
      for (let i = this._connWaiters.length - 1; i >= 0; i--) {
        const waiter = this._connWaiters[i]
        if (waiter.targetPeerId === logicalId) {
          this._connWaiters.splice(i, 1)
          waiter.reject(new Error('peer disconnected: ' + logicalId))
        }
      }
    }
  }

  _onFrame(connRecord, channel, payload) {
    if (connRecord.closed) return
    const frameB64 = payload.toString('base64')
    let body
    try {
      body = JSON.parse(payload.toString('utf8'))
    } catch {
      if (connRecord.authState !== AUTH_AUTHENTICATED) {
        this._handlePeerDisconnect(connRecord, new Error('pre-auth binary frame'))
        return
      }
      this._emit('frame', {
        peerId: connRecord.logicalPeerId,
        channel,
        frameB64,
      })
      return
    }

    const type = body && body.type
    if (channel === 'control' && type === 'orbits-identity') {
      this._handleIdentityFrame(connRecord, body)
      return
    }

    if (connRecord.authState !== AUTH_AUTHENTICATED) {
      if (!PRE_AUTH_TYPES.has(type)) {
        this._handlePeerDisconnect(connRecord, new Error('pre-auth frame: ' + (type || channel)))
      }
      return
    }

    const peerId = connRecord.logicalPeerId
    if (!peerId) {
      this._handlePeerDisconnect(connRecord, new Error('authenticated without logical peer'))
      return
    }

    if (channel === 'message' && type === 'harness-echo') {
      this.send(peerId, 'message', {
        type: 'harness-echo-reply',
        id: body.id,
        text: body.text,
      }).catch(() => {})
    }

    if (channel === 'attachment' && body) {
      this._handleAttachmentFrame(connRecord, peerId, body)
    }

    this._emit('frame', { peerId, channel, body, frameB64 })
  }

  _handleIdentityFrame(connRecord, body) {
    if (this.backend === 'hyperswarm') {
      const binding = body.binding
      if (!binding || !binding.transportPublicKeyB64) {
        this._handlePeerDisconnect(connRecord, new Error('IDENTITY_BINDING_REQUIRED'))
        return
      }
      if (!connRecord.noise) {
        this._handlePeerDisconnect(connRecord, new Error('NOISE_KEY_MISSING'))
        return
      }
      try {
        const transportHex = Buffer.from(binding.transportPublicKeyB64, 'base64').toString('hex')
        if (transportHex !== connRecord.noise) {
          this._handlePeerDisconnect(connRecord, new Error('NOISE_KEY_MISMATCH'))
          return
        }
      } catch (err) {
        this._handlePeerDisconnect(connRecord, err)
        return
      }
      const logical = binding.ownerPeerId || binding.peerId
      if (!logical) {
        this._handlePeerDisconnect(connRecord, new Error('IDENTITY_OWNER_REQUIRED'))
        return
      }
      this._assignLogicalPeer(connRecord, String(logical), binding)
      return
    }
    if (body.peerId) {
      this._assignLogicalPeer(connRecord, String(body.peerId), body.binding || null)
    }
  }

  _handleAttachmentFrame(connRecord, peerId, body) {
    const type = body.type
    if (HARNESS_FILE_TYPES.has(type) && !this.allowHarnessFiles) {
      this._handlePeerDisconnect(connRecord, new Error('harness-file-disabled'))
      return
    }
    if (type === 'harness-file-start' || type === 'file-start') {
      this._openIncomingOffer(connRecord, peerId, body)
      return
    }
    if (type === 'harness-file-chunk' || type === 'file-chunk') {
      this._writeIncomingChunk(peerId, body)
      return
    }
    if (type === 'harness-file-end' || type === 'file-end') {
      this._finishIncomingFile(peerId, body)
    }
  }

  _openIncomingOffer(connRecord, peerId, body) {
    let externalId
    try {
      externalId = incomingPaths.assertSafeTransferId(body.id)
    } catch (err) {
      this._handlePeerDisconnect(connRecord, err)
      return
    }
    const trustedSender = incomingPaths.assertSafeSenderId(peerId)
    const localId = incomingPaths.generateLocalStorageId()
    const dir = incomingPaths.resolveIncomingDir(this._incomingBase, trustedSender, localId)
    incomingPaths.assertInsideRoot(this._incomingRoot, dir)
    fs.mkdirSync(dir, { recursive: true })
    const tempPath = incomingPaths.blobPathFor(dir)
    incomingPaths.assertInsideRoot(this._incomingRoot, tempPath)
    const metaPath = path.join(dir, 'meta.json')
    const meta = {
      trustedSender,
      trustedDevice: (connRecord.binding && connRecord.binding.deviceId) || null,
      externalTransferId: externalId,
      localTransferId: localId,
      fileName: String(body.name || 'blob'),
      expectedSize: Number(body.size || 0),
      expectedHash: body.sha256 || null,
      protocolVersion: 1,
    }
    fs.writeFileSync(metaPath, JSON.stringify(meta))
    const flags = fs.existsSync(tempPath) ? 'r+' : 'wx'
    const fd = fs.openSync(tempPath, flags)
    this._incomingFiles = this._incomingFiles || new Map()
    this._incomingFiles.set(`${trustedSender}|${externalId}`, {
      fd,
      path: tempPath,
      dir,
      name: meta.fileName,
      size: meta.expectedSize,
      sha256: meta.expectedHash,
      hasher: createHash('sha256'),
      writtenBytes: 0,
      owner: trustedSender,
      localId,
    })
  }

  _writeIncomingChunk(peerId, body) {
    let id
    try {
      id = incomingPaths.assertSafeTransferId(body.id)
    } catch {
      return
    }
    this._incomingFiles = this._incomingFiles || new Map()
    const incoming = this._incomingFiles.get(`${peerId}|${id}`)
    if (!incoming || !body.b64) return
    const chunkBuf = Buffer.from(body.b64, 'base64')
    const offset = Number(body.offset || 0)
    fs.writeSync(incoming.fd, chunkBuf, 0, chunkBuf.length, offset)
    incoming.hasher.update(chunkBuf)
    incoming.writtenBytes += chunkBuf.length
  }

  _finishIncomingFile(peerId, body) {
    let id
    try {
      id = incomingPaths.assertSafeTransferId(body.id)
    } catch {
      return
    }
    this._incomingFiles = this._incomingFiles || new Map()
    const incoming = this._incomingFiles.get(`${peerId}|${id}`)
    if (!incoming) return
    this._incomingFiles.delete(`${peerId}|${id}`)
    fs.closeSync(incoming.fd)
    const actualSha = incoming.hasher.digest('hex')
    const expectedSha = body.sha256 || incoming.sha256
    if (expectedSha && actualSha !== expectedSha) {
      try { fs.unlinkSync(incoming.path) } catch {}
      this._emit('error', { code: 'file-hash', message: 'attachment hash mismatch' })
      return
    }
    this._emit('frame', {
      peerId,
      channel: 'attachment',
      body: {
        type: 'harness-file-received',
        id,
        localId: incoming.localId,
        path: incoming.path,
        size: incoming.writtenBytes,
        sha256: actualSha,
      },
    })
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
    case 'authorize':
      return await worklet.authorize(params.peerId)
    case 'deny':
      return await worklet.deny(params.peerId)
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
        published: Boolean(worklet._publishedTopic),
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

module.exports = { Worklet, handleIpcRequest, parseWorkletArgv, secretToBuffer }

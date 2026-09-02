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
const {
  encodeMux,
  MuxDecoder,
  FrameError,
  MAX_MUX_FRAME_BYTES,
} = require('./mux')
const { contactDiscoveryTopic, asSecret, MIN_DISCOVERY_SECRET_BYTES } = require('./discovery')
const { LoopbackBackend } = require('./loopback')
const { REQUEST, RESPONSE, EVENT, encode, Decoder } = require('./ipc')
const { CorestoreJournal } = require('./corestore_journal')
const { AutobaseProjection, objectHasLiveForbiddenKeys } = require('./autobase')

const FILE_CHUNK = 64 * 1024
const MAX_FILE_BYTES = 64 * 1024 * 1024
const OUTBOUND_QUEUE_CAP = 4 * 1024 * 1024
const PRE_AUTH_TYPES = new Set(['device-binding', 'harness-hello'])

// Attachment ciphertext must not carry named secrets. Same names as Dart
// kForbiddenReplicationFields. Do not add `b64` — that is the chunk
// ciphertext field and must stay allowed on this ingest path.
const ATTACH_FORBIDDEN_KEYS = new Set([
  'plaintext',
  'password',
  'kek',
  'vaultKek',
  'rootKey',
  'sendCk',
  'recvCk',
  'dhPriv',
  'skipped',
  'discoverySecret',
  'sharedDiscoverySecret',
  'attachmentBytes',
  'fileKey',
  'fileKeyB64',
  'identityPrivateKey',
  'privBytes',
])

const IPC_FORBIDDEN_KEYS = new Set([
  'identityPrivateKey',
  'fileKey',
  'fileKeyB64',
  'discoverySecret',
])

/**
 * Cycle-safe walk of objects/arrays. Rejects if any key is in
 * ATTACH_FORBIDDEN_KEYS, including nested `{ meta: { fileKey } }`.
 */
function attachBodyHasForbiddenKey(value, seen) {
  if (!value || typeof value !== 'object') return false
  const walk = seen || new Set()
  if (walk.has(value)) return false
  walk.add(value)
  if (Array.isArray(value)) {
    for (const item of value) {
      if (attachBodyHasForbiddenKey(item, walk)) return true
    }
    return false
  }
  for (const [key, child] of Object.entries(value)) {
    if (ATTACH_FORBIDDEN_KEYS.has(key)) return true
    if (attachBodyHasForbiddenKey(child, walk)) return true
  }
  return false
}

function objectHasKeysFrom(value, forbidden, seen) {
  if (!value || typeof value !== 'object') return false
  const walk = seen || new Set()
  if (walk.has(value)) return false
  walk.add(value)
  if (Array.isArray(value)) {
    return value.some((item) => objectHasKeysFrom(item, forbidden, walk))
  }
  for (const [k, v] of Object.entries(value)) {
    if (forbidden.has(k)) return true
    if (objectHasKeysFrom(v, forbidden, walk)) return true
  }
  return false
}

function ipcPayloadHasForbiddenKey(value) {
  return objectHasKeysFrom(value, IPC_FORBIDDEN_KEYS)
}

function assertLocalPath(p, label) {
  if (p == null || p === '') return
  if (typeof p === 'string' && p.includes('://')) {
    const err = new Error(label + ' refuses :// path')
    err.code = 'remote-path'
    throw err
  }
}

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

function waitDrain(socket) {
  return new Promise((resolve, reject) => {
    const onDrain = () => {
      cleanup()
      resolve()
    }
    const onClose = () => {
      cleanup()
      reject(Object.assign(new Error('socket-closed'), { code: 'socket-closed' }))
    }
    const onError = (err) => {
      cleanup()
      reject(err)
    }
    const cleanup = () => {
      socket.off('drain', onDrain)
      socket.off('close', onClose)
      socket.off('error', onError)
    }
    socket.once('drain', onDrain)
    socket.once('close', onClose)
    socket.once('error', onError)
  })
}

// Stream a file for hashing. Never load the whole blob into one buffer.
function hashPath(filePath) {
  assertLocalPath(filePath, 'hashPath')
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
    this._harnessAuth = opts.harnessAuth || 'local'
    this._loop = new LoopbackBackend()
    this._swarm = null
    this._peers = new Map()
    this._peerHistory = new Map()
    this._started = false
    this._suspended = false
    this._lifecycle = 'idle'
    this._diagnosticsEnabled = false
    this._config = null
    this._topic = null
    this.events = []
    this._journal = new CorestoreJournal('local-device')
    this._autobase = new AutobaseProjection()
    this._files = new Map()
    this._attachFiles = new Map()
    this._resumeOffsets = new Map()
    this._resumeWaiters = new Map()
    this._noiseToPeerId = new Map()
    this._timers = new Set()
    this._fileCancels = new Set()
    this._outgoingFiles = new Map()
    this._droppedPreAuth = 0
    this._oversizedFrames = 0
    this._totals = { bytesSent: 0, bytesReceived: 0, connections: 0 }
    this._outboundQueueCap = Number(opts.outboundQueueCap) || OUTBOUND_QUEUE_CAP
    this.fileSendBudget = null
    this._emit = opts.emit || ((name, payload) => this.events.push({ name, payload }))
  }

  _schedule(fn, ms) {
    const t = setTimeout(() => {
      this._timers.delete(t)
      fn()
    }, ms)
    if (typeof t.unref === 'function') t.unref()
    this._timers.add(t)
    return t
  }

  _cancelTimer(t) {
    if (!t) return
    clearTimeout(t)
    this._timers.delete(t)
  }

  /// Map a Hyperswarm Noise public key to the contact ORBIT id from Dart
  /// `connect({ peerId, noisePublicKey })`. Discovery topics stay
  /// HASH("orbits-contact-discovery-v1" || sharedSecret). Noise is not
  /// the identity key.
  _rememberOrbitPeer(orbitId, noiseHex) {
    if (typeof orbitId !== 'string' || typeof noiseHex !== 'string') return
    const id = orbitId.trim()
    const hex = noiseHex.trim().toLowerCase()
    if (!id || id.includes('://')) return
    if (!/^[0-9a-f]+$/.test(hex) || hex.length < 64) return
    this._noiseToPeerId.set(hex, id)
    for (const [key, peer] of this._peers) {
      if (key === id) continue
      const pk =
        peer.info && peer.info.publicKey
          ? Buffer.from(peer.info.publicKey).toString('hex').toLowerCase()
          : ''
      if (pk !== hex && key.toLowerCase() !== hex) continue
      this._peers.delete(key)
      peer.peerId = id
      this._peers.set(id, peer)
      this._emit('connected', {
        peerId: id,
        path: (peer.info && peer.info.path) || 'direct',
      })
    }
  }

  _resolvePeerId(info) {
    const pk =
      info && info.publicKey
        ? Buffer.from(info.publicKey).toString('hex').toLowerCase()
        : ''
    if (pk && this._noiseToPeerId.has(pk)) return this._noiseToPeerId.get(pk)
    if (info && typeof info.id === 'string' && info.id.length > 0) return info.id
    return pk
  }

  async start(config) {
    this._lifecycle = 'starting'
    this._config = config || {}
    if (this._config.discoverySecret != null) {
      asSecret(this._config.discoverySecret)
    }
    assertLocalPath(this._config.journalDir, 'journal')
    assertLocalPath(this._config.worklet, 'worklet')
    assertLocalPath(this._config.workletPath, 'worklet')
    this._diagnosticsEnabled = Boolean(this._config.diagnosticsEnabled)
    this._started = true
    try {
      const journalDir = localJournalDir(this._config.journalDir)
      await this._journal.useCorestoreIfPresent(journalDir || undefined)
    } catch {
      this._journal.backend = 'memory'
    }
    this._hydrateAutobaseFromJournal()
    if (this.backend === 'loopback') {
      await this._loop.listen(this._config.listenHost)
      this._loop.on('connection', (sock, info) => this._onConn(sock, info))
    } else {
      const { createHyperswarmBackend } = require('./swarm')
      const swarmOpts = {
        bootstrap: this._config.bootstrap,
        keyPair: this._config.keyPair,
        firewall: this._config.firewall,
        relayForced: Boolean(this._config.relayForced),
        relayThrough: this._config.relayThrough,
      }
      if (this._config.seed) {
        swarmOpts.seed = Buffer.isBuffer(this._config.seed)
          ? this._config.seed
          : Buffer.from(this._config.seed)
      }
      this._swarm = await createHyperswarmBackend(swarmOpts)
      this._swarm.onConnection((sock, info) => this._onConn(sock, info))
    }
    this._lifecycle = 'started'
    this._emit('started', {
      backend: this.backend,
      port: this._loop.port,
      noisePublicKey: this.noisePublicKeyHex(),
      journalBackend: this._journal.backend,
      diagnosticsEnabled: this._diagnosticsEnabled,
    })
  }

  noisePublicKeyHex() {
    const kp = this._swarm && this._swarm.swarm && this._swarm.swarm.keyPair
    return kp && kp.publicKey ? Buffer.from(kp.publicKey).toString('hex') : null
  }

  async publish(binding) {
    const secret = asSecret(this._config && this._config.discoverySecret)
    this._topic = contactDiscoveryTopic(secret)
    if (this._swarm) await this._swarm.join(this._topic)
    this._emit('published', { topicHex: this._topic.toString('hex'), binding })
  }

  async unpublish() {
    if (this._swarm && this._topic) await this._swarm.leave(this._topic)
  }

  async connect(peer) {
    if (this._suspended) throw new Error('suspended')
    this.rememberPeer(peer)
    const timeoutMs = Number(peer && peer.timeoutMs) || 0
    const inner = this._connectInner(peer)
    if (!timeoutMs) {
      await inner
      return
    }
    let timer
    const timeout = new Promise((_, reject) => {
      timer = this._schedule(() => {
        const err = new Error('connect-timeout')
        err.code = 'connect-timeout'
        reject(err)
      }, timeoutMs)
    })
    try {
      await Promise.race([inner, timeout])
    } finally {
      this._cancelTimer(timer)
    }
  }

  async _connectInner(peer) {
    if (this.backend === 'loopback') {
      if (peer.port == null) throw new Error('loopback connect needs port')
      const host = peer.host || '127.0.0.1'
      assertLocalPath(host, 'connect')
      await this._loop.connect(peer.port, {
        host,
        timeoutMs: Number(peer.timeoutMs) || 0,
      })
    } else if (this._swarm) {
      const noise =
        peer && peer.noisePublicKey != null ? String(peer.noisePublicKey) : ''
      if (noise) this._swarm.swarm.joinPeer(Buffer.from(noise, 'hex'))
    }
  }

  rememberPeer(peer) {
    const noise =
      peer && peer.noisePublicKey != null ? String(peer.noisePublicKey) : ''
    const orbitId = peer && peer.peerId != null ? String(peer.peerId) : ''
    this._rememberOrbitPeer(orbitId, noise)
  }

  markAuthenticated(peerId) {
    if (typeof peerId !== 'string' || !peerId || peerId.includes('://')) return
    const peer = this._peers.get(peerId)
    if (!peer || peer.authenticated) return
    peer.authenticated = true
    this._emit('authenticated', { peerId })
  }

  async disconnect(peerId) {
    if (typeof peerId !== 'string' || !peerId || peerId.includes('://')) return
    const peer = this._peers.get(peerId)
    if (!peer) return
    peer.disconnectReason = 'local-disconnect'
    this._peers.delete(peerId)
    this._recordHistory(peer, 'local-disconnect')
    if (peer.socket) {
      if (typeof peer.socket.destroy === 'function') peer.socket.destroy()
      else if (typeof peer.socket.end === 'function') peer.socket.end()
    }
    this._emit('disconnected', { peerId, reason: 'local-disconnect' })
  }

  _recordHistory(peer, reason) {
    if (!peer || !peer.peerId) return
    const prev = this._peerHistory.get(peer.peerId) || { retryCount: 0 }
    this._peerHistory.set(peer.peerId, {
      retryCount: prev.retryCount,
      disconnectReason: reason || peer.disconnectReason || 'closed',
      lastPath: peer.info && peer.info.path,
    })
  }

  async send(peerId, channel, frame) {
    if (this._suspended) throw new Error('suspended')
    const peer = this._peers.get(peerId)
    if (!peer) throw new Error('not connected: ' + peerId)
    if (frame && typeof frame === 'object' && !Buffer.isBuffer(frame)) {
      if (ipcPayloadHasForbiddenKey(frame) || attachBodyHasForbiddenKey(frame)) {
        throw new Error('send refuses forbidden key')
      }
    }
    const payload = Buffer.isBuffer(frame) ? frame : Buffer.from(JSON.stringify(frame))
    if (payload.length > MAX_MUX_FRAME_BYTES) {
      this._oversizedFrames += 1
      const err = new FrameError('oversized-frame', 'send payload exceeds MAX_MUX_FRAME_BYTES')
      throw err
    }
    if (channel === 'control') {
      this._applyControlAutobase(
        payload,
        (this._config && this._config.peerId) || 'local',
      )
    }
    const encoded = encodeMux(channel, payload)
    if (peer.outBytes + encoded.length > this._outboundQueueCap) {
      const err = new Error('outbound-queue-full')
      err.code = 'outbound-queue-full'
      throw err
    }
    peer.outBytes += encoded.length
    if (peer.outBytes > peer.maxOutBytes) peer.maxOutBytes = peer.outBytes
    return new Promise((resolve, reject) => {
      peer.outQ.push({ buf: encoded, resolve, reject, bytes: encoded.length })
      this._flushOut(peer)
    })
  }

  async _flushOut(peer) {
    if (peer.flushing) return
    peer.flushing = true
    try {
      while (peer.outQ.length) {
        const item = peer.outQ.shift()
        try {
          if (!peer.socket || peer.socket.destroyed) {
            throw Object.assign(new Error('socket-closed'), { code: 'socket-closed' })
          }
          const ok = peer.socket.write(item.buf)
          peer.bytesSent += item.bytes
          this._totals.bytesSent += item.bytes
          if (!ok) await waitDrain(peer.socket)
          peer.outBytes -= item.bytes
          item.resolve()
        } catch (err) {
          peer.outBytes -= item.bytes
          item.reject(err)
        }
      }
    } finally {
      peer.flushing = false
      if (peer.outQ.length) this._flushOut(peer)
    }
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
    // Nested walk: `{ meta: { fileKey } }` must not stream. Same set as
    // inbound `_ingestAttachChunk`. Do not add `b64` — chunk ciphertext.
    if (attachBodyHasForbiddenKey(file) || ipcPayloadHasForbiddenKey(file)) {
      throw new Error('sendFile refuses fileKey')
    }
    if (file.protocol === 'attach-chunk') {
      await this._sendAttachChunk(peerId, file)
      return
    }
    const { digest, size } = hashPath(file.path)
    if (size > MAX_FILE_BYTES) {
      const err = new Error('file-too-large')
      err.code = 'file-too-large'
      throw err
    }
    const id = typeof file.id === 'string' && file.id ? file.id : digest.slice(0, 16)
    if (id.includes('://')) throw new Error('sendFile refuses remote path')
    const resumeOffset = Number(file.resumeOffset) || 0
    if (resumeOffset < 0 || resumeOffset > size) {
      throw new Error('sendFile resumeOffset out of range')
    }
    const outgoing = { id, peerId, cancelled: false, size, path: file.path }
    this._outgoingFiles.set(id, outgoing)
    const onAbort = () => {
      outgoing.cancelled = true
      this._fileCancels.add(id)
    }
    if (file.signal && typeof file.signal.addEventListener === 'function') {
      if (file.signal.aborted) onAbort()
      else file.signal.addEventListener('abort', onAbort)
    }
    try {
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
          if (this._fileCancels.has(id) || outgoing.cancelled) {
            const err = new Error('file-cancelled')
            err.code = 'file-cancelled'
            throw err
          }
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
      if (this._fileCancels.has(id) || outgoing.cancelled) {
        const err = new Error('file-cancelled')
        err.code = 'file-cancelled'
        throw err
      }
      await this.send(peerId, 'attachment', { type: 'harness-file-end', id })
    } finally {
      if (file.signal && typeof file.signal.removeEventListener === 'function') {
        file.signal.removeEventListener('abort', onAbort)
      }
      this._outgoingFiles.delete(id)
    }
  }

  async cancelFile(id) {
    if (typeof id !== 'string' || !id) throw new Error('cancelFile needs id')
    if (id.includes('://')) throw new Error('cancelFile refuses :// path')
    this._fileCancels.add(id)
    const outgoing = this._outgoingFiles.get(id)
    if (outgoing) outgoing.cancelled = true
    const incoming = this._files.get(id)
    if (incoming) {
      try {
        fs.closeSync(incoming.fd)
      } catch {
        // already closed
      }
      try {
        fs.unlinkSync(incoming.path)
      } catch {
        // already gone
      }
      try {
        fs.rmSync(path.dirname(incoming.path), { recursive: true, force: true })
      } catch {
        // temp already gone
      }
      this._files.delete(id)
    }
    const notifyPeer = (outgoing && outgoing.peerId) || null
    const targets = notifyPeer ? [notifyPeer] : Array.from(this._peers.keys())
    for (const peerId of targets) {
      if (!this._peers.has(peerId)) continue
      this.send(peerId, 'attachment', { type: 'harness-file-cancel', id }).catch(() => {})
    }
    this._emit('file-cancelled', { id })
  }

  async _sendAttachChunk(peerId, file) {
    const fileId = typeof file.fileId === 'string' ? file.fileId : ''
    if (!fileId) throw new Error('attach-chunk needs fileId')
    if (fileId.includes('://')) throw new Error('sendFile refuses remote path')
    let offset = Number(file.resumeOffset) || 0
    const size = fs.statSync(file.path).size
    if (size > MAX_FILE_BYTES) {
      const err = new Error('file-too-large')
      err.code = 'file-too-large'
      throw err
    }
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
    this._lifecycle = 'suspended'
    if (this._swarm) await this._swarm.suspend()
    else await this._loop.suspend()
    this._emit('suspended', {})
  }

  async resume() {
    this._suspended = false
    this._lifecycle = this._started ? 'started' : 'idle'
    if (this._swarm) await this._swarm.resume()
    else await this._loop.resume()
    this._emit('resumed', {})
  }

  async refreshNetwork() {
    if (this._swarm) await this._swarm.refresh()
    this._emit('networkChanged', { detail: this.backend })
  }

  diagnostics() {
    const peers = {}
    for (const [id, peer] of this._peers) {
      const hist = this._peerHistory.get(id) || {}
      peers[id] = {
        path: (peer.info && peer.info.path) || 'unknown',
        connectDurationMs:
          peer.connectedAt != null ? Date.now() - peer.connectedAt : null,
        bytesSent: peer.bytesSent || 0,
        bytesReceived: peer.bytesReceived || 0,
        retryCount: hist.retryCount || peer.retryCount || 0,
        disconnectReason: hist.disconnectReason || peer.disconnectReason || null,
        authenticated: Boolean(peer.authenticated),
        queuedBytes: peer.outBytes || 0,
        maxQueuedBytes: peer.maxOutBytes || 0,
      }
    }
    const activeFileTransfers = []
    for (const incoming of this._files.values()) {
      activeFileTransfers.push({
        id: incoming.id,
        direction: 'recv',
        size: incoming.size,
        offset: nextContiguousOffset(incoming.ranges),
      })
    }
    for (const outgoing of this._outgoingFiles.values()) {
      activeFileTransfers.push({
        id: outgoing.id,
        direction: 'send',
        size: outgoing.size,
        cancelled: Boolean(outgoing.cancelled),
      })
    }
    return {
      lifecycle: this._lifecycle,
      backend: this.backend,
      transport: this.backend,
      topicHex: this._topic ? this._topic.toString('hex') : null,
      peers,
      totals: { ...this._totals },
      droppedPreAuth: this._droppedPreAuth,
      oversizedFrames: this._oversizedFrames,
      activeFileTransfers,
      outboundQueueCap: this._outboundQueueCap,
      maxFileBytes: MAX_FILE_BYTES,
      maxMuxFrameBytes: MAX_MUX_FRAME_BYTES,
      harnessAuth: this._harnessAuth,
    }
  }

  async stop() {
    this._lifecycle = 'stopping'
    for (const t of this._timers) clearTimeout(t)
    this._timers.clear()
    for (const waiter of this._resumeWaiters.values()) {
      try {
        waiter(0)
      } catch {
        // ignore
      }
    }
    this._resumeWaiters.clear()
    this._resumeOffsets.clear()
    for (const peer of this._peers.values()) {
      for (const item of peer.outQ || []) {
        try {
          item.reject(Object.assign(new Error('stopped'), { code: 'stopped' }))
        } catch {
          // ignore
        }
      }
      peer.outQ = []
      peer.outBytes = 0
      if (peer.socket) {
        try {
          if (typeof peer.socket.destroy === 'function') peer.socket.destroy()
          else if (typeof peer.socket.end === 'function') peer.socket.end()
        } catch {
          // already closed
        }
      }
    }
    this._peers.clear()
    for (const incoming of this._files.values()) {
      try {
        fs.closeSync(incoming.fd)
      } catch {
        // already closed
      }
    }
    this._files.clear()
    for (const incoming of this._attachFiles.values()) {
      try {
        fs.closeSync(incoming.fd)
      } catch {
        // already closed
      }
    }
    this._attachFiles.clear()
    this._outgoingFiles.clear()
    this._fileCancels.clear()
    if (this._loop && typeof this._loop.removeAllListeners === 'function') {
      this._loop.removeAllListeners('connection')
    }
    if (this._swarm) {
      try {
        await this._swarm.destroy()
      } catch {
        // already destroyed
      }
      this._swarm = null
    }
    await this._loop.destroy()
    try {
      await this._journal.close()
    } catch {
      // journal already closed
    }
    this._started = false
    this._suspended = false
    this._noiseToPeerId.clear()
    this._lifecycle = 'stopped'
  }

  _onConn(socket, info) {
    const peerId = this._resolvePeerId(info)
    const hist = this._peerHistory.get(peerId)
    const retryCount = hist ? hist.retryCount + 1 : 0
    if (hist) hist.retryCount = retryCount
    else this._peerHistory.set(peerId, { retryCount: 0 })
    const decoder = new MuxDecoder()
    const peer = {
      socket,
      info,
      decoder,
      peerId,
      authenticated: this._harnessAuth === 'local',
      helloSent: false,
      connectedAt: Date.now(),
      bytesSent: 0,
      bytesReceived: 0,
      outQ: [],
      outBytes: 0,
      maxOutBytes: 0,
      flushing: false,
      retryCount,
      disconnectReason: null,
    }
    this._peers.set(peerId, peer)
    this._totals.connections += 1
    this._emit('connected', { peerId, path: info.path || 'unknown' })
    this._emit('pathChanged', { peerId, path: info.path || 'direct' })
    if (peer.authenticated) this._emit('authenticated', { peerId })
    socket.on('data', (chunk) => {
      peer.bytesReceived += chunk.length
      this._totals.bytesReceived += chunk.length
      try {
        for (const frame of decoder.add(chunk)) {
          this._onFrame(peer.peerId, frame.channel, frame.payload)
        }
      } catch (err) {
        const code = err && err.code
        const reason = code === 'oversized-frame' ? 'oversized-frame' : 'malformed-frame'
        if (reason === 'oversized-frame') this._oversizedFrames += 1
        peer.disconnectReason = reason
        this._recordHistory(peer, reason)
        try {
          socket.destroy()
        } catch {
          // already closed
        }
        this._emit('disconnected', { peerId: peer.peerId, reason })
        const cur = this._peers.get(peer.peerId)
        if (cur === peer) this._peers.delete(peer.peerId)
      }
    })
    socket.on('error', () => {})
    socket.on('close', () => {
      const cur = this._peers.get(peer.peerId)
      if (cur !== peer) return
      this._peers.delete(peer.peerId)
      const reason = peer.disconnectReason || 'closed'
      this._recordHistory(peer, reason)
      this._emit('disconnected', { peerId: peer.peerId, reason })
    })
    if (this._harnessAuth === 'local' && !peer.helloSent) {
      peer.helloSent = true
      this.send(peerId, 'control', { type: 'harness-hello' }).catch(() => {})
    }
  }

  _isAuthenticated(peerId) {
    const peer = this._peers.get(peerId)
    if (!peer) return this._harnessAuth === 'local'
    return Boolean(peer.authenticated)
  }

  _onFrame(peerId, channel, payload) {
    const frameB64 = payload.toString('base64')
    let body
    try {
      body = JSON.parse(payload.toString('utf8'))
    } catch {
      if (!this._isAuthenticated(peerId)) {
        this._droppedPreAuth += 1
        return
      }
      this._emit('frame', { peerId, channel, frameB64 })
      return
    }
    const preAuthAllowed =
      channel === 'control' && body && PRE_AUTH_TYPES.has(body.type)
    if (!this._isAuthenticated(peerId) && !preAuthAllowed) {
      this._droppedPreAuth += 1
      return
    }
    if (channel === 'control' && body && body.type === 'harness-hello') {
      this.markAuthenticated(peerId)
      const peer = this._peers.get(peerId)
      if (peer && !peer.helloSent) {
        peer.helloSent = true
        this.send(peerId, 'control', { type: 'harness-hello' }).catch(() => {})
      }
    }
    if (channel === 'control' && body && body.type === 'device-binding') {
      // Dart marks the peer after its own checks. Emit so the host can
      // call markAuthenticated. Do not auto-auth in strict mode.
    }
    if (channel === 'message' && body.type === 'harness-echo') {
      this.send(peerId, 'message', {
        type: 'harness-echo-reply',
        id: body.id,
        text: body.text,
      }).catch(() => {})
    }
    if (channel === 'attachment') {
      if (this._handleIncomingFile(peerId, body) === true) return
    }
    if (channel === 'control') {
      if (!objectHasLiveForbiddenKeys(body)) {
        this._autobase.applyFromPacket(body, peerId)
      }
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
      const t = this._schedule(() => {
        this._resumeWaiters.delete(id)
        resolve(fallback)
      }, 2000)
      this._resumeWaiters.set(id, (n) => {
        this._cancelTimer(t)
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
    // Fail-close before fs.openSync / received. Same walk as
    // `_ingestAttachChunk`. Do not add `b64` or `text` to ATTACH_FORBIDDEN.
    if (attachBodyHasForbiddenKey(body)) return true
    if (typeof id === 'string' && id.includes('://')) return true
    if (
      type === 'harness-file-start' &&
      body &&
      typeof body.path === 'string' &&
      body.path.includes('://')
    ) {
      return true
    }
    if (type === 'harness-file-cancel') {
      if (id) {
        this._fileCancels.add(id)
        const outgoing = this._outgoingFiles.get(id)
        if (outgoing) outgoing.cancelled = true
        const incoming = this._files.get(id)
        if (incoming) {
          try {
            fs.closeSync(incoming.fd)
          } catch {
            // already closed
          }
          try {
            fs.unlinkSync(incoming.path)
          } catch {
            // already gone
          }
          try {
            fs.rmSync(path.dirname(incoming.path), { recursive: true, force: true })
          } catch {
            // temp already gone
          }
          this._files.delete(id)
        }
      }
      return true
    }
    if (type === 'attach-chunk') {
      this._ingestAttachChunk(peerId, body)
      return true
    }
    if (type === 'harness-file-resume') {
      if (id) this._onResume(id, Number(body.offset) || 0)
      return
    }
    if (type === 'harness-file-start') {
      const digest = body.sha256 || ''
      const size = Number(body.size) || 0
      if (size > MAX_FILE_BYTES) {
        this._emit('error', { code: 'file-too-large', message: 'incoming file exceeds MAX_FILE_BYTES' })
        return true
      }
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
          size,
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
      if (offset < 0 || offset + buf.length > MAX_FILE_BYTES) return
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
      const received = {
        type: 'harness-file-received',
        id,
        path: incoming.path,
        size: hashed.size,
        sha256: hashed.digest,
      }
      this._emit('frame', {
        peerId,
        channel: 'attachment',
        body: received,
        frameB64: Buffer.from(JSON.stringify(received)).toString('base64'),
      })
    }
    return false
  }

  _ingestAttachChunk(peerId, body) {
    if (!body || attachBodyHasForbiddenKey(body)) return
    const fileId = typeof body.fileId === 'string' ? body.fileId : ''
    if (!fileId || fileId.includes('://')) return
    const buf = Buffer.from(body.b64 || '', 'base64')
    if (!buf.length) return
    const offset = Number(body.offset) || 0
    if (offset < 0 || offset + buf.length > MAX_FILE_BYTES) return
    const hash = typeof body.hash === 'string' ? body.hash : ''
    if (hash) {
      const actual = createHash('sha256').update(buf).digest('hex')
      if (actual !== hash) return
    }
    let incoming = this._attachFiles.get(fileId)
    if (!incoming) {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-att-ct-'))
      const filePath = path.join(dir, 'cipher.bin')
      incoming = { path: filePath, fd: fs.openSync(filePath, 'w+') }
      this._attachFiles.set(fileId, incoming)
      const pathBody = { type: 'attach-chunk-path', fileId, path: filePath }
      this._emit('frame', {
        peerId,
        channel: 'attachment',
        body: pathBody,
        frameB64: Buffer.from(JSON.stringify(pathBody)).toString('base64'),
      })
    }
    fs.writeSync(incoming.fd, buf, 0, buf.length, offset)
    try {
      fs.fsyncSync(incoming.fd)
    } catch {
      // already flushed
    }
  }

  _applyControlAutobase(payload, fallbackWriter) {
    try {
      const body = JSON.parse(payload.toString('utf8'))
      if (objectHasLiveForbiddenKeys(body)) return
      this._autobase.applyFromPacket(body, fallbackWriter)
    } catch {
      // binary / non-JSON control frames are not Autobase events
    }
  }

  // Rebuild members from journal rows. Encrypted envelopes and message
  // bodies are skipped. Safe to call after open, append, or IPC hydrate.
  _hydrateAutobaseFromJournal(rows) {
    const list = Array.isArray(rows) ? rows : this._journal.list()
    return this._autobase.hydrateFromJournal(list)
  }
}

async function handleIpcRequest(worklet, body) {
  const method = body.method
  const params = body.params || {}
  if (method === 'send' || method === 'sendFile' || method === 'journal.append') {
    if (ipcPayloadHasForbiddenKey(params)) {
      throw new Error('refusing forbidden key in IPC payload')
    }
    if (method === 'send' && params.frame && ipcPayloadHasForbiddenKey(params.frame)) {
      throw new Error('refusing forbidden key in IPC payload')
    }
    if (method === 'sendFile' && params.file && ipcPayloadHasForbiddenKey(params.file)) {
      throw new Error('refusing forbidden key in IPC payload')
    }
  }
  if (method === 'start') {
    assertLocalPath(params.journalDir, 'journal')
    assertLocalPath(params.worklet, 'worklet')
    assertLocalPath(params.workletPath, 'worklet')
  }
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
    case 'disconnect':
      await worklet.disconnect(params.peerId)
      return {}
    case 'rememberPeer':
      worklet.rememberPeer(params)
      return {}
    case 'markAuthenticated':
      worklet.markAuthenticated(params.peerId)
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
      await worklet.cancelFile(params.id)
      return {}
    case 'diagnostics':
      return worklet.diagnostics()
    case 'suspend':
      await worklet.suspend()
      return {}
    case 'resume':
      await worklet.resume()
      return {}
    case 'refreshNetwork':
      await worklet.refreshNetwork()
      return {}
    case 'journal.append': {
      const stored = await worklet._journal.append(params)
      worklet._hydrateAutobaseFromJournal([stored])
      return stored
    }
    case 'journal.list': {
      const blocks = worklet._journal.list()
      worklet._hydrateAutobaseFromJournal(blocks)
      return { blocks }
    }
    case 'autobase.hydrate': {
      const rows = Array.isArray(params.rows)
        ? params.rows
        : Array.isArray(params.blocks)
          ? params.blocks
          : worklet._journal.list()
      const hydrated = worklet._hydrateAutobaseFromJournal(rows)
      return { hydrated, ...worklet._autobase.snapshot() }
    }
    case 'autobase.state':
      return worklet._autobase.snapshot()
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
    try {
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
    } catch (err) {
      process.stderr.write(String(err && err.message ? err.message : err) + '\n')
    }
  })
}

module.exports = {
  Worklet,
  handleIpcRequest,
  hashPath,
  FILE_CHUNK,
  MAX_FILE_BYTES,
  OUTBOUND_QUEUE_CAP,
  MAX_MUX_FRAME_BYTES,
  MIN_DISCOVERY_SECRET_BYTES,
  ATTACH_FORBIDDEN_KEYS,
  IPC_FORBIDDEN_KEYS,
  attachBodyHasForbiddenKey,
  ipcPayloadHasForbiddenKey,
  assertLocalPath,
}

'use strict'

const net = require('node:net')
const { EventEmitter } = require('node:events')

/**
 * Local TCP hub so two worklets can meet without a public DHT.
 * Host listens; guest connects. Path is always direct.
 */
class LoopbackBackend extends EventEmitter {
  constructor() {
    super()
    this._server = null
    this._sockets = new Map()
    this.suspended = false
    this.port = 0
  }

  async listen(host) {
    const bind = host == null || host === '' ? '127.0.0.1' : String(host)
    if (bind.includes('://')) throw new Error('listen refuses :// host')
    this._server = net.createServer((sock) => this._onSocket(sock, 'inbound'))
    await new Promise((resolve, reject) => {
      this._server.once('error', reject)
      this._server.listen(0, bind, () => {
        this._server.off('error', reject)
        resolve()
      })
    })
    const addr = this._server.address()
    this.port = addr.port
    this.host = addr.address
  }

  async connect(port, opts) {
    const options = opts && typeof opts === 'object' ? opts : {}
    const host = options.host == null || options.host === '' ? '127.0.0.1' : String(options.host)
    if (host.includes('://')) throw new Error('loopback refuses :// host')
    const timeoutMs = Number(options.timeoutMs) || 0
    const sock = net.connect({ host, port: Number(port) })
    await new Promise((resolve, reject) => {
      let timer = null
      const onConnect = () => {
        cleanup()
        resolve()
      }
      const onError = (err) => {
        cleanup()
        reject(err)
      }
      const cleanup = () => {
        sock.off('connect', onConnect)
        sock.off('error', onError)
        if (timer) clearTimeout(timer)
      }
      if (timeoutMs > 0) {
        timer = setTimeout(() => {
          cleanup()
          sock.destroy()
          const err = new Error('connect-timeout')
          err.code = 'connect-timeout'
          reject(err)
        }, timeoutMs)
        if (typeof timer.unref === 'function') timer.unref()
      }
      sock.once('connect', onConnect)
      sock.once('error', onError)
    })
    this._onSocket(sock, 'outbound')
  }

  _onSocket(sock, direction) {
    const id = `${direction}:${sock.remotePort}`
    this._sockets.set(id, sock)
    this.emit('connection', sock, {
      publicKey: Buffer.alloc(32, direction === 'inbound' ? 1 : 2),
      path: 'direct',
      id,
    })
    sock.on('close', () => this._sockets.delete(id))
  }

  async suspend() {
    this.suspended = true
    for (const sock of this._sockets.values()) sock.pause()
  }

  async resume() {
    this.suspended = false
    for (const sock of this._sockets.values()) sock.resume()
  }

  async destroy() {
    for (const sock of this._sockets.values()) sock.destroy()
    this._sockets.clear()
    if (this._server) {
      await new Promise((resolve) => this._server.close(resolve))
      this._server = null
    }
  }
}

module.exports = { LoopbackBackend }

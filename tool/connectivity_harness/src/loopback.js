'use strict'

const { net, events } = require('./bare_compat')
const { EventEmitter } = events

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

  async listen() {
    this._server = net.createServer((sock) => this._onSocket(sock, 'inbound'))
    await new Promise((resolve) => this._server.listen(0, '127.0.0.1', resolve))
    this.port = this._server.address().port
  }

  async connect(port) {
    const sock = net.connect({ host: '127.0.0.1', port })
    await new Promise((resolve, reject) => {
      sock.once('connect', resolve)
      sock.once('error', reject)
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

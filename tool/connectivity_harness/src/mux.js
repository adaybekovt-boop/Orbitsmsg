'use strict'

const CHANNELS = [
  'control',
  'message',
  'receipt',
  'presence',
  'replication',
  'attachment',
  'call',
  'diagnostics',
]
const VERSION = 1

function encodeMux(channel, payload) {
  const id = CHANNELS.indexOf(channel)
  if (id < 0) throw new Error('bad channel')
  const buf = Buffer.isBuffer(payload) ? payload : Buffer.from(payload)
  const header = Buffer.alloc(7)
  header.writeUInt8(VERSION, 0)
  header.writeUInt8(id, 1)
  header.writeUInt8(0, 2)
  header.writeUInt32BE(buf.length, 3)
  return Buffer.concat([header, buf])
}

class MuxDecoder {
  constructor() {
    this._buf = Buffer.alloc(0)
  }

  add(chunk) {
    this._buf = Buffer.concat([this._buf, chunk])
    const out = []
    while (this._buf.length >= 7) {
      const version = this._buf.readUInt8(0)
      if (version !== VERSION) throw new Error('bad mux version')
      const channel = CHANNELS[this._buf.readUInt8(1)]
      if (!channel) throw new Error('bad mux channel')
      const len = this._buf.readUInt32BE(3)
      if (this._buf.length < 7 + len) break
      out.push({ channel, payload: this._buf.subarray(7, 7 + len) })
      this._buf = this._buf.subarray(7 + len)
    }
    return out
  }
}

module.exports = { CHANNELS, encodeMux, MuxDecoder }

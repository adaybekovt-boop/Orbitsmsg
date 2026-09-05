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

/** One mux frame: 64 KiB file chunk + JSON/base64 envelope, not gigabytes. */
const MAX_MUX_FRAME_BYTES = 256 * 1024
/** Accumulated undecoded bytes across fragments. */
const MAX_MUX_BUFFER_BYTES = 512 * 1024
const HEADER_BYTES = 7

function encodeMux(channel, payload) {
  const id = CHANNELS.indexOf(channel)
  if (id < 0) throw new Error('bad channel')
  const buf = Buffer.isBuffer(payload) ? payload : Buffer.from(payload)
  if (buf.length > MAX_MUX_FRAME_BYTES) throw new Error('mux frame too large')
  const header = Buffer.alloc(HEADER_BYTES)
  header.writeUInt8(VERSION, 0)
  header.writeUInt8(id, 1)
  header.writeUInt8(0, 2)
  header.writeUInt32BE(buf.length, 3)
  return Buffer.concat([header, buf])
}

class MuxDecoder {
  constructor() {
    this._chunks = []
    this._length = 0
    this.closed = false
  }

  reset() {
    this._chunks = []
    this._length = 0
  }

  close() {
    this.closed = true
    this.reset()
  }

  _coalesce() {
    if (this._chunks.length === 0) return Buffer.alloc(0)
    if (this._chunks.length === 1) return this._chunks[0]
    const joined = Buffer.concat(this._chunks, this._length)
    this._chunks = [joined]
    return joined
  }

  add(chunk) {
    if (this.closed) throw new Error('mux decoder closed')
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
    if (this._length + buf.length > MAX_MUX_BUFFER_BYTES) {
      this.reset()
      throw new Error('mux buffer exceeded')
    }
    this._chunks.push(buf)
    this._length += buf.length
    const out = []
    let view = this._coalesce()
    while (view.length >= HEADER_BYTES) {
      const version = view.readUInt8(0)
      if (version !== VERSION) {
        this.reset()
        throw new Error('bad mux version')
      }
      const channel = CHANNELS[view.readUInt8(1)]
      if (!channel) {
        this.reset()
        throw new Error('bad mux channel')
      }
      const len = view.readUInt32BE(3)
      if (!Number.isInteger(len) || len < 0 || len > MAX_MUX_FRAME_BYTES) {
        this.reset()
        throw new Error('mux frame too large')
      }
      if (view.length < HEADER_BYTES + len) break
      out.push({ channel, payload: Buffer.from(view.subarray(HEADER_BYTES, HEADER_BYTES + len)) })
      view = view.subarray(HEADER_BYTES + len)
    }
    this._chunks = view.length ? [Buffer.from(view)] : []
    this._length = view.length
    return out
  }
}

module.exports = {
  CHANNELS,
  VERSION,
  MAX_MUX_FRAME_BYTES,
  MAX_MUX_BUFFER_BYTES,
  HEADER_BYTES,
  encodeMux,
  MuxDecoder,
}

'use strict'

/**
 * 7-byte mux header: version(1) channel(1) flags(1) length(4 BE) + payload.
 *
 * MAX_MUX_FRAME_BYTES is 1 MiB. That is well above a 64 KiB attachment
 * chunk after base64 (~87 KiB) plus JSON wrapping. Header slack lives in
 * MAX_MUX_PENDING_BYTES so a complete header+payload can sit in the
 * decoder without allowing an unbounded pending buffer.
 */
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
const HEADER_BYTES = 7
const MAX_MUX_FRAME_BYTES = 1024 * 1024
const MAX_MUX_PENDING_BYTES = MAX_MUX_FRAME_BYTES + HEADER_BYTES + 64 * 1024

class FrameError extends Error {
  constructor(code, message) {
    super(message || code)
    this.name = 'FrameError'
    this.code = code
  }
}

function encodeMux(channel, payload) {
  const id = CHANNELS.indexOf(channel)
  if (id < 0) throw new FrameError('malformed-frame', 'bad channel')
  const buf = Buffer.isBuffer(payload) ? payload : Buffer.from(payload)
  if (buf.length > MAX_MUX_FRAME_BYTES) {
    throw new FrameError('oversized-frame', 'mux payload exceeds MAX_MUX_FRAME_BYTES')
  }
  const header = Buffer.alloc(HEADER_BYTES)
  header.writeUInt8(VERSION, 0)
  header.writeUInt8(id, 1)
  header.writeUInt8(0, 2)
  header.writeUInt32BE(buf.length, 3)
  return Buffer.concat([header, buf])
}

class MuxDecoder {
  constructor(opts) {
    this._buf = Buffer.alloc(0)
    this._max = (opts && opts.maxFrameBytes) || MAX_MUX_FRAME_BYTES
    this._maxPending = (opts && opts.maxPendingBytes) || MAX_MUX_PENDING_BYTES
  }

  add(chunk) {
    if (!chunk || !chunk.length) return []
    if (this._buf.length + chunk.length > this._maxPending) {
      throw new FrameError('oversized-frame', 'mux pending buffer exceeds cap')
    }
    this._buf = Buffer.concat([this._buf, chunk])
    const out = []
    while (this._buf.length >= HEADER_BYTES) {
      const version = this._buf.readUInt8(0)
      if (version !== VERSION) {
        throw new FrameError('malformed-frame', 'bad mux version')
      }
      const channel = CHANNELS[this._buf.readUInt8(1)]
      if (!channel) throw new FrameError('malformed-frame', 'bad mux channel')
      const len = this._buf.readUInt32BE(3)
      if (len > this._max) {
        throw new FrameError('oversized-frame', 'mux frame too large')
      }
      if (this._buf.length < HEADER_BYTES + len) break
      out.push({
        channel,
        payload: Buffer.from(this._buf.subarray(HEADER_BYTES, HEADER_BYTES + len)),
      })
      this._buf = this._buf.subarray(HEADER_BYTES + len)
    }
    return out
  }
}

module.exports = {
  CHANNELS,
  VERSION,
  HEADER_BYTES,
  MAX_MUX_FRAME_BYTES,
  MAX_MUX_PENDING_BYTES,
  FrameError,
  encodeMux,
  MuxDecoder,
}

'use strict'

/**
 * 10-byte IPC header: magic(4) version(1) type(1) length(4 BE) + JSON body.
 *
 * MAX_IPC_FRAME_BYTES is 4 MiB. Large file bytes must never travel on
 * this channel (path/descriptor only). The pending-buffer cap is the
 * frame max plus header slack so a slow writer cannot grow RAM without bound.
 */
const MAGIC = 0x4f545031
const VERSION = 1
const REQUEST = 1
const RESPONSE = 2
const EVENT = 3
const HEADER_BYTES = 10
const MAX_IPC_FRAME_BYTES = 4 * 1024 * 1024
const MAX_IPC_PENDING_BYTES = MAX_IPC_FRAME_BYTES + HEADER_BYTES + 64 * 1024

class IpcFrameError extends Error {
  constructor(code, message) {
    super(message || code)
    this.name = 'IpcFrameError'
    this.code = code
  }
}

function encode(type, body) {
  const payload = Buffer.from(JSON.stringify(body), 'utf8')
  if (payload.length > MAX_IPC_FRAME_BYTES) {
    throw new IpcFrameError('oversized-frame', 'IPC payload exceeds MAX_IPC_FRAME_BYTES')
  }
  const header = Buffer.alloc(HEADER_BYTES)
  header.writeUInt32BE(MAGIC, 0)
  header.writeUInt8(VERSION, 4)
  header.writeUInt8(type, 5)
  header.writeUInt32BE(payload.length, 6)
  return Buffer.concat([header, payload])
}

class Decoder {
  constructor(opts) {
    this._buf = Buffer.alloc(0)
    this._max = (opts && opts.maxFrameBytes) || MAX_IPC_FRAME_BYTES
    this._maxPending = (opts && opts.maxPendingBytes) || MAX_IPC_PENDING_BYTES
  }

  add(chunk) {
    if (!chunk || !chunk.length) return []
    if (this._buf.length + chunk.length > this._maxPending) {
      throw new IpcFrameError('oversized-frame', 'IPC pending buffer exceeds cap')
    }
    this._buf = Buffer.concat([this._buf, chunk])
    const out = []
    while (this._buf.length >= HEADER_BYTES) {
      const magic = this._buf.readUInt32BE(0)
      if (magic !== MAGIC) throw new IpcFrameError('malformed-frame', 'bad IPC magic')
      const version = this._buf.readUInt8(4)
      if (version !== VERSION) {
        throw new IpcFrameError('malformed-frame', 'unsupported IPC version')
      }
      const type = this._buf.readUInt8(5)
      if (type !== REQUEST && type !== RESPONSE && type !== EVENT) {
        throw new IpcFrameError('malformed-frame', 'bad IPC type')
      }
      const len = this._buf.readUInt32BE(6)
      if (len > this._max) {
        throw new IpcFrameError('oversized-frame', 'IPC frame too large')
      }
      if (this._buf.length < HEADER_BYTES + len) break
      const payload = this._buf.subarray(HEADER_BYTES, HEADER_BYTES + len)
      let body
      try {
        body = JSON.parse(payload.toString('utf8'))
      } catch {
        throw new IpcFrameError('malformed-frame', 'bad IPC json')
      }
      out.push({ type, body })
      this._buf = this._buf.subarray(HEADER_BYTES + len)
    }
    return out
  }
}

module.exports = {
  MAGIC,
  VERSION,
  REQUEST,
  RESPONSE,
  EVENT,
  HEADER_BYTES,
  MAX_IPC_FRAME_BYTES,
  MAX_IPC_PENDING_BYTES,
  IpcFrameError,
  encode,
  Decoder,
}

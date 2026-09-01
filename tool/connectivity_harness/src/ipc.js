'use strict'

const MAGIC = 0x4f545031
const VERSION = 1
const REQUEST = 1
const RESPONSE = 2
const EVENT = 3

function encode(type, body) {
  const payload = Buffer.from(JSON.stringify(body), 'utf8')
  const header = Buffer.alloc(10)
  header.writeUInt32BE(MAGIC, 0)
  header.writeUInt8(VERSION, 4)
  header.writeUInt8(type, 5)
  header.writeUInt32BE(payload.length, 6)
  return Buffer.concat([header, payload])
}

class Decoder {
  constructor() {
    this._buf = Buffer.alloc(0)
  }

  add(chunk) {
    this._buf = Buffer.concat([this._buf, chunk])
    const out = []
    while (this._buf.length >= 10) {
      const magic = this._buf.readUInt32BE(0)
      if (magic !== MAGIC) throw new Error('bad IPC magic')
      const version = this._buf.readUInt8(4)
      if (version !== VERSION) throw new Error('unsupported IPC version')
      const type = this._buf.readUInt8(5)
      const len = this._buf.readUInt32BE(6)
      if (this._buf.length < 10 + len) break
      const payload = this._buf.subarray(10, 10 + len)
      out.push({ type, body: JSON.parse(payload.toString('utf8')) })
      this._buf = this._buf.subarray(10 + len)
    }
    return out
  }
}

module.exports = { MAGIC, VERSION, REQUEST, RESPONSE, EVENT, encode, Decoder }

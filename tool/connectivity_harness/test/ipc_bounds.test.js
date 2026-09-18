'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { MAGIC, VERSION, MAX_PAYLOAD, encode, Decoder } = require('../src/ipc')

test('payload exactly at the cap decodes', () => {
  const body = { pad: 'x'.repeat(1024) }
  const frame = encode(1, body)
  const out = new Decoder().add(frame)
  assert.equal(out.length, 1)
  assert.equal(out[0].body.pad.length, 1024)
})

test('declared payload over the cap is rejected', () => {
  const header = Buffer.alloc(10)
  header.writeUInt32BE(MAGIC, 0)
  header.writeUInt8(VERSION, 4)
  header.writeUInt8(1, 5)
  header.writeUInt32BE(MAX_PAYLOAD + 1, 6)
  assert.throws(() => new Decoder().add(header), /exceeds cap/)
})

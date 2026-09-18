'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { encodeMux, MuxDecoder, MAX_MUX_FRAME_BYTES } = require('../src/mux')

function header(len, channel = 1) {
  const h = Buffer.alloc(7)
  h.writeUInt8(1, 0)
  h.writeUInt8(channel, 1)
  h.writeUInt8(0, 2)
  h.writeUInt32BE(len >>> 0, 3)
  return h
}

test('frame exactly at the limit decodes', () => {
  const payload = Buffer.alloc(MAX_MUX_FRAME_BYTES, 7)
  const dec = new MuxDecoder()
  const frames = dec.add(encodeMux('message', payload))
  assert.equal(frames.length, 1)
  assert.equal(frames[0].payload.length, MAX_MUX_FRAME_BYTES)
})

test('frame one byte over the limit is rejected', () => {
  const dec = new MuxDecoder()
  assert.throws(() => dec.add(Buffer.concat([header(MAX_MUX_FRAME_BYTES + 1), Buffer.alloc(8)])), /too large/)
})

test('0xffffffff length is rejected without allocating the body', () => {
  const dec = new MuxDecoder()
  const before = process.memoryUsage().heapUsed
  assert.throws(() => dec.add(header(0xffffffff)), /too large/)
  const after = process.memoryUsage().heapUsed
  assert.ok(after - before < 8 * 1024 * 1024)
})

test('header can arrive in parts', () => {
  const payload = Buffer.from('{"ok":true}')
  const frame = encodeMux('control', payload)
  const dec = new MuxDecoder()
  assert.deepEqual(dec.add(frame.subarray(0, 3)), [])
  assert.deepEqual(dec.add(frame.subarray(3, 7)), [])
  const out = dec.add(frame.subarray(7))
  assert.equal(out.length, 1)
  assert.equal(out[0].channel, 'control')
  assert.equal(out[0].payload.toString(), payload.toString())
})

test('slow advertised huge frame is cut off at the header', () => {
  const dec = new MuxDecoder()
  assert.throws(() => dec.add(header(16 * 1024 * 1024)), /too large/)
  assert.equal(dec._length, 0)
})

test('many small fragments still decode one frame', () => {
  const frame = encodeMux('message', Buffer.from('hello-fragments'))
  const dec = new MuxDecoder()
  let out = []
  for (const byte of frame) {
    out = out.concat(dec.add(Buffer.from([byte])))
  }
  assert.equal(out.length, 1)
  assert.equal(out[0].payload.toString(), 'hello-fragments')
})

test('several valid frames in one chunk', () => {
  const dec = new MuxDecoder()
  const blob = Buffer.concat([
    encodeMux('message', Buffer.from('one')),
    encodeMux('receipt', Buffer.from('two')),
    encodeMux('presence', Buffer.from('three')),
  ])
  const out = dec.add(blob)
  assert.equal(out.length, 3)
  assert.deepEqual(out.map((f) => f.payload.toString()), ['one', 'two', 'three'])
})

test('decoder resets after close and rejects further input', () => {
  const dec = new MuxDecoder()
  dec.add(encodeMux('message', Buffer.from('x')))
  dec.close()
  assert.equal(dec._length, 0)
  assert.throws(() => dec.add(encodeMux('message', Buffer.from('y'))), /closed/)
})

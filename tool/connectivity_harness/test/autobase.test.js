'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const {
  AutobaseProjection,
  roomEventFromNativePacket,
} = require('../src/autobase')

test('two writers converge in any apply order', () => {
  const events = [
    {
      writerId: 'b',
      seq: 0,
      kind: 'membership',
      payload: { peerId: 'b', action: 'join', displayName: 'B' },
    },
    {
      writerId: 'a',
      seq: 0,
      kind: 'membership',
      payload: { peerId: 'a', action: 'join', displayName: 'A' },
    },
    {
      writerId: 'a',
      seq: 1,
      kind: 'channel',
      payload: { id: 'c1', name: 'general' },
    },
    {
      writerId: 'b',
      seq: 1,
      kind: 'message',
      payload: { id: 'm1', text: 'hi' },
    },
  ]
  const left = new AutobaseProjection()
  left.applyAll(events)
  const right = new AutobaseProjection()
  right.applyAll([...events].reverse())
  assert.deepEqual(left.state.members, right.state.members)
  assert.deepEqual(left.state.channels, right.state.channels)
  assert.deepEqual(left.state.messages, right.state.messages)
})

test('room_file_chunk projects metadata and strips b64', () => {
  const event = roomEventFromNativePacket(
    {
      type: 'room_file_chunk',
      id: 'f1',
      roomId: 'r1',
      channelId: 'c1',
      offset: 0,
      total: 4,
      last: true,
      b64: 'AQIDBA==',
      fileKey: 'nope',
      attachment: { name: 'note.bin', size: 4, mime: 'application/octet-stream' },
      abWriter: 'a',
      abSeq: 2,
    },
    'fallback',
  )
  assert.equal(event.kind, 'attachment')
  assert.equal(event.payload.id, 'f1')
  assert.equal(event.payload.name, 'note.bin')
  assert.equal(event.payload.b64, undefined)
  assert.equal(event.payload.fileKey, undefined)
  const later = roomEventFromNativePacket(
    {
      type: 'room_file_chunk',
      id: 'f1',
      offset: 64,
      b64: 'xxxx',
      abWriter: 'a',
      abSeq: 3,
    },
    'a',
  )
  assert.equal(later, null)
  const proj = new AutobaseProjection()
  proj.apply(event)
  const snap = proj.snapshot()
  assert.equal(snap.attachments.f1.name, 'note.bin')
  assert.equal(snap.attachments.f1.b64, undefined)
  const dumped = JSON.stringify(snap)
  assert.equal(dumped.includes('AQIDBA=='), false)
  assert.equal(dumped.includes('fileKey'), false)
})

test('membership events do not copy message plaintext into the snapshot keys', () => {
  const proj = new AutobaseProjection()
  proj.applyFromPacket(
    {
      type: 'room_join',
      roomId: 'r1',
      guestPeerId: 'p1',
      guestName: 'Pat',
      abWriter: 'a',
      abSeq: 0,
    },
    'x',
  )
  const snap = proj.snapshot()
  assert.equal(snap.members.p1, 'Pat')
  assert.equal(Object.prototype.hasOwnProperty.call(snap, 'plaintext'), false)
})

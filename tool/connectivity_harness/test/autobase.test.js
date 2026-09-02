'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {
  AutobaseProjection,
  roomEventFromNativePacket,
  hydrateFromJournal,
  membershipEventFromJournalRow,
} = require('../src/autobase')
const { Worklet, handleIpcRequest } = require('../src/worklet')

function membershipRow(fields, extra = {}) {
  return {
    seq: extra.seq == null ? 1 : extra.seq,
    writerDeviceId: extra.writerDeviceId || 'dev-a',
    kind: extra.kind || 'roomMembershipChanged',
    fields,
  }
}

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

test('hydrateFromJournal applies only roomMembershipChanged metadata', () => {
  const rows = [
    membershipRow({
      roomId: 'room-hydrate',
      peerId: 'ORBIT-BB',
      action: 'join',
      displayName: 'B',
      writerId: 'a',
      seq: 0,
    }),
    membershipRow(
      {
        roomId: 'room-hydrate',
        peerId: 'ORBIT-CC',
        action: 'join',
        displayName: 'C',
        writerId: 'a',
        seq: 1,
      },
      { seq: 2 },
    ),
    {
      seq: 3,
      writerDeviceId: 'dev-a',
      kind: 'messageEnvelopeCreated',
      fields: {
        encryptedEnvelope: 'v2:cipher-body',
        eventId: 'hydrate-env',
      },
    },
    {
      writerId: 'a',
      seq: 2,
      kind: 'message',
      payload: { id: 'm1', text: 'hello-plaintext' },
    },
    {
      kind: 'membership',
      fields: { peerId: 'sneaky', action: 'join', displayName: 'Nope' },
    },
  ]
  const event = membershipEventFromJournalRow(rows[0])
  assert.equal(event.kind, 'membership')
  assert.deepEqual(Object.keys(event.payload).sort(), [
    'action',
    'displayName',
    'peerId',
    'roomId',
  ])
  const first = new AutobaseProjection()
  assert.equal(hydrateFromJournal(first, rows), 2)
  const snap = first.snapshot()
  assert.equal(snap.members['ORBIT-BB'], 'B')
  assert.equal(snap.members['ORBIT-CC'], 'C')
  assert.equal(snap.members.sneaky, undefined)
  assert.deepEqual(snap.messages, [])
  const dumped = JSON.stringify(snap)
  assert.equal(dumped.includes('hello-plaintext'), false)
  assert.equal(dumped.includes('v2:cipher-body'), false)
  assert.equal(dumped.includes('fileKey'), false)

  const restarted = new AutobaseProjection()
  restarted.hydrateFromJournal(rows)
  assert.deepEqual(restarted.snapshot().members, snap.members)
  assert.deepEqual(restarted.snapshot().messages, [])
})

test('hydrateFromJournal skips rows with forbidden field names', () => {
  const banned = [
    'text',
    'b64',
    'fileKey',
    'fileKeyB64',
    'plaintext',
    'password',
    'kek',
    'rootKey',
    'discoverySecret',
  ]
  const proj = new AutobaseProjection()
  const rows = banned.map((key, i) =>
    membershipRow(
      {
        peerId: 'p-' + key,
        action: 'join',
        displayName: 'Bad',
        roomId: 'r1',
        [key]: key === 'b64' ? 'AQID' : 'secret-' + key,
      },
      { seq: i + 1, writerDeviceId: 'w' + i },
    ),
  )
  rows.push(
    membershipRow(
      {
        peerId: 'ok',
        action: 'join',
        displayName: 'Ok',
        roomId: 'r1',
      },
      { seq: 100, writerDeviceId: 'ok-dev' },
    ),
  )
  assert.equal(proj.hydrateFromJournal(rows), 1)
  const snap = proj.snapshot()
  assert.equal(snap.members.ok, 'Ok')
  for (const key of banned) {
    assert.equal(snap.members['p-' + key], undefined)
  }
  const dumped = JSON.stringify(snap)
  assert.equal(dumped.includes('secret-'), false)
  assert.equal(dumped.includes('AQID'), false)
  assert.equal(dumped.includes('fileKey'), false)
  assert.equal(dumped.includes('plaintext'), false)
})

test('worklet Autobase rebuilds members from journal after restart', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-ab-hydrate-'))
  try {
    const first = new Worklet()
    await first.start({ peerId: 'ORBIT-AA', journalDir: dir })
    await handleIpcRequest(first, {
      method: 'journal.append',
      params: {
        kind: 'roomMembershipChanged',
        writerDeviceId: 'dev-a',
        fields: {
          roomId: 'room-1',
          peerId: 'ORBIT-BB',
          action: 'join',
          displayName: 'B',
          writerId: 'a',
          seq: 0,
        },
      },
    })
    await handleIpcRequest(first, {
      method: 'journal.append',
      params: {
        kind: 'messageEnvelopeCreated',
        fields: { encryptedEnvelope: 'v2:not-a-member-body', eventId: 'e1' },
      },
    })
    const live = await handleIpcRequest(first, {
      method: 'autobase.state',
      params: {},
    })
    assert.equal(live.members['ORBIT-BB'], 'B')
    assert.deepEqual(live.messages, [])
    assert.equal(JSON.stringify(live).includes('v2:not-a-member-body'), false)
    await first.stop()

    const second = new Worklet()
    await second.start({ peerId: 'ORBIT-AA', journalDir: dir })
    const hydrated = await handleIpcRequest(second, {
      method: 'autobase.hydrate',
      params: {},
    })
    assert.equal(hydrated.members['ORBIT-BB'], 'B')
    assert.ok(hydrated.hydrated >= 1)
    assert.ok(Array.isArray(hydrated.applied))
    assert.deepEqual(hydrated.messages, [])
    const dumped = JSON.stringify(hydrated)
    assert.equal(dumped.includes('v2:not-a-member-body'), false)
    assert.equal(dumped.includes('fileKey'), false)
    assert.equal(dumped.includes('plaintext'), false)
    const listed = await handleIpcRequest(second, {
      method: 'journal.list',
      params: {},
    })
    assert.equal(listed.blocks.length, 2)
    await second.stop()
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('autobase.hydrate IPC applies supplied rows and ignores bodies', async () => {
  const worklet = new Worklet()
  await worklet.start({ peerId: 'ORBIT-AA' })
  try {
    const result = await handleIpcRequest(worklet, {
      method: 'autobase.hydrate',
      params: {
        rows: [
          membershipRow({
            peerId: 'p1',
            action: 'join',
            displayName: 'Pat',
            roomId: 'r1',
          }),
          {
            kind: 'messageEnvelopeCreated',
            fields: { encryptedEnvelope: 'v2:abc', text: 'nope' },
          },
          membershipRow({
            peerId: 'p2',
            action: 'join',
            displayName: 'Bad',
            text: 'hi',
          }),
        ],
      },
    })
    assert.equal(result.members.p1, 'Pat')
    assert.equal(result.members.p2, undefined)
    assert.deepEqual(result.messages, [])
    const dumped = JSON.stringify(result)
    assert.equal(dumped.includes('nope'), false)
    assert.equal(dumped.includes('"hi"'), false)
  } finally {
    await worklet.stop()
  }
})

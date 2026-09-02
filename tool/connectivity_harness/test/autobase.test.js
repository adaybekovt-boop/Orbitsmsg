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
  objectHasLiveForbiddenKeys,
  STRIP,
  JOURNAL_FORBIDDEN,
} = require('../src/autobase')

/** Mirrors lib/transport/layers.dart kForbiddenReplicationFields. */
const DART_FORBIDDEN = [
  'plaintext',
  'password',
  'kek',
  'vaultKek',
  'rootKey',
  'sendCk',
  'recvCk',
  'dhPriv',
  'skipped',
  'discoverySecret',
  'sharedDiscoverySecret',
  'attachmentBytes',
  'fileKey',
  'fileKeyB64',
  'privBytes',
]
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

test('STRIP and JOURNAL_FORBIDDEN project kForbiddenReplicationFields', () => {
  const expectedStrip = new Set([...DART_FORBIDDEN, 'b64', 'dataB64', 'bytes'])
  const expectedJournal = new Set([...DART_FORBIDDEN, 'text', 'b64'])
  assert.equal(STRIP.has('text'), false)
  assert.equal(STRIP.size, expectedStrip.size)
  for (const key of expectedStrip) {
    assert.equal(STRIP.has(key), true, 'STRIP missing ' + key)
  }
  assert.equal(JOURNAL_FORBIDDEN.size, expectedJournal.size)
  for (const key of expectedJournal) {
    assert.equal(JOURNAL_FORBIDDEN.has(key), true, 'JOURNAL_FORBIDDEN missing ' + key)
  }
})

test('hydrateFromJournal skips rows with forbidden field names', () => {
  const banned = ['text', 'b64', ...DART_FORBIDDEN]
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

test('hydrateFromJournal skips sendCk, vaultKek, sharedDiscoverySecret, privBytes', () => {
  const banned = ['sendCk', 'vaultKek', 'sharedDiscoverySecret', 'privBytes']
  const proj = new AutobaseProjection()
  const rows = banned.map((key, i) =>
    membershipRow(
      {
        peerId: 'p-' + key,
        action: 'join',
        displayName: 'Bad',
        roomId: 'r1',
        [key]: 'leaked-' + key,
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
  assert.equal(dumped.includes('leaked-'), false)
  assert.equal(dumped.includes('sendCk'), false)
  assert.equal(dumped.includes('vaultKek'), false)
  assert.equal(dumped.includes('sharedDiscoverySecret'), false)
  assert.equal(dumped.includes('privBytes'), false)
})

test('JOURNAL_FORBIDDEN rejects a membership journal row with text or fileKey', () => {
  assert.equal(
    membershipEventFromJournalRow(
      membershipRow({
        peerId: 'p-text',
        action: 'join',
        displayName: 'Bad',
        roomId: 'r1',
        text: 'hello-plaintext',
      }),
    ),
    null,
  )
  assert.equal(
    membershipEventFromJournalRow(
      membershipRow({
        peerId: 'p-file',
        action: 'join',
        displayName: 'Bad',
        roomId: 'r1',
        fileKey: 'smuggle-file',
      }),
    ),
    null,
  )
  const ok = membershipEventFromJournalRow(
    membershipRow({
      peerId: 'p-ok',
      action: 'join',
      displayName: 'Ok',
      roomId: 'r1',
    }),
  )
  assert.equal(ok.kind, 'membership')
  assert.equal(ok.payload.peerId, 'p-ok')
  assert.equal(ok.payload.text, undefined)
  assert.equal(ok.payload.fileKey, undefined)
})

test('apply strips sendCk, vaultKek, sharedDiscoverySecret, privBytes and keeps text', () => {
  const proj = new AutobaseProjection()
  proj.apply({
    writerId: 'a',
    seq: 1,
    kind: 'message',
    payload: {
      id: 'm-hello',
      text: 'hello',
      fileKey: 'smuggle-file',
      sendCk: 'smuggle-send',
      vaultKek: 'smuggle-vault',
      sharedDiscoverySecret: 'smuggle-shared',
      privBytes: 'smuggle-priv',
    },
  })
  const stored = proj.state.messages[0]
  assert.equal(stored.text, 'hello')
  assert.equal(stored.id, 'm-hello')
  assert.equal(stored.fileKey, undefined)
  assert.equal(stored.sendCk, undefined)
  assert.equal(stored.vaultKek, undefined)
  assert.equal(stored.sharedDiscoverySecret, undefined)
  assert.equal(stored.privBytes, undefined)
  const dumped = JSON.stringify(proj.snapshot())
  assert.equal(dumped.includes('smuggle-'), false)
})

test('apply and fromWire sanitize nested array chunks: keep text/name, drop fileKey/b64', () => {
  const payload = {
    chunks: [{ fileKey: 'x', b64: 'AQID', name: 'n' }],
    text: 'hello',
  }
  const event = roomEventFromNativePacket(
    {
      type: 'autobase-event',
      writerId: 'a',
      seq: 5,
      kind: 'message',
      payload,
    },
    'fallback',
  )
  assert.equal(event.kind, 'message')
  assert.equal(event.payload.text, 'hello')
  assert.equal(event.payload.chunks.length, 1)
  assert.equal(event.payload.chunks[0].name, 'n')
  assert.equal(event.payload.chunks[0].fileKey, undefined)
  assert.equal(event.payload.chunks[0].b64, undefined)
  assert.equal(STRIP.has('text'), false)

  const proj = new AutobaseProjection()
  proj.apply({
    writerId: 'b',
    seq: 1,
    kind: 'message',
    payload,
  })
  const stored = proj.state.messages[0]
  assert.equal(stored.text, 'hello')
  assert.equal(stored.chunks[0].name, 'n')
  assert.equal(stored.chunks[0].fileKey, undefined)
  assert.equal(stored.chunks[0].b64, undefined)
  const dumped = JSON.stringify(proj.snapshot())
  assert.equal(dumped.includes('fileKey'), false)
  assert.equal(dumped.includes('AQID'), false)
})

test('sanitize is cycle-safe when arrays and objects repeat a seen value', () => {
  const payload = { text: 'hello', name: 'n' }
  payload.self = payload
  payload.chunks = [payload, { fileKey: 'x', b64: 'AQID', name: 'inner' }]
  const proj = new AutobaseProjection()
  proj.apply({
    writerId: 'a',
    seq: 1,
    kind: 'message',
    payload,
  })
  const stored = proj.state.messages[0]
  assert.equal(stored.text, 'hello')
  assert.equal(stored.name, 'n')
  assert.equal(stored.self.fileKey, undefined)
  assert.equal(stored.chunks[1].name, 'inner')
  assert.equal(stored.chunks[1].fileKey, undefined)
  assert.equal(stored.chunks[1].b64, undefined)
  const dumped = JSON.stringify(proj.snapshot())
  assert.equal(dumped.includes('fileKey'), false)
  assert.equal(dumped.includes('AQID'), false)
})

test('message event with text and fileKey keeps text and drops fileKey', () => {
  const event = roomEventFromNativePacket(
    {
      type: 'autobase-event',
      writerId: 'a',
      seq: 4,
      kind: 'message',
      payload: { id: 'm1', text: 'hello', fileKey: 'smuggle-file' },
    },
    'fallback',
  )
  assert.equal(event.kind, 'message')
  assert.equal(event.payload.text, 'hello')
  assert.equal(event.payload.id, 'm1')
  assert.equal(event.payload.fileKey, undefined)
  const proj = new AutobaseProjection()
  proj.apply(event)
  const stored = proj.state.messages[0]
  assert.equal(stored.text, 'hello')
  assert.equal(stored.fileKey, undefined)
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

test('applyFromPacket refuses room_join with top-level fileKey', () => {
  const proj = new AutobaseProjection()
  const event = proj.applyFromPacket(
    {
      type: 'room_join',
      peerId: 'hostile',
      guestName: 'Eve',
      fileKey: 'smuggle-file',
      abWriter: 'a',
      abSeq: 0,
    },
    'fallback',
  )
  assert.equal(event, null)
  const snap = proj.snapshot()
  assert.deepEqual(snap.members, {})
  const dumped = JSON.stringify(snap)
  assert.equal(dumped.includes('fileKey'), false)
  assert.equal(dumped.includes('smuggle-file'), false)
})

test('applyFromPacket refuses room_msg with nested discoverySecret', () => {
  const proj = new AutobaseProjection()
  const event = proj.applyFromPacket(
    {
      type: 'room_msg',
      id: 'm-bad',
      text: 'host-plaintext',
      meta: { discoverySecret: 'leaked-topic' },
      abWriter: 'a',
      abSeq: 1,
    },
    'fallback',
  )
  assert.equal(event, null)
  assert.deepEqual(proj.snapshot().messages, [])
})

test('applyFromPacket still joins a legit room_join', () => {
  const proj = new AutobaseProjection()
  const event = proj.applyFromPacket(
    {
      type: 'room_join',
      peerId: 'ORBIT-BB',
      guestName: 'Bee',
      abWriter: 'a',
      abSeq: 0,
    },
    'fallback',
  )
  assert.equal(event.kind, 'membership')
  assert.equal(event.payload.peerId, 'ORBIT-BB')
  assert.equal(proj.snapshot().members['ORBIT-BB'], 'Bee')
})

test('applyFromPacket still records host-plaintext room_msg text', () => {
  assert.equal(STRIP.has('text'), false)
  assert.equal(
    objectHasLiveForbiddenKeys({
      type: 'room_msg',
      id: 'm1',
      text: 'host-plaintext',
      peerId: 'ORBIT-AA',
      b64: 'AQID',
      dataB64: 'xx',
      bytes: [1],
    }),
    false,
  )
  const proj = new AutobaseProjection()
  const event = proj.applyFromPacket(
    {
      type: 'room_msg',
      id: 'm1',
      text: 'host-plaintext',
      abWriter: 'a',
      abSeq: 1,
    },
    'fallback',
  )
  assert.equal(event.kind, 'message')
  assert.equal(event.payload.text, 'host-plaintext')
  assert.equal(proj.snapshot().messages[0].text, 'host-plaintext')
})

test('worklet control path refuses hostile fileKey membership', async () => {
  const worklet = new Worklet()
  await worklet.start({ peerId: 'ORBIT-AA' })
  try {
    worklet._applyControlAutobase(
      Buffer.from(
        JSON.stringify({
          type: 'room_join',
          peerId: 'hostile',
          guestName: 'Eve',
          fileKey: 'smuggle-file',
          abWriter: 'a',
          abSeq: 0,
        }),
      ),
      'ORBIT-AA',
    )
    worklet._onFrame(
      'peer-x',
      'control',
      Buffer.from(
        JSON.stringify({
          type: 'room_join',
          peerId: 'hostile2',
          guestName: 'Eve2',
          fileKey: 'smuggle2',
          abWriter: 'b',
          abSeq: 1,
        }),
      ),
    )
    const snap = worklet._autobase.snapshot()
    assert.deepEqual(snap.members, {})
    const dumped = JSON.stringify(snap)
    assert.equal(dumped.includes('fileKey'), false)
    assert.equal(dumped.includes('smuggle'), false)
  } finally {
    await worklet.stop()
  }
})

test('fromWire and apply refuse URL-shaped writerId and do not mark applied', () => {
  assert.equal(
    roomEventFromNativePacket(
      {
        type: 'autobase-event',
        writerId: 'https://evil',
        seq: 0,
        kind: 'membership',
        payload: { peerId: 'eve', action: 'join' },
      },
      'a',
    ),
    null,
  )
  assert.equal(
    roomEventFromNativePacket(
      {
        type: 'room_join',
        roomId: 'r1',
        guestPeerId: 'p1',
        guestName: 'Pat',
        abWriter: 'https://evil',
        abSeq: 0,
      },
      'a',
    ),
    null,
  )
  assert.equal(
    roomEventFromNativePacket(
      {
        type: 'room_join',
        roomId: 'r1',
        guestPeerId: 'p1',
        guestName: 'Pat',
        abSeq: 0,
      },
      'https://evil',
    ),
    null,
  )
  assert.equal(
    membershipEventFromJournalRow(
      membershipRow(
        { peerId: 'eve', action: 'join' },
        { writerDeviceId: 'https://evil' },
      ),
    ),
    null,
  )
  const proj = new AutobaseProjection()
  proj.apply({
    writerId: 'https://evil',
    seq: 0,
    kind: 'membership',
    payload: { peerId: 'eve', action: 'join', displayName: 'Eve' },
  })
  assert.deepEqual(proj.state.members, {})
  assert.equal(proj.state.applied.size, 0)
  const join = roomEventFromNativePacket(
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
  assert.equal(join.writerId, 'a')
  proj.apply(join)
  assert.equal(proj.state.members.p1, 'Pat')
})

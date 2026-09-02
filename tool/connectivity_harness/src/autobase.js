'use strict'

/**
 * Deterministic multiwriter room projection (Phase 12).
 * Mirrors lib/rooms/autobase_log.dart. Host-plaintext warning stays.
 * Message bodies and file bytes stay in this local view — never Corestore.
 * Not the Holepunch Autobase npm package (that is not in bare_stdlib.zip).
 */

// Projects lib/transport/layers.dart kForbiddenReplicationFields.
// Autobase-only extras: b64, dataB64, bytes (attachment ciphertext).
// Host-plaintext live `text` must survive — do not add `text` here.
const STRIP = new Set([
  'b64',
  'dataB64',
  'bytes',
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
])

/** Journal rows that rebuild membership after restart. Not live packet kinds. */
const JOURNAL_MEMBERSHIP_KINDS = new Set([
  'roomMembershipChanged',
  'RoomMembershipChanged',
])

/** Skip the whole journal row if any of these keys appear (fields or nested). */
// Same Dart forbidden names, plus text/b64 so journal hydrate
// never copies message bodies or attachment ciphertext.
const JOURNAL_FORBIDDEN = new Set([
  'text',
  'b64',
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
])

/** Live packets: Dart kForbiddenReplicationFields only. Not text/b64/peerId. */
const LIVE_FORBIDDEN = new Set([
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
])

const MEMBERSHIP_PAYLOAD_KEYS = ['peerId', 'action', 'displayName', 'roomId']

function sanitize(value, seen) {
  if (!value || typeof value !== 'object') return value
  const walk = seen || new Set()
  if (walk.has(value)) return Array.isArray(value) ? [] : {}
  walk.add(value)
  if (Array.isArray(value)) {
    return value.map((item) => sanitize(item, walk))
  }
  const out = {}
  for (const [k, v] of Object.entries(value)) {
    if (STRIP.has(k)) continue
    out[k] = sanitize(v, walk)
  }
  return out
}

function objectHasKeysFrom(value, forbidden, seen) {
  if (!value || typeof value !== 'object') return false
  const walk = seen || new Set()
  if (walk.has(value)) return false
  walk.add(value)
  if (Array.isArray(value)) {
    return value.some((item) => objectHasKeysFrom(item, forbidden, walk))
  }
  for (const [k, v] of Object.entries(value)) {
    if (forbidden.has(k)) return true
    if (objectHasKeysFrom(v, forbidden, walk)) return true
  }
  return false
}

function objectHasForbiddenKeys(value, seen) {
  return objectHasKeysFrom(value, JOURNAL_FORBIDDEN, seen)
}

/** Live control packets. Do not use JOURNAL_FORBIDDEN (that set includes text). */
function objectHasLiveForbiddenKeys(value, seen) {
  return objectHasKeysFrom(value, LIVE_FORBIDDEN, seen)
}

function isJournalMembershipKind(kind) {
  return typeof kind === 'string' && JOURNAL_MEMBERSHIP_KINDS.has(kind)
}

function journalFieldsOf(row) {
  if (!row || typeof row !== 'object') return null
  const fields = row.fields
  if (fields && typeof fields === 'object' && !Array.isArray(fields)) return fields
  return row
}

/**
 * Map a worklet journal row to a membership event.
 * Only `roomMembershipChanged` (journal.append kind). Payload is
 * peerId / action / displayName / roomId — never ciphertext or secrets.
 */
function membershipEventFromJournalRow(row) {
  if (!row || typeof row !== 'object' || Array.isArray(row)) return null
  if (!isJournalMembershipKind(row.kind)) return null
  const fields = journalFieldsOf(row)
  if (!fields) return null
  if (objectHasForbiddenKeys(fields) || objectHasForbiddenKeys(row)) return null
  const peerId = fields.peerId
  if (typeof peerId !== 'string' || !peerId) return null
  const payload = {}
  for (const key of MEMBERSHIP_PAYLOAD_KEYS) {
    if (!Object.prototype.hasOwnProperty.call(fields, key)) continue
    const value = fields[key]
    if (key === 'peerId' || key === 'action' || key === 'displayName') {
      if (typeof value !== 'string' || !value) continue
    } else if (value == null || value === '') {
      continue
    }
    payload[key] = value
  }
  if (!payload.peerId) return null
  if (!payload.action) payload.action = 'join'
  const writer =
    (typeof fields.writerId === 'string' && fields.writerId) ||
    (typeof row.writerDeviceId === 'string' && row.writerDeviceId) ||
    (typeof row.writerId === 'string' && row.writerId) ||
    'journal'
  const seq = Number(fields.seq != null ? fields.seq : row.seq) || 0
  return {
    writerId: writer,
    seq,
    kind: 'membership',
    payload,
  }
}

/**
 * Rebuild membership from worklet journal rows. Skips envelopes, message
 * bodies, and any row that carries forbidden field names.
 */
function hydrateFromJournal(projection, rows) {
  if (!projection || typeof projection.apply !== 'function') return 0
  if (!Array.isArray(rows)) return 0
  const events = []
  for (const row of rows) {
    const event = membershipEventFromJournalRow(row)
    if (event) events.push(event)
  }
  projection.applyAll(events)
  return events.length
}

function fromWire(packet) {
  if (!packet || packet.type !== 'autobase-event') return null
  const writer = packet.writerId
  const kind = packet.kind
  if (typeof writer !== 'string' || typeof kind !== 'string') return null
  const raw = packet.payload
  return {
    writerId: writer,
    seq: Number(packet.seq) || 0,
    kind,
    payload: raw && typeof raw === 'object' ? sanitize(raw) : {},
  }
}

function roomEventFromNativePacket(packet, fallbackWriter) {
  if (!packet || typeof packet !== 'object') return null
  if (packet.type === 'autobase-event') return fromWire(packet)
  const writer = packet.abWriter || fallbackWriter
  const seq = Number(packet.abSeq) || 0
  if (typeof writer !== 'string' || !writer) return null
  switch (packet.type) {
    case 'room_join': {
      const peer = packet.guestPeerId || packet.peerId
      if (!peer) return null
      return {
        writerId: writer,
        seq,
        kind: 'membership',
        payload: {
          ...(packet.roomId != null ? { roomId: packet.roomId } : {}),
          peerId: peer,
          action: 'join',
          displayName: packet.guestName || peer,
        },
      }
    }
    case 'room_leave':
    case 'room_destroy': {
      const peer = packet.guestPeerId || packet.peerId
      if (!peer) return null
      return {
        writerId: writer,
        seq,
        kind: 'membership',
        payload: {
          ...(packet.roomId != null ? { roomId: packet.roomId } : {}),
          peerId: peer,
          action: 'leave',
        },
      }
    }
    case 'room_channel_create': {
      const raw = packet.channel
      const channel = raw && typeof raw === 'object' ? raw : packet
      const id = channel.id
      const name = channel.name
      if (id == null || name == null) return null
      return {
        writerId: writer,
        seq,
        kind: 'channel',
        payload: { id, name },
      }
    }
    case 'room_msg':
      return {
        writerId: writer,
        seq,
        kind: 'message',
        payload: { id: packet.id, text: packet.text },
      }
    case 'room_file_chunk': {
      const offset = Number(packet.offset) || 0
      if (offset !== 0) return null
      if (packet.id == null) return null
      const att =
        packet.attachment && typeof packet.attachment === 'object'
          ? packet.attachment
          : {}
      return {
        writerId: writer,
        seq,
        kind: 'attachment',
        payload: sanitize({
          id: packet.id,
          name: att.name,
          size: att.size != null ? att.size : packet.total,
          mime: att.mime,
          ...(packet.roomId != null ? { roomId: packet.roomId } : {}),
          ...(packet.channelId != null ? { channelId: packet.channelId } : {}),
        }),
      }
    }
    default:
      return null
  }
}

class AutobaseProjection {
  constructor() {
    this.state = {
      members: {},
      roles: {},
      channels: {},
      messages: [],
      attachments: {},
      applied: new Set(),
    }
  }

  keyOf(event) {
    return event.writerId + ':' + event.seq
  }

  reset() {
    this.state.members = {}
    this.state.roles = {}
    this.state.channels = {}
    this.state.messages = []
    this.state.attachments = {}
    this.state.applied = new Set()
  }

  apply(event) {
    if (!event || typeof event !== 'object') return
    const key = this.keyOf(event)
    if (this.state.applied.has(key)) return
    this.state.applied.add(key)
    const payload = sanitize(event.payload || {})
    switch (event.kind) {
      case 'membership': {
        const peer = payload.peerId
        const action = payload.action || 'join'
        if (!peer) return
        if (action === 'leave' || action === 'kick') {
          delete this.state.members[peer]
          delete this.state.roles[peer]
        } else {
          this.state.members[peer] = payload.displayName || peer
        }
        break
      }
      case 'role': {
        const peer = payload.peerId
        const role = payload.role
        if (peer && role) this.state.roles[peer] = role
        break
      }
      case 'channel': {
        if (payload.id != null && payload.name != null) {
          this.state.channels[payload.id] = payload.name
        }
        break
      }
      case 'message':
        this.state.messages.push({ ...payload })
        break
      case 'attachment': {
        const id = payload.id
        if (id == null) return
        this.state.attachments[id] = { ...payload }
        break
      }
      case 'moderation': {
        const id = payload.messageId
        if (id != null) {
          this.state.messages = this.state.messages.filter((m) => m.id !== id)
        }
        break
      }
      default:
        break
    }
  }

  applyAll(events) {
    const sorted = [...events].sort((a, b) => {
      const bySeq = a.seq - b.seq
      if (bySeq !== 0) return bySeq
      return String(a.writerId).localeCompare(String(b.writerId))
    })
    for (const event of sorted) this.apply(event)
  }

  applyFromPacket(packet, fallbackWriter) {
    if (!packet || typeof packet !== 'object') return null
    if (objectHasLiveForbiddenKeys(packet)) return null
    const event = roomEventFromNativePacket(packet, fallbackWriter)
    if (event) this.apply(event)
    return event
  }

  // Journal restart path. Membership metadata only — never message bodies.
  hydrateFromJournal(rows) {
    return hydrateFromJournal(this, rows)
  }

  snapshot() {
    return {
      members: { ...this.state.members },
      roles: { ...this.state.roles },
      channels: { ...this.state.channels },
      messages: this.state.messages.map((m) => ({ ...m })),
      attachments: Object.fromEntries(
        Object.entries(this.state.attachments).map(([k, v]) => [k, { ...v }]),
      ),
      applied: [...this.state.applied],
    }
  }
}

module.exports = {
  AutobaseProjection,
  roomEventFromNativePacket,
  fromWire,
  hydrateFromJournal,
  membershipEventFromJournalRow,
  isJournalMembershipKind,
  objectHasLiveForbiddenKeys,
  STRIP,
  JOURNAL_FORBIDDEN,
  LIVE_FORBIDDEN,
  JOURNAL_MEMBERSHIP_KINDS,
}

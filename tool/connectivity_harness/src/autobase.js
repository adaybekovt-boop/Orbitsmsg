'use strict'

/**
 * Deterministic multiwriter room projection (Phase 12).
 * Mirrors lib/rooms/autobase_log.dart. Host-plaintext warning stays.
 * Message bodies and file bytes stay in this local view — never Corestore.
 * Not the Holepunch Autobase npm package (that is not in bare_stdlib.zip).
 */

const STRIP = new Set([
  'b64',
  'dataB64',
  'fileKey',
  'fileKeyB64',
  'plaintext',
  'password',
  'kek',
  'rootKey',
  'bytes',
])

function sanitize(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return value
  const out = {}
  for (const [k, v] of Object.entries(value)) {
    if (STRIP.has(k)) continue
    out[k] = sanitize(v)
  }
  return out
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
    const event = roomEventFromNativePacket(packet, fallbackWriter)
    if (event) this.apply(event)
    return event
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
}

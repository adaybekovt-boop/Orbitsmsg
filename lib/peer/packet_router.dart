// Port of `src/peer/packetRouter.js`.
//
// Middleware chain for inbound packets on a PeerJS DataConnection. Each
// middleware returns `true` when it consumed the packet; the chain stops
// at the first handler that returns `true`. The chain replaces the
// nested `if`/`switch` inside useConnections.attachConn.onData on the
// React side.
//
// Two channels, two chains:
//
//   ephemeral (unreliable UDP-like): [ephemeralMiddleware] — decrypts
//     wire ciphertext if needed, splits off drop-beacon packets, hands
//     the rest to [dispatchEphemeralInbound] (typing + heartbeat).
//
//   reliable (ordered TCP-like): [dropMiddleware] → [reliableMiddleware]
//     — drop/file-transfer traffic fast-paths to DropManager; everything
//     else (wire handshake, chat msg, profile exchange, bundle push/pull,
//     ack / edit / delete) goes through [dispatchReliableInbound].
//
// Notes relative to the JS version:
// - The giant inline callback bag in JS useConnections collapses into two
//   small Dart classes ([ReliableInboundCtx] + [EphemeralInboundCtx]) that
//   the caller builds once per peer at attach time. [PacketRouterCtx]
//   just composes them. Same wiring, less per-packet closure pressure.
// - `flushOutboxForPeer(remoteId)` in JS is a function of [remoteId];
//   here the caller bakes [remoteId] into [PacketRouterCtx.flushOutbox]
//   once at attach time because the Dart handler is also created per-peer.
// - DropManager is not ported yet — [PacketRouterCtx.dropHandlePacket] is
//   nullable so a dropless build still compiles and silently swallows
//   drop-beacon traffic (same effect as an unregistered JS handler).

import 'dart:async';
import 'dart:typed_data';

import '../core/wire_crypto.dart';
import '../messaging/message_protocol.dart';

/// Packet types that belong to the file-transfer (drop) subsystem. Match
/// the JS set 1:1 — adding or removing entries here will desync the two
/// builds. Source of truth: `src/peer/packetRouter.js::DROP_TYPES`.
const Set<String> dropTypes = <String>{
  'drop-beacon',
  'drop-beacon-ack',
  'drop-req',
  'drop-ack',
  'drop-rej',
  'drop-cancel',
  'file-start',
  'file-chunk',
  'file-end',
  'file-abort',
  'drop-resume',
};

/// File-transfer control types handled by the Drop engine (the actual chunk
/// payloads arrive as binary messages, not Maps). Routed to [dropInbound].
const Set<String> _fileTransferTypes = <String>{
  'file-start',
  'file-end',
  'file-abort',
};

/// True iff [data] is a JSON-shaped map whose `type` is one of [dropTypes].
/// Used by both the standalone [dropMiddleware] (reliable chain) and the
/// inline drop fast-path inside [ephemeralMiddleware].
bool isDropPacket(Object? data) {
  if (data is! Map) return false;
  final t = data['type'];
  return t is String && dropTypes.contains(t);
}

/// True iff [data] is a JSON map whose `type` is a room-protocol packet
/// (`room_join`, `room_msg`, `room_members_update`, `room_channel_create`,
/// `room_destroy`, `room_leave`). Routed to [PacketRouterCtx.roomInbound]
/// ahead of the generic reliable dispatcher. Room packets ride the reliable
/// channel as PLAINTEXT maps (DTLS-protected like Drop chunks) — they
/// intentionally bypass the per-message ratchet so unverified guests aren't
/// blocked by the TOFU/`verified` gate on `decryptInbound`.
bool isRoomPacket(Object? data) {
  if (data is! Map) return false;
  final t = data['type'];
  return t is String && t.startsWith('room_');
}

/// Signature for the handler returned by [createPacketHandler]. Matches
/// PeerJS `conn.on('data', ...)` — the transport gives us a raw decoded
/// value and we chew on it asynchronously.
typedef PacketHandler = Future<void> Function(Object? data);

/// Per-connection wiring for the router. Built once at attach time; the
/// router holds a reference for the lifetime of the channel.
class PacketRouterCtx {
  const PacketRouterCtx({
    required this.conn,
    required this.reliable,
    required this.ephemeral,
    required this.flushOutbox,
    this.dropHandlePacket,
    this.dropInbound,
    this.roomInbound,
  });

  /// Plaintext send over the underlying DataConnection. The router uses
  /// it to forward wire-handshake replies; app-level chat traffic flows
  /// through [reliable.sendEncrypted] instead.
  final ConnSend conn;

  /// Reliable-channel dispatch context for this peer.
  final ReliableInboundCtx reliable;

  /// Ephemeral-channel dispatch context (typing + heartbeat).
  final EphemeralInboundCtx ephemeral;

  /// Called after the reliable dispatcher consumes a packet — mirrors
  /// `flushOutboxForPeer(remoteId)` in JS. The caller typically retries
  /// any queued outbound messages here because an ack just landed.
  final void Function() flushOutbox;

  /// Optional DropManager hook for *discovery* beacons (drop-beacon etc) that
  /// ride the ephemeral channel. Null is a legal "dropless build" state.
  final void Function(String remoteId, Map<String, Object?> data)?
      dropHandlePacket;

  /// Optional Orbits-Drop file-transfer hook. Receives both the JSON control
  /// maps (`file-start`/`file-end`/`file-abort`) and the raw binary chunk
  /// frames ([Uint8List]) on the reliable channel, and feeds them into the
  /// `DropEngine`. Null leaves file transfer disabled.
  final void Function(String remoteId, Object packet)? dropInbound;

  /// Optional room-protocol hook. Receives plaintext `room_*` control maps on
  /// the reliable channel and feeds them into the `RoomManager`
  /// (star-topology room signalling). Null leaves rooms disabled.
  final void Function(String remoteId, Map<String, Object?> data)? roomInbound;
}

// ─── Middlewares ──────────────────────────────────────────────────

/// Reliable-channel drop-packet fast-path. Returns `true` if the packet
/// was a drop/file-transfer frame, `false` otherwise (fall through to
/// [reliableMiddleware]).
bool dropMiddleware(String remoteId, Object? data, PacketRouterCtx ctx) {
  if (!isDropPacket(data)) return false;
  ctx.dropHandlePacket
      ?.call(remoteId, Map<String, Object?>.from(data as Map));
  return true;
}

/// Ephemeral-channel entry. Decrypts wire ciphertext if needed, peels
/// off drop-beacon packets, and hands anything else to
/// [dispatchEphemeralInbound]. Always returns `true` — the ephemeral
/// chain has only this one middleware so nothing falls through.
Future<bool> ephemeralMiddleware(
  String remoteId,
  Object? rawData,
  PacketRouterCtx ctx,
) async {
  Object? payload = rawData;

  if (isWireCiphertext(rawData)) {
    try {
      payload = await decryptWirePayload(remoteId, rawData as String);
    } catch (_) {
      // Bad ciphertext on an unreliable channel is normal noise — swallow
      // without surfacing to onDecryptError (which is reliable-only in JS).
      return true;
    }
  } else if (rawData is String) {
    // Stray unencrypted string — ignore. Protocol puts typing/hb as JSON.
    return true;
  }

  if (payload is! Map) return true;
  final mapPayload = Map<String, Object?>.from(payload);

  // Drop-beacon packets can ride the ephemeral channel (lower latency for
  // discovery). Same short-circuit as the reliable drop middleware.
  if (isDropPacket(mapPayload)) {
    ctx.dropHandlePacket?.call(remoteId, mapPayload);
    return true;
  }

  dispatchEphemeralInbound(mapPayload, remoteId, ctx.ephemeral);
  return true;
}

/// Reliable-channel entry. Delegates to [dispatchReliableInbound] and
/// flushes the outbox when the dispatcher reports the packet was
/// consumed (handshake accepted, ack/message/etc routed). Always
/// returns `true` — this is the terminal middleware in the reliable
/// chain, so nothing falls through.
Future<bool> reliableMiddleware(
  String remoteId,
  Object? data,
  PacketRouterCtx ctx,
) async {
  final handled = await dispatchReliableInbound(
    data,
    ctx.conn,
    remoteId,
    ctx.reliable,
  );
  if (handled) {
    try {
      ctx.flushOutbox();
    } catch (_) {
      // Outbox flush is best-effort; nothing above this frame cares
      // whether it succeeded this tick.
    }
  }
  return true;
}

// ─── Chain runner ─────────────────────────────────────────────────

/// Build a packet handler for a given channel.
///
/// Pass `'ephemeral'` for the unreliable channel (typing + heartbeat +
/// optional drop-beacon) or `'reliable'` for the ordered channel (chat,
/// wire handshake, profile exchange, acks, drop/file-transfer frames).
///
/// The returned [PacketHandler] is safe to wire straight into the
/// transport's `onData` callback. It catches nothing — transport-level
/// failures should bubble so the connection layer can trigger a rekey
/// or a reconnect.
PacketHandler createPacketHandler(
  String channel,
  String remoteId,
  PacketRouterCtx ctx,
) {
  if (channel == 'ephemeral') {
    return (data) async {
      await ephemeralMiddleware(remoteId, data, ctx);
    };
  }

  // Reliable channel: file-transfer traffic first (binary chunks + control),
  // then the generic drop fast-path (beacons), then everything else.
  return (data) async {
    // Binary chunk frame → Drop engine. Nothing else on the reliable channel
    // sends raw binary (wire ciphertext is a String, control is a Map).
    if (data is Uint8List) {
      ctx.dropInbound?.call(remoteId, data);
      return;
    }
    // file-start / file-end / file-abort control maps → Drop engine.
    if (data is Map && _fileTransferTypes.contains(data['type'])) {
      ctx.dropInbound?.call(remoteId, Map<String, Object?>.from(data));
      return;
    }
    // Room-protocol control maps + QR-pairing auth responses (both plaintext,
    // reliable) → RoomManager bridge. Checked before the generic dispatcher so
    // they don't fall through to the chat/wire handler (which would drop them
    // as unknown types).
    if (data is Map &&
        (isRoomPacket(data) || data['type'] == 'qr_auth_response')) {
      ctx.roomInbound?.call(remoteId, Map<String, Object?>.from(data));
      return;
    }
    if (dropMiddleware(remoteId, data, ctx)) return;
    await reliableMiddleware(remoteId, data, ctx);
  };
}

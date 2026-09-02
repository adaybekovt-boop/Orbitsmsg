// Port of `src/messaging/messageProtocol.js`.
//
// Pure inbound-message dispatcher. Takes a decoded data object coming off a
// PeerJS DataChannel and routes it to the right application-level handler
// (profile exchange, ack, edit/delete, bundle push/pull, chat msg). No
// Flutter / no platform channels at this level вЂ” all UI effects are
// surfaced via typed callbacks on [ReliableInboundCtx], so the module is
// unit-testable with fakes and has zero dependency on the widget tree.
//
// Port choices that deviate from the literal JS:
// - React `refs.current` в†’ Dart getters (`() => localProfile`) or shared
//   mutable collections (`Set<String> seenMsgIds`). The owner holds the
//   state; the dispatcher only reads / mutates it.
// - `ctx.setProfilesByPeer((prev) => next)` / `setMessagesByPeer` kept as
//   functional updaters so the eventual Riverpod wiring can plug in as a
//   `state = updater(state)` without rewriting this module. In Phase 11 we
//   can swap to Riverpod notifiers; everything under this file stays as-is.
// - `localStorage.setItem(STORAGE.profiles, вЂ¦)` inside the profile-res
//   branch is intentionally *omitted*: peers are already persisted via
//   [db.savePeer] through `upsertPeer`, so the LS cache is redundant. UI
//   layer can add a `SharedPreferences` mirror later if hydration latency
//   matters.
// - `document.hidden && document.hasFocus()` (web foreground check) в†’
//   `ctx.isAppInForeground()` callback. Mobile callers wire this to
//   `WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed`.
// - Blobs: web JS uses `Blob`, Dart uses raw `Uint8List`. Voice / file
//   storage already accepts `List<int>` in `storage/db.dart` вЂ” we pass
//   base64-decoded bytes straight through.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../core/bundle_cache.dart';
import '../core/prekey_bundle.dart';
import '../core/wire_crypto.dart';
import '../peer/helpers.dart';
import '../utils/heavy_codec.dart';
import '../storage/db.dart' as db;
import '../transport/hello_capabilities.dart';
import '../transport/layers.dart';
import '../utils/common.dart';
import 'message_auth.dart';

// в”Ђв”Ђв”Ђ Type aliases в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

/// JSON-ish map we pass around when we don't want to invent a class for
/// every on-the-wire payload.
typedef JsonMap = Map<String, Object?>;

/// Transport-level callback for sending raw (not yet encrypted) frames
/// over the underlying PeerJS DataConnection. Used for the plaintext
/// wire-handshake reply вЂ” chat traffic goes through [ReliableInboundCtx.sendEncrypted].
typedef ConnSend = void Function(Object? data);

// в”Ђв”Ђв”Ђ Ephemeral (typing / heartbeat) context в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

class EphemeralInboundCtx {
  const EphemeralInboundCtx({
    required this.applyTyping,
    required this.onHeartbeat,
  });

  /// Called with the parsed `isTyping` flag. The caller typically runs
  /// this through a debounce so stale "still typing" indicators expire.
  final void Function(bool isTyping) applyTyping;

  /// Called on every `{type: 'hb'}` packet. Keep-alive so the UI can
  /// detect a hung reliable channel and trigger a wireRekey if needed.
  final void Function() onHeartbeat;
}

// в”Ђв”Ђв”Ђ Reliable (chat / control) context в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

/// Outcome of persisting one inbound chat message (R03 / R04).
enum InboundPersistResult { committed, blocked, failed, duplicate }

class ReliableInboundCtx {
  ReliableInboundCtx({
    required this.selfPeerId,
    required this.localProfile,
    required this.seenMsgIds,
    required this.pushMessage,
    required this.updateMessage,
    required this.setProfilesByPeer,
    required this.setMessagesByPeer,
    required this.upsertPeer,
    required this.queueAckStatus,
    required this.sendEncrypted,
    required this.notifyNewMessage,
    required this.hapticMessage,
    required this.playReceiveSound,
    required this.isAppInForeground,
    this.onGameMessage,
    this.onBundleAccepted,
    this.onBundleRejected,
    this.onHandshakeError,
    this.onDecryptError,
    this.onUnexpectedPlaintext,
    this.onDeliveryAcked,
    this.persistInbound,
    this.isPeerBlocked,
    this.assembleNativeAttachment,
    this.assembleNativeAttachmentPath,
    Set<String>? processingMsgIds,
  }) : processingMsgIds = processingMsgIds ?? <String>{};

  /// Our own normalized peerId. Was `peerIdRef.current` in JS.
  final String selfPeerId;

  /// Getter for the current local profile (nullable вЂ” user may have logged
  /// out between dispatch and read). Was `localProfileRef.current`.
  final JsonMap? Function() localProfile;

  /// De-dup set for inbound messages that have been *committed*. Shared-
  /// mutable; dispatcher adds the id only after persist succeeds. Clamp
  /// ~4000 / keep the most recent 2000 on overflow. Same heuristic as JS.
  final Set<String> seenMsgIds;

  /// Ids currently being persisted. Failed writes leave this set so a
  /// retry can try again; success moves the id into [seenMsgIds].
  final Set<String> processingMsgIds;

  /// Optional single awaited persist (R03). When set, the dispatcher
  /// does not call [db.saveMessage] itself and only ACKs after
  /// [InboundPersistResult.committed].
  final Future<InboundPersistResult> Function(String remoteId, JsonMap uiMsg)?
      persistInbound;

  /// Ingress block-list check (R04). When true, the dispatcher refuses
  /// the packet before persist / ACK / lastSeen.
  final bool Function(String remoteId)? isPeerBlocked;

  /// Append a fresh inbound message to the UI-side state for [remoteId].
  /// Returns an explicit persist result so callers cannot ignore a reject.
  final Future<InboundPersistResult> Function(String remoteId, JsonMap uiMsg)
      pushMessage;

  /// Patch fields on a UI message (typically `delivery`, `text`, `editedAt`).
  final void Function(String remoteId, String id, JsonMap patch) updateMessage;

  /// Functional updater for the profiles-by-peer state map.
  final void Function(JsonMap Function(JsonMap prev)) setProfilesByPeer;

  /// Functional updater for the messages-by-peer state map. Each value is
  /// the list of UI messages for that peer (newest last).
  final void Function(
    Map<String, List<JsonMap>> Function(Map<String, List<JsonMap>> prev),
  ) setMessagesByPeer;

  /// Merge peer metadata into the contacts table (displayName, lastSeenAt,
  /// etc). Goes through `storage/db.dart::savePeer` upstream.
  final void Function(String peerId, JsonMap patch) upsertPeer;

  /// Broadcast a delivery-status update (delivered / read) to any
  /// outbox-side listeners.
  final void Function(String id, String status) queueAckStatus;

  /// Send a reply over the ratcheted reliable channel. The caller
  /// (packet_router) pre-applies the `remoteId`, so this dispatcher only
  /// needs to hand it the payload map.
  final void Function(JsonMap msg) sendEncrypted;

  /// Platform notification hook. Caller wires to `flutter_local_notifications`
  /// or similar; no-op is a safe default.
  final void Function({
    required String from,
    required String text,
    required String tag,
  }) notifyNewMessage;

  final void Function() hapticMessage;
  final void Function() playReceiveSound;

  /// True when the app is visible + focused. Controls whether we ring the
  /// receive sound / haptic. Usually wired to
  /// `WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed`.
  final bool Function() isAppInForeground;

  // в”Ђв”Ђ Optional observers в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  final void Function(String remoteId, Object? payload)? onGameMessage;
  final void Function(String remoteId, AcceptBundleResult result)?
      onBundleAccepted;
  final void Function(String remoteId, AcceptBundleResult result)?
      onBundleRejected;
  final void Function(Object err)? onHandshakeError;
  final void Function(Object err)? onDecryptError;
  final void Function(Object? data)? onUnexpectedPlaintext;
  final void Function(String remoteId, String eventId)? onDeliveryAcked;

  /// Native `attach-chunk` reassembly. [fileKey] comes from the ratcheted
  /// envelope, never from the journal. Null when the default PeerJS
  /// path is in use.
  final Future<Uint8List?> Function(
    String remoteId,
    String fileId,
    List<int> fileKey,
  )? assembleNativeAttachment;

  /// Native `attach-chunk` decrypt-to-path. Persist via
  /// [db.saveFileBlobFromPath] so Drift does not hold the plaintext.
  final Future<String?> Function(
    String remoteId,
    String fileId,
    List<int> fileKey,
  )? assembleNativeAttachmentPath;
}

// в”Ђв”Ђв”Ђ Ephemeral dispatch в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

/// Route a packet that landed on the ephemeral (unreliable) channel.
/// Only handles `typing` and `hb`; anything else is silently dropped.
void dispatchEphemeralInbound(
  Object? data,
  String remoteId,
  EphemeralInboundCtx ctx,
) {
  if (data is! Map) return;
  if (!replicationValueIsSafe(data)) return;
  final type = data['type'];
  if (type == 'typing') {
    ctx.applyTyping(data['isTyping'] == true);
    return;
  }
  if (type == 'hb') {
    ctx.onHeartbeat();
    return;
  }
}

// в”Ђв”Ђв”Ђ Reliable dispatch (wire-decrypt + route) в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

/// Route a packet that landed on the reliable channel. Accepts either:
///   - a plaintext wire-handshake control object (`wireHello` / `wireRekey`)
///   - a [String] carrying wire ciphertext (`v2:hdr:iv:ct`) в†’ decrypts via
///     the ratchet, then hands the plaintext to [dispatchReliablePlaintext]
/// Anything else is dropped with [ReliableInboundCtx.onUnexpectedPlaintext]
/// so diagnostics surface the drift.
///
/// Returns `true` if the packet was consumed (handshake accepted, plaintext
/// routed), `false` if it was dropped silently.
Future<bool> dispatchReliableInbound(
  Object? data,
  ConnSend connSend,
  String remoteId,
  ReliableInboundCtx ctx,
) async {
  if (ctx.isPeerBlocked?.call(remoteId) == true) {
    return true;
  }
  // в”Ђв”Ђ Handshake in plaintext в”Ђв”Ђ
  if (data is Map) {
    final type = data['type'];
    if (type == 'wireHello' || type == 'wireRekey') {
      // Stricter than [replicationValueIsSafe]: refuse wake tokens and
      // URL-ish keys before the handshake runs. Consumed, no reply.
      if (!helloEnvelopeIsSafe(data)) {
        return true;
      }
      try {
        final result = await acceptWireHello(
          peerId: remoteId,
          myPeerId: ctx.selfPeerId,
          helloMsg: Map<String, Object?>.from(data),
        );
        // First verified (v3+) handshake pins the peer's identity (TOFU). Bump
        // stored trust unknownв†’TOFU so the chat shows an "unverified" (not
        // "unknown") badge and nudges the user to compare safety numbers; this
        // never auto-promotes to user-verified, and only fires on first contact
        // to keep the write off the steady-state path (audit H1).
        if (result.verified && result.firstContact) {
          unawaited(db.ensurePeerTofuTrust(remoteId));
        }
        final reply = result.reply;
        if (reply != null) {
          try {
            connSend(reply);
          } catch (_) {
            // Connection might've closed between decide and send вЂ” not our
            // problem, the upper layer will retry the handshake on reconnect.
          }
        }
      } catch (err) {
        ctx.onHandshakeError?.call(err);
      }
      return true;
    }
  }

  // в”Ђв”Ђ Encrypted payload в”Ђв”Ђ
  if (isWireCiphertext(data)) {
    Object? plaintext;
    try {
      plaintext = await decryptWirePayload(remoteId, data as String);
    } catch (err) {
      ctx.onDecryptError?.call(err);
      return false;
    }
    if (plaintext is! Map) return false;
    return await dispatchReliablePlaintext(
      Map<String, Object?>.from(plaintext),
      connSend,
      remoteId,
      ctx,
    );
  }

  // в”Ђв”Ђ Anything else is dropped silently, but we log once for visibility. в”Ђв”Ђ
  ctx.onUnexpectedPlaintext?.call(data);
  return false;
}

// в”Ђв”Ђв”Ђ Reliable plaintext dispatch (trusted, decrypted) в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

/// Dispatch a decrypted application-level object. This only runs on
/// trusted input that's already been authenticated by the Double Ratchet
/// (or plaintext control frames for handshake/rekey).
Future<bool> dispatchReliablePlaintext(
  JsonMap data,
  ConnSend connSend,
  String remoteId,
  ReliableInboundCtx ctx,
) async {
  void sendReply(JsonMap msg) {
    try {
      ctx.sendEncrypted(msg);
    } catch (_) {
      // Outbound failure here is fine вЂ” the original packet has already
      // been logically handled; the sender will retry on their side.
    }
  }

  final type = data['type'];

  // в”Ђв”Ђв”Ђ profile_req вЂ” remote wants our profile card в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
  if (type == 'profile_req') {
    final lp = ctx.localProfile();
    if (lp == null) return true;
    // Do not reply with a secret-bearing card if localProfile itself
    // nests [kForbiddenReplicationFields] (`peerId` / `avatarDataUrl` are
    // legitimate leaves and stay allowed).
    if (!replicationValueIsSafe(lp)) return true;
    final nonce = data['nonce'] is num
        ? (data['nonce'] as num).toInt()
        : DateTime.now().millisecondsSinceEpoch;
    sendReply(<String, Object?>{
      'type': 'profile_res',
      'nonce': nonce,
      'profile': <String, Object?>{
        'peerId': lp['peerId'],
        'displayName': lp['displayName'],
        'bio': lp['bio'],
        'avatarDataUrl': lp['avatarDataUrl'],
      },
    });
    return true;
  }

  // в”Ђв”Ђв”Ђ profile_res вЂ” remote returned their profile card в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
  if (type == 'profile_res') {
    final p = data['profile'];
    if (p is! Map) return true;
    final pMap = Map<String, Object?>.from(p);
    if (!replicationValueIsSafe(pMap)) return true;
    final avatarRaw = pMap['avatarDataUrl'];

    // Remote avatars are untrusted вЂ” validate MIME + size strictly (the
    // validator also rejects data:image/svg+xml which can carry scripts).
    final safeAvatar = safeAvatarDataUrl(avatarRaw);
    if (safeAvatar != null) {
      unawaited(_safelySaveAvatar(remoteId, safeAvatar));
    } else if (avatarRaw == null || avatarRaw == '') {
      // Peer explicitly cleared their avatar вЂ” drop the stale cached copy.
      unawaited(_safelyDeleteAvatar(remoteId));
    }

    final safeDisplayName = _clip(
      (pMap['displayName'] as String?) ?? remoteId,
      64,
    );
    try {
      ctx.upsertPeer(remoteId, <String, Object?>{
        'displayName': safeDisplayName,
        'lastSeenAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {}

    ctx.setProfilesByPeer((prev) {
      final next = Map<String, Object?>.from(prev);
      next[remoteId] = <String, Object?>{
        'peerId': remoteId,
        'displayName': safeDisplayName,
        'bio': _clip((pMap['bio'] as String?) ?? '', 220),
        'avatarDataUrl': safeAvatar,
      };
      return next;
    });
    return true;
  }

  // в”Ђв”Ђв”Ђ bundle_req / bundle_res вЂ” X3DH prekey bundle exchange в”Ђв”Ђв”Ђв”Ђв”Ђ
  if (type == 'bundle_req') {
    final nonce = data['nonce'] is num
        ? (data['nonce'] as num).toInt()
        : DateTime.now().millisecondsSinceEpoch;
    final selfPeerId = ctx.selfPeerId;
    if (selfPeerId.isEmpty) return true;
    unawaited(() async {
      try {
        final bundle = await buildLocalBundle(peerId: selfPeerId);
        sendReply(<String, Object?>{
          'type': 'bundle_res',
          'nonce': nonce,
          'bundle': serializeBundle(bundle),
        });
      } catch (_) {
        // Bundle build failure is non-fatal вЂ” remote will retry.
      }
    }());
    return true;
  }

  if (type == 'bundle_res') {
    final wire = data['bundle'];
    if (wire is! Map) return true;
    unawaited(() async {
      final result = await acceptIncomingBundle(
        senderPeerId: remoteId,
        wire: Map<String, Object?>.from(wire),
      );
      if (result.ok) {
        try {
          ctx.onBundleAccepted?.call(remoteId, result);
        } catch (_) {}
      } else {
        try {
          ctx.onBundleRejected?.call(remoteId, result);
        } catch (_) {}
      }
    }());
    return true;
  }

  // в”Ђв”Ђв”Ђ ack вЂ” delivery receipt for an outbound message в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
  if (type == 'ack') {
    final ackId = data['id'];
    if (ackId is! String || ackId.isEmpty) return true;
    final row = await db.getMessageById(ackId);
    if (!remoteCanAckOutbound(remoteId, row)) return true;
    ctx.updateMessage(remoteId, ackId, <String, Object?>{
      'delivery': 'delivered',
    });
    ctx.queueAckStatus(ackId, 'delivered');
    try {
      ctx.onDeliveryAcked?.call(remoteId, ackId);
    } catch (_) {}
    return true;
  }

  // в”Ђв”Ђв”Ђ game вЂ” mini-game piggyback on the reliable channel в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
  if (type == 'game') {
    final payload = data['payload'];
    // Nested secret in a Map payload: consume without handing it to the
    // game observer. Non-Map payloads keep current behavior unless the
    // envelope itself nests a forbidden key.
    if (payload is Map) {
      if (!replicationValueIsSafe(payload)) return true;
    } else if (!replicationValueIsSafe(data)) {
      return true;
    }
    try {
      ctx.onGameMessage?.call(remoteId, payload);
    } catch (_) {}
    return true;
  }

  // в”Ђв”Ђв”Ђ edit вЂ” remote edited an earlier message в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
  if (type == 'edit') {
    // `text` is a legitimate leaf (not in [kForbiddenReplicationFields]);
    // a nested secret on the envelope must not reach updateMessage / Drift.
    if (!replicationValueIsSafe(data)) return true;
    final id = data['id'];
    if (id is! String || id.isEmpty) return true;
    final existing = await db.getMessageById(id);
    if (!remoteOwnsInboundMessage(remoteId, existing)) return true;
    final newText = data['text'] is String ? data['text'] as String : '';
    final editedAt = (data['editedAt'] is num)
        ? (data['editedAt'] as num).toInt()
        : DateTime.now().millisecondsSinceEpoch;
    ctx.updateMessage(remoteId, id, <String, Object?>{
      'text': newText,
      'editedAt': editedAt,
    });
    unawaited(() async {
      try {
        final row = await db.getMessageById(id);
        if (row != null) {
          final payload = row['payload'];
          final basePayload = payload is Map
              ? Map<String, Object?>.from(payload)
              : <String, Object?>{};
          basePayload['text'] = newText;
          basePayload['editedAt'] = editedAt;
          await db.updateMessage(id, <String, Object?>{
            'payload': basePayload,
          });
        }
      } catch (_) {}
    }());
    return true;
  }

  // в”Ђв”Ђв”Ђ delete вЂ” remote tombstones an earlier message в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
  if (type == 'delete') {
    // Hostile envelope with a nested secret must not tombstone.
    if (!replicationValueIsSafe(data)) return true;
    final id = data['id'];
    if (id is! String || id.isEmpty) return true;
    final existing = await db.getMessageById(id);
    if (!remoteOwnsInboundMessage(remoteId, existing)) return true;
    final forEveryone = data['forEveryone'] == true;
    if (forEveryone) {
      ctx.setMessagesByPeer((prev) {
        final list = prev[remoteId] ?? const <JsonMap>[];
        final next = list.where((m) => m['id'] != id).toList(growable: false);
        if (next.length == list.length) return prev;
        final out = Map<String, List<JsonMap>>.from(prev);
        out[remoteId] = next;
        return out;
      });
      unawaited(db.deleteMessageRow(id));
      // The row might reference a voice OR file blob вЂ” we don't know
      // which from the delete envelope alone (id is just the message
      // id, same across types). Try both; each is a no-op if the key
      // doesn't exist in that table. Without this we'd leak `file_blobs`
      // rows forever when the peer recalls a shared image/video/file.
      unawaited(() async {
        try {
          await db.deleteVoiceBlob(id);
        } catch (_) {}
        try {
          await db.deleteFileBlob(id);
        } catch (_) {}
      }());
    }
    return true;
  }

  // в”Ђв”Ђв”Ђ msg / text вЂ” regular chat message в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
  final typeStr = type is String ? type : '';
  if (typeStr != 'msg' && typeStr != 'text') return false;

  final text = data['text'] is String ? data['text'] as String : '';
  final ts = data['ts'] is num
      ? (data['ts'] as num).toInt()
      : DateTime.now().millisecondsSinceEpoch;
  final fromRaw = data['from'];
  final from = normalizePeerId(fromRaw is String ? fromRaw : remoteId);
  final rawId = data['id'];
  // Fail-close: URL-shaped ids must not be used as msgId, minted around,
  // persisted, or echoed in an ack.
  if (rawId is String && rawId.contains('://')) {
    return true;
  }
  final msgId = (rawId is String && rawId.isNotEmpty)
      ? rawId
      : '$from:$ts:${_randomHex()}';
  final msgType = data['msgType'] is String ? data['msgType'] as String : 'text';
  JsonMap? sticker = data['sticker'] is Map
      ? Map<String, Object?>.from(data['sticker'] as Map)
      : null;
  if (sticker != null && !replicationValueIsSafe(sticker)) sticker = null;
  JsonMap? replyTo = data['replyTo'] is Map
      ? Map<String, Object?>.from(data['replyTo'] as Map)
      : null;
  if (replyTo != null && !replicationValueIsSafe(replyTo)) replyTo = null;
  JsonMap? voiceMeta = data['voice'] is Map
      ? Map<String, Object?>.from(data['voice'] as Map)
      : null;
  if (voiceMeta != null && !replicationValueIsSafe(voiceMeta)) voiceMeta = null;
  final attachmentMeta = data['attachment'] is Map
      ? Map<String, Object?>.from(data['attachment'] as Map)
      : null;

  // De-dup: committed ids still owe a fresh ack (remote may have lost
  // ours). Processing ids must NOT be acked — persist has not committed.
  if (ctx.seenMsgIds.contains(msgId)) {
    sendReply(<String, Object?>{
      'type': 'ack',
      'id': msgId,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    return true;
  }
  if (ctx.processingMsgIds.contains(msgId)) {
    return true;
  }
  if (ctx.isPeerBlocked?.call(remoteId) == true) {
    return true;
  }
  ctx.processingMsgIds.add(msgId);

  await () async {
    // Belt-and-braces: the in-memory dedup already fired, but if this
    // dispatcher was just re-hydrated from disk a DB row might exist.
    if (ctx.persistInbound == null) {
      try {
        final existing = await db.getMessageById(msgId);
        if (existing != null) {
          ctx.processingMsgIds.remove(msgId);
          ctx.seenMsgIds.add(msgId);
          sendReply(<String, Object?>{
            'type': 'ack',
            'id': msgId,
            'ts': DateTime.now().millisecondsSinceEpoch,
          });
          return;
        }
      } catch (_) {}
    }

    // в”Ђв”Ђ Voice meta: decode + persist blob if inline, else metadata-only в”Ђв”Ђ
    JsonMap? voiceRef;
    final transcriptRaw = voiceMeta?['transcript'];
    final transcript =
        transcriptRaw is String ? _clip(transcriptRaw, 2000) : '';
    if (voiceMeta != null && voiceMeta['b64'] is String) {
      try {
        final b64 = voiceMeta['b64'] as String;
        // Anti-OOM (audit finding 4): cap the attacker-controlled base64 length
        // BEFORE decode. Mirrors the send-side gate `_maxVoiceB64Len` (8 MiB)
        // in messaging_notifier.dart. Oversized в†’ treated as bad base64 (falls
        // through to the metadata-only "voice failed" bubble below).
        if (b64.length > 8 * 1024 * 1024) {
          throw const FormatException('voice b64 exceeds inbound cap');
        }
        final bytes = await b64DecodeHeavy(b64);
        final mime = (voiceMeta['mime'] as String?) ?? 'audio/webm';
        final duration = _asInt(voiceMeta['duration']);
        final waveform = _numListToDoubles(voiceMeta['waveform']);
        await db.saveVoiceBlob(
          msgId,
          bytes,
          mime: mime,
          duration: duration,
          waveform: waveform,
        );
        voiceRef = <String, Object?>{
          'duration': duration,
          'mime': mime,
          'waveform': waveform,
          'transcript': transcript,
        };
      } catch (_) {
        // Bad base64 вЂ” fall through to metadata-only so the bubble can at
        // least render a "voice failed" state.
      }
    } else if (voiceMeta != null) {
      voiceRef = <String, Object?>{
        'duration': _asInt(voiceMeta['duration']),
        'mime': (voiceMeta['mime'] as String?) ?? 'audio/webm',
        'waveform': _numListToDoubles(voiceMeta['waveform']),
        'transcript': transcript,
      };
    }

    // в”Ђв”Ђ Attachment meta: decode + persist blob if inline, else missing:true в”Ђв”Ђ
    JsonMap? attachmentRef;
    if (attachmentMeta != null) {
      final name = _clip((attachmentMeta['name'] as String?) ?? 'file', 200);
      final mime =
          (attachmentMeta['mime'] as String?) ?? 'application/octet-stream';
      final kind = (attachmentMeta['kind'] as String?) ?? 'file';
      final size = _asInt(attachmentMeta['size']);
      final width = _asInt(attachmentMeta['width']);
      final height = _asInt(attachmentMeta['height']);
      final duration = _asInt(attachmentMeta['duration']);
      final thumb =
          attachmentMeta['thumb'] is String ? attachmentMeta['thumb'] : null;

      final metaOut = <String, Object?>{
        'name': name,
        'size': size,
        'mime': mime,
        'kind': kind,
        'thumb': thumb,
        'width': width,
        'height': height,
        'duration': duration,
      };

      if (attachmentMeta['b64'] is String) {
        try {
          final b64 = attachmentMeta['b64'] as String;
          // Anti-OOM (audit finding 4): cap base64 length BEFORE decode.
          // Mirrors the send-side gate `_maxFileB64Len` (16 MiB) in
          // messaging_notifier.dart. Oversized → marked missing (below).
          if (b64.length > 16 * 1024 * 1024) {
            throw const FormatException('attachment b64 exceeds inbound cap');
          }
          final bytes = await b64DecodeHeavy(b64);
          await db.saveFileBlob(
            msgId,
            bytes,
            mime: mime,
            name: name,
            kind: kind,
            size: size == 0 ? bytes.length : size,
            width: width,
            height: height,
            duration: duration,
            // `thumb` on the wire is a dataURL string; persisting it as bytes
            // would round-trip through utf8 which hurts nothing but adds
            // nothing either — we keep the string copy inside the UI-side
            // attachmentRef and leave the bytes-column null for now.
          );
          attachmentRef = metaOut;
        } catch (_) {
          attachmentRef = <String, Object?>{...metaOut, 'missing': true};
        }
      } else if (attachmentMeta['chunked'] == true) {
        attachmentRef = await _assembleChunkedAttachment(
          ctx: ctx,
          remoteId: remoteId,
          msgId: msgId,
          meta: attachmentMeta,
          metaOut: metaOut,
          mime: mime,
          name: name,
          kind: kind,
          size: size,
          width: width,
          height: height,
          duration: duration,
        );
      } else {
        attachmentRef = <String, Object?>{...metaOut, 'missing': true};
      }
    }

    final uiMsg = <String, Object?>{
      'id': msgId,
      'from': remoteId,
      'to': ctx.selfPeerId,
      'text': text,
      'ts': ts,
      'delivery': 'received',
      'type': msgType,
      'sticker': sticker,
      'replyTo': replyTo,
      'voice': voiceRef,
      'attachment': attachmentRef,
    };
    final persist = ctx.persistInbound ?? ctx.pushMessage;
    InboundPersistResult persistResult;
    try {
      persistResult = await persist(remoteId, uiMsg);
    } catch (_) {
      persistResult = InboundPersistResult.failed;
    }
    ctx.processingMsgIds.remove(msgId);
    if (persistResult != InboundPersistResult.committed &&
        persistResult != InboundPersistResult.duplicate) {
      return;
    }

    ctx.seenMsgIds.add(msgId);
    if (ctx.seenMsgIds.length > 4000) {
      final kept = ctx.seenMsgIds
          .toList(growable: false)
          .sublist(ctx.seenMsgIds.length - 2000);
      ctx.seenMsgIds
        ..clear()
        ..addAll(kept);
    }

    sendReply(<String, Object?>{
      'type': 'ack',
      'id': msgId,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });

    if (ctx.isAppInForeground()) {
      try {
        ctx.hapticMessage();
      } catch (_) {}
      try {
        ctx.playReceiveSound();
      } catch (_) {}
    }

    final preview = _previewFor(
      msgType: msgType,
      text: text,
      sticker: sticker,
      attachment: attachmentRef,
    );
    try {
      ctx.notifyNewMessage(from: remoteId, text: preview, tag: msgId);
    } catch (_) {}
  }();

  return true;
}

// в”Ђв”Ђв”Ђ Private helpers в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

String _clip(String s, int maxChars) =>
    s.length > maxChars ? s.substring(0, maxChars) : s;

int _asInt(Object? v) => v is num ? v.toInt() : 0;

/// Coerce a dynamic list of numerics into `List<double>` waveform
/// amplitudes in 0..1. Matches the JS wire format
/// (`audioRecorder.js::compressSamples` в†’ `Math.min(1, в€љrms Г— 2.2)`);
/// Flutter storage + player widget use the same shape so no rescaling
/// is needed on either edge.
///
/// Historically this helper rounded via `.toInt()`, which collapsed the
/// JS 0..1 doubles into 0 or 1 and broke the player's waveform
/// rendering. Keeping the shape as doubles end-to-end avoids that
/// quantisation pothole entirely.
///
/// Values > 1 get clamped (a misbehaving peer shouldn't be able to
/// coax a 1000-unit-tall bar), values < 0 clamp to 0. Returns null for
/// absent input so the DB column can stay absent rather than being set
/// to an empty list.
List<double>? _numListToDoubles(Object? v) {
  if (v is! List) return null;
  final out = <double>[];
  for (final e in v) {
    if (e is num) {
      final d = e.toDouble();
      out.add(d.isNaN ? 0 : d.clamp(0, 1).toDouble());
    }
  }
  return out;
}

Future<JsonMap> _assembleChunkedAttachment({
  required ReliableInboundCtx ctx,
  required String remoteId,
  required String msgId,
  required JsonMap meta,
  required JsonMap metaOut,
  required String mime,
  required String name,
  required String kind,
  required int size,
  required int width,
  required int height,
  required int duration,
}) async {
  final missing = <String, Object?>{...metaOut, 'missing': true};
  final fileId = meta['fileId'];
  final keyB64 = meta['fileKeyB64'];
  if (fileId is! String ||
      fileId.isEmpty ||
      fileId.length > 200 ||
      fileId.contains('://') ||
      keyB64 is! String ||
      keyB64.isEmpty ||
      keyB64.length > 64) {
    return missing;
  }
  List<int> key;
  try {
    key = base64Decode(keyB64);
  } catch (_) {
    return missing;
  }
  if (key.length < 8) return missing;
  final pathAssemble = ctx.assembleNativeAttachmentPath;
  if (pathAssemble != null) {
    try {
      final path = await pathAssemble(remoteId, fileId, key);
      if (path != null && path.isNotEmpty && !path.contains('://')) {
        final ok = await db.saveFileBlobFromPath(
          msgId,
          path,
          mime: mime,
          name: name,
          kind: kind,
          size: size,
          width: width,
          height: height,
          duration: duration,
        );
        if (ok) return metaOut;
      }
    } catch (_) {}
  }
  final assemble = ctx.assembleNativeAttachment;
  if (assemble == null) return missing;
  try {
    final bytes = await assemble(remoteId, fileId, key);
    if (bytes == null || bytes.isEmpty) return missing;
    await db.saveFileBlob(
      msgId,
      bytes,
      mime: mime,
      name: name,
      kind: kind,
      size: size == 0 ? bytes.length : size,
      width: width,
      height: height,
      duration: duration,
    );
    return metaOut;
  } catch (_) {
    return missing;
  }
}

/// Entropy for fallback [msgId] generation. Message ids are not keys, but
/// a predictable PRNG lets a peer collide or pre-guess ids. Must be
/// [Random.secure], not the default [Random].
Random newMessageIdRng() => Random.secure();

/// 64 bits of randomness as 16 hex chars. Used when inbound `msg`/`text`
/// has no `id`.
String _randomHex() {
  final rng = newMessageIdRng();
  final lo = rng.nextInt(1 << 32);
  final hi = rng.nextInt(1 << 32);
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}

String _previewFor({
  required String msgType,
  required String text,
  JsonMap? sticker,
  JsonMap? attachment,
}) {
  if (msgType == 'sticker') {
    final emoji = sticker?['emoji'];
    return emoji is String && emoji.isNotEmpty ? emoji : 'рџ–ј РЎС‚РёРєРµСЂ';
  }
  if (msgType == 'voice') return 'рџЋ¤ Р“РѕР»РѕСЃРѕРІРѕРµ';
  if (msgType == 'file') {
    final kind = attachment?['kind'];
    if (kind == 'image') return 'рџ–ј Р¤РѕС‚Рѕ';
    if (kind == 'video') return 'рџЋ¬ Р’РёРґРµРѕ';
    final name = attachment?['name'];
    return 'рџ“Ћ ${name is String && name.isNotEmpty ? name : 'Р¤Р°Р№Р»'}';
  }
  return text;
}

Future<void> _safelySaveAvatar(String peerId, String dataUrl) async {
  try {
    await db.saveAvatar(peerId, dataUrl);
  } catch (_) {
    // Avatar persist failure is non-fatal; next profile-res round will retry.
  }
}

Future<void> _safelyDeleteAvatar(String peerId) async {
  try {
    await db.deleteAvatar(peerId);
  } catch (_) {}
}

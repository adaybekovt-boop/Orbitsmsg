// Port of `src/messaging/messageProtocol.js`.
//
// Pure inbound-message dispatcher. Takes a decoded data object coming off a
// PeerJS DataChannel and routes it to the right application-level handler
// (profile exchange, ack, edit/delete, bundle push/pull, chat msg). No
// Flutter / no platform channels at this level — all UI effects are
// surfaced via typed callbacks on [ReliableInboundCtx], so the module is
// unit-testable with fakes and has zero dependency on the widget tree.
//
// Port choices that deviate from the literal JS:
// - React `refs.current` → Dart getters (`() => localProfile`) or shared
//   mutable collections (`Set<String> seenMsgIds`). The owner holds the
//   state; the dispatcher only reads / mutates it.
// - `ctx.setProfilesByPeer((prev) => next)` / `setMessagesByPeer` kept as
//   functional updaters so the eventual Riverpod wiring can plug in as a
//   `state = updater(state)` without rewriting this module. In Phase 11 we
//   can swap to Riverpod notifiers; everything under this file stays as-is.
// - `localStorage.setItem(STORAGE.profiles, …)` inside the profile-res
//   branch is intentionally *omitted*: peers are already persisted via
//   [db.savePeer] through `upsertPeer`, so the LS cache is redundant. UI
//   layer can add a `SharedPreferences` mirror later if hydration latency
//   matters.
// - `document.hidden && document.hasFocus()` (web foreground check) →
//   `ctx.isAppInForeground()` callback. Mobile callers wire this to
//   `WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed`.
// - Blobs: web JS uses `Blob`, Dart uses raw `Uint8List`. Voice / file
//   storage already accepts `List<int>` in `storage/db.dart` — we pass
//   base64-decoded bytes straight through.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../core/bundle_cache.dart';
import '../core/prekey_bundle.dart';
import '../core/wire_crypto.dart';
import '../peer/helpers.dart';
import '../storage/db.dart' as db;
import '../utils/common.dart';
import 'message_auth.dart';

// ─── Type aliases ─────────────────────────────────────────────────

/// JSON-ish map we pass around when we don't want to invent a class for
/// every on-the-wire payload.
typedef JsonMap = Map<String, Object?>;

/// Transport-level callback for sending raw (not yet encrypted) frames
/// over the underlying PeerJS DataConnection. Used for the plaintext
/// wire-handshake reply — chat traffic goes through [ReliableInboundCtx.sendEncrypted].
typedef ConnSend = void Function(Object? data);

// ─── Ephemeral (typing / heartbeat) context ───────────────────────

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

// ─── Reliable (chat / control) context ────────────────────────────

class ReliableInboundCtx {
  const ReliableInboundCtx({
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
  });

  /// Our own normalized peerId. Was `peerIdRef.current` in JS.
  final String selfPeerId;

  /// Getter for the current local profile (nullable — user may have logged
  /// out between dispatch and read). Was `localProfileRef.current`.
  final JsonMap? Function() localProfile;

  /// De-dup set for inbound messages. Shared-mutable; dispatcher adds the
  /// id of every delivered message and clamps size to ~4000 / keeps the
  /// most recent 2000 on overflow. Same heuristic as JS.
  final Set<String> seenMsgIds;

  /// Append a fresh inbound message to the UI-side state for [remoteId].
  final void Function(String remoteId, JsonMap uiMsg) pushMessage;

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

  // ── Optional observers ──────────────────────────────────────────

  final void Function(String remoteId, Object? payload)? onGameMessage;
  final void Function(String remoteId, AcceptBundleResult result)?
      onBundleAccepted;
  final void Function(String remoteId, AcceptBundleResult result)?
      onBundleRejected;
  final void Function(Object err)? onHandshakeError;
  final void Function(Object err)? onDecryptError;
  final void Function(Object? data)? onUnexpectedPlaintext;
}

// ─── Ephemeral dispatch ───────────────────────────────────────────

/// Route a packet that landed on the ephemeral (unreliable) channel.
/// Only handles `typing` and `hb`; anything else is silently dropped.
void dispatchEphemeralInbound(
  Object? data,
  String remoteId,
  EphemeralInboundCtx ctx,
) {
  if (data is! Map) return;
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

// ─── Reliable dispatch (wire-decrypt + route) ─────────────────────

/// Route a packet that landed on the reliable channel. Accepts either:
///   - a plaintext wire-handshake control object (`wireHello` / `wireRekey`)
///   - a [String] carrying wire ciphertext (`v2:hdr:iv:ct`) → decrypts via
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
  // ── Handshake in plaintext ──
  if (data is Map) {
    final type = data['type'];
    if (type == 'wireHello' || type == 'wireRekey') {
      try {
        final result = await acceptWireHello(
          peerId: remoteId,
          myPeerId: ctx.selfPeerId,
          helloMsg: Map<String, Object?>.from(data),
        );
        // First verified (v3+) handshake pins the peer's identity (TOFU). Bump
        // stored trust unknown→TOFU so the chat shows an "unverified" (not
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
            // Connection might've closed between decide and send — not our
            // problem, the upper layer will retry the handshake on reconnect.
          }
        }
      } catch (err) {
        ctx.onHandshakeError?.call(err);
      }
      return true;
    }
  }

  // ── Encrypted payload ──
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

  // ── Anything else is dropped silently, but we log once for visibility. ──
  ctx.onUnexpectedPlaintext?.call(data);
  return false;
}

// ─── Reliable plaintext dispatch (trusted, decrypted) ─────────────

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
      // Outbound failure here is fine — the original packet has already
      // been logically handled; the sender will retry on their side.
    }
  }

  final type = data['type'];

  // ─── profile_req — remote wants our profile card ───────────────
  if (type == 'profile_req') {
    final lp = ctx.localProfile();
    if (lp == null) return true;
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

  // ─── profile_res — remote returned their profile card ──────────
  if (type == 'profile_res') {
    final p = data['profile'];
    if (p is! Map) return true;
    final pMap = Map<String, Object?>.from(p);
    final avatarRaw = pMap['avatarDataUrl'];

    // Remote avatars are untrusted — validate MIME + size strictly (the
    // validator also rejects data:image/svg+xml which can carry scripts).
    final safeAvatar = safeAvatarDataUrl(avatarRaw);
    if (safeAvatar != null) {
      unawaited(_safelySaveAvatar(remoteId, safeAvatar));
    } else if (avatarRaw == null || avatarRaw == '') {
      // Peer explicitly cleared their avatar — drop the stale cached copy.
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

  // ─── bundle_req / bundle_res — X3DH prekey bundle exchange ─────
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
        // Bundle build failure is non-fatal — remote will retry.
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

  // ─── ack — delivery receipt for an outbound message ────────────
  if (type == 'ack') {
    final ackId = data['id'];
    if (ackId is! String || ackId.isEmpty) return true;
    final row = await db.getMessageById(ackId);
    if (!remoteCanAckOutbound(remoteId, row)) return true;
    ctx.updateMessage(remoteId, ackId, <String, Object?>{
      'delivery': 'delivered',
    });
    ctx.queueAckStatus(ackId, 'delivered');
    return true;
  }

  // ─── game — mini-game piggyback on the reliable channel ────────
  if (type == 'game') {
    try {
      ctx.onGameMessage?.call(remoteId, data['payload']);
    } catch (_) {}
    return true;
  }

  // ─── edit — remote edited an earlier message ───────────────────
  if (type == 'edit') {
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

  // ─── delete — remote tombstones an earlier message ─────────────
  if (type == 'delete') {
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
      // The row might reference a voice OR file blob — we don't know
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

  // ─── msg / text — regular chat message ─────────────────────────
  final typeStr = type is String ? type : '';
  if (typeStr != 'msg' && typeStr != 'text') return false;

  final text = data['text'] is String ? data['text'] as String : '';
  final ts = data['ts'] is num
      ? (data['ts'] as num).toInt()
      : DateTime.now().millisecondsSinceEpoch;
  final fromRaw = data['from'];
  final from = normalizePeerId(fromRaw is String ? fromRaw : remoteId);
  final rawId = data['id'];
  final msgId = (rawId is String && rawId.isNotEmpty)
      ? rawId
      : '$from:$ts:${_randomHex()}';
  final msgType = data['msgType'] is String ? data['msgType'] as String : 'text';
  final sticker = data['sticker'] is Map
      ? Map<String, Object?>.from(data['sticker'] as Map)
      : null;
  final replyTo = data['replyTo'] is Map
      ? Map<String, Object?>.from(data['replyTo'] as Map)
      : null;
  final voiceMeta = data['voice'] is Map
      ? Map<String, Object?>.from(data['voice'] as Map)
      : null;
  final attachmentMeta = data['attachment'] is Map
      ? Map<String, Object?>.from(data['attachment'] as Map)
      : null;

  // De-dup: if we've seen this id before we still owe a fresh ack (remote
  // may have lost ours), but we do not re-persist / re-notify.
  if (ctx.seenMsgIds.contains(msgId)) {
    sendReply(<String, Object?>{
      'type': 'ack',
      'id': msgId,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    return true;
  }
  ctx.seenMsgIds.add(msgId);
  // Clamp: ~4000 max, keep the most recent 2000 on overflow. Matches JS.
  if (ctx.seenMsgIds.length > 4000) {
    final kept = ctx.seenMsgIds
        .toList(growable: false)
        .sublist(ctx.seenMsgIds.length - 2000);
    ctx.seenMsgIds
      ..clear()
      ..addAll(kept);
  }

  unawaited(() async {
    // Belt-and-braces: the in-memory dedup already fired, but if this
    // dispatcher was just re-hydrated from disk a DB row might exist.
    try {
      final existing = await db.getMessageById(msgId);
      if (existing != null) {
        sendReply(<String, Object?>{
          'type': 'ack',
          'id': msgId,
          'ts': DateTime.now().millisecondsSinceEpoch,
        });
        return;
      }
    } catch (_) {}

    // ── Voice meta: decode + persist blob if inline, else metadata-only ──
    JsonMap? voiceRef;
    final transcriptRaw = voiceMeta?['transcript'];
    final transcript =
        transcriptRaw is String ? _clip(transcriptRaw, 2000) : '';
    if (voiceMeta != null && voiceMeta['b64'] is String) {
      try {
        final b64 = voiceMeta['b64'] as String;
        // Anti-OOM (audit finding 4): cap the attacker-controlled base64 length
        // BEFORE decode. Mirrors the send-side gate `_maxVoiceB64Len` (8 MiB)
        // in messaging_notifier.dart. Oversized → treated as bad base64 (falls
        // through to the metadata-only "voice failed" bubble below).
        if (b64.length > 8 * 1024 * 1024) {
          throw const FormatException('voice b64 exceeds inbound cap');
        }
        final bytes = base64Decode(b64);
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
        // Bad base64 — fall through to metadata-only so the bubble can at
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

    // ── Attachment meta: decode + persist blob if inline, else missing:true ──
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
          final bytes = base64Decode(b64);
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
    ctx.pushMessage(remoteId, uiMsg);
    unawaited(db.saveMessage(<String, Object?>{
      'id': msgId,
      'peerId': remoteId,
      'timestamp': ts,
      'direction': 'in',
      'status': 'delivered',
      'payload': <String, Object?>{
        'id': msgId,
        'from': remoteId,
        'to': ctx.selfPeerId,
        'text': text,
        'ts': ts,
        'type': msgType,
        'sticker': sticker,
        'replyTo': replyTo,
        'voice': voiceRef,
        'attachment': attachmentRef,
      },
    }));
    sendReply(<String, Object?>{
      'type': 'ack',
      'id': msgId,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });

    // Side effects — only when app is actually visible, otherwise push /
    // local-notif code is the right channel (handled by notifyNewMessage).
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
  }());

  return true;
}

// ─── Private helpers ──────────────────────────────────────────────

String _clip(String s, int maxChars) =>
    s.length > maxChars ? s.substring(0, maxChars) : s;

int _asInt(Object? v) => v is num ? v.toInt() : 0;

/// Coerce a dynamic list of numerics into `List<double>` waveform
/// amplitudes in 0..1. Matches the JS wire format
/// (`audioRecorder.js::compressSamples` → `Math.min(1, √rms × 2.2)`);
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

/// 64 bits of randomness as 16 hex chars. Only used to break ties on a
/// missing [msgId], never for crypto, so [Random] (not secure) is fine
/// and matches JS's `Math.random().toString(16).slice(2)`.
String _randomHex() {
  final rng = Random();
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
    return emoji is String && emoji.isNotEmpty ? emoji : '🖼 Стикер';
  }
  if (msgType == 'voice') return '🎤 Голосовое';
  if (msgType == 'file') {
    final kind = attachment?['kind'];
    if (kind == 'image') return '🖼 Фото';
    if (kind == 'video') return '🎬 Видео';
    final name = attachment?['name'];
    return '📎 ${name is String && name.isNotEmpty ? name : 'Файл'}';
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

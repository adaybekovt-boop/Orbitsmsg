// Port of `src/hooks/useMessaging.js` вЂ” sendMessage, flushOutbox, typing,
// plus the handful of small utilities the packet router relies on
// (pushInbound, patchMessage, queueAckStatus).
//
// Key departures from the JS source:
//   вЂў Message state lives in Drift, not in-memory. React kept a
//     `messagesByPeer` map so useState rerendered the chat list on every
//     insert. Dart reads the chat stream straight from the DB via
//     `messagesForPeerProvider`, which means mutations here just call
//     `db.saveMessage` / `db.updateMessage` вЂ” the UI auto-updates without
//     any local state mirror.
//   вЂў The only thing we do keep in-notifier state is `typingByPeer`, since
//     typing indicators are transient, UI-only, and have no persistence
//     story.
//   вЂў Text / sticker / voice / file all land through distinct `sendX`
//     entry points. Inbound for all four dispatches through the packet
//     router into `pushInbound` вЂ” display is the responsibility of the
//     chat page, not this notifier.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_reporter.dart';
import '../core/path_byte_stream.dart';
import '../utils/heavy_codec.dart';

import '../messaging/lost_inbound_ledger.dart';
import '../messaging/message_protocol.dart' show InboundPersistResult;
import '../messaging/sent_ack_guard.dart';
import '../peer/helpers.dart';
import '../storage/db.dart' as db;
import 'auth_notifier.dart';
import 'connections_notifier.dart';
import 'local_profile_provider.dart';
import 'peers_provider.dart';

/// Fire a best-effort DB write without awaiting, but surface failures
/// instead of swallowing them. Release builds get a structured error payload
/// through `error_reporter` (audit Round 5 B.5) вЂ” debug builds additionally
/// print.
void _persistBestEffort(Future<Object?> write, String what) {
  unawaited(write.catchError((Object e, StackTrace st) {
    reportError(e, <String, Object?>{
      'source': 'messaging.persist',
      'what': what,
    });
    if (kDebugMode) {
      // ignore: avoid_print
      print('[messaging] persist failed ($what): $e');
    }
    return null;
  }));
}

// Hard caps вЂ” match JS byte-for-byte so a round-trip between web and native
// clients never truncates on one side and passes on the other.
//
// The voice/file caps come in two flavours:
//   *RawBytes is the pre-encode cap (what the recorder / picker produced).
//   *B64Len  is the post-encode cap (the base64 string on the wire).
// We check both вЂ” raw at the caller so we can fail fast before paying the
// base64 encode, b64 on the wire envelope so a pathological compressor
// can't slip past the raw check and still blow out the receiver's clamp.
const int _maxTextLen = 32 * 1024;
const int _maxStickerLen = 512 * 1024;
const int _maxVoiceRawBytes = 6 * 1024 * 1024; // ~8 MiB base64
const int _maxVoiceB64Len = 8 * 1024 * 1024;
const int _maxFileRawBytes = 12 * 1024 * 1024; // JS UI gate (Chats.jsx:822)
const int _maxFileB64Len = 16 * 1024 * 1024;
const int _maxFileThumbLen = 48 * 1024;
const int _maxFileNameLen = 200; // JS: messageProtocol.js:347

// в”Ђв”Ђв”Ђ State в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

class MessagingState {
  const MessagingState({
    this.typingByPeer = const <String, bool>{},
    this.lostInboundCount = 0,
  });

  /// Peer в†’ isTyping. Entries are added when a typing packet arrives and
  /// removed when the peer sends `{isTyping: false}` or a message. The map
  /// is intentionally tiny вЂ” typing indicators expire on their own, we
  /// don't keep history.
  final Map<String, bool> typingByPeer;

  /// Inbound messages dropped because persisting them failed (typically the
  /// vault being locked вЂ” audit Round 5 B.5). The UI can surface this as
  /// "СЃРѕРѕР±С‰РµРЅРёСЏ РјРѕРіР»Рё РїСЂРёР№С‚Рё, РїРѕРєР° РїСЂРёР»РѕР¶РµРЅРёРµ Р±С‹Р»Рѕ Р·Р°Р±Р»РѕРєРёСЂРѕРІР°РЅРѕ" instead of
  /// a silently empty chat.
  final int lostInboundCount;

  MessagingState copyWith({
    Map<String, bool>? typingByPeer,
    int? lostInboundCount,
  }) =>
      MessagingState(
        typingByPeer: typingByPeer ?? this.typingByPeer,
        lostInboundCount: lostInboundCount ?? this.lostInboundCount,
      );
}

// в”Ђв”Ђв”Ђ Notifier в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

class MessagingNotifier extends StateNotifier<MessagingState> {
  MessagingNotifier(this._ref) : super(const MessagingState()) {
    // Register ourselves with the connections registry so the packet router
    // can push inbound messages back in. Done here (not in the provider
    // factory) so the bridge is live the moment this notifier exists.
    _ref.read(connectionsNotifierProvider.notifier).bindMessaging(
          MessagingBridge(
            pushInbound: pushInbound,
            patchMessage: patchMessage,
            queueAckStatus: queueAckStatus,
            flushOutboxForPeer: flushOutboxForPeer,
            loadPendingForPeer: loadPendingForPeer,
            applyTyping: applyTyping,
            isPeerBlocked: isPeerBlocked,
          ),
        );

    // Keep a tight in-memory mirror of the `blocked` column so the hot-path
    // packet-router check (`_isPeerBlocked`) is synchronous. Reading off
    // `peersProvider.asData?.value` every call worked too, but it lagged
    // the Drift emit by a microtask вЂ” a malicious peer could squeeze a
    // single packet through the gap between the user tapping "block" and
    // the stream re-emitting. This listener closes that race: the moment
    // `setPeerBlocked(true)` runs a write, the stream wakes, this callback
    // fires, and the id lands in `_blockedIds` *before* the next inbound
    // packet can be dispatched to us.
    //
    // Bonus: we also use the transition (peer flipped `false в†’ true`) to
    // clear any lingering typing bubble + idle timer for that peer so the
    // "РїРµС‡Р°С‚Р°РµС‚вЂ¦" indicator doesn't float above the block banner for the
    // full 8 s safety window.
    _peersSub = _ref.listen<AsyncValue<List<Map<String, Object?>>>>(
      peersProvider,
      (prev, next) {
        final rows = next.asData?.value;
        if (rows == null) return;
        final nextBlocked = <String>{};
        for (final r in rows) {
          final id = r['id'] as String?;
          if (id == null || id.isEmpty) continue;
          final b = r['blocked'];
          if (b == true || (b is num && b.toInt() == 1)) {
            nextBlocked.add(id);
          }
        }
        // Detect newly-blocked peers so we can flush their typing state.
        final newlyBlocked = nextBlocked.difference(_blockedIds);
        _blockedIds
          ..clear()
          ..addAll(nextBlocked);
        if (newlyBlocked.isEmpty || !mounted) return;
        var typing = Map<String, bool>.from(state.typingByPeer);
        var changed = false;
        for (final id in newlyBlocked) {
          _typingIdleTimers.remove(id)?.cancel();
          if (typing.remove(id) != null) changed = true;
        }
        if (changed) state = state.copyWith(typingByPeer: typing);
      },
      fireImmediately: true,
    );

    // Sign-out hygiene: drop volatile session state so it can't bleed into the
    // next account (audit H4). The persisted blocked column is mirrored back
    // off `peersProvider`, but typing bubbles + their idle timers live only in
    // memory and would otherwise survive a logoutв†’login.
    _ref.listen<AuthState>(
      authNotifierProvider,
      (prev, next) {
        if (prev is AuthAuthed && next is! AuthAuthed) {
          for (final t in _typingIdleTimers.values) {
            t.cancel();
          }
          _typingIdleTimers.clear();
          _blockedIds.clear();
          _lostInbound.reset();
          if (mounted) state = const MessagingState();
        }
      },
    );

    // R06: `sent`/`inflight` rows do not survive in-memory timers. Demote
    // them back to `pending` so the next reliable-open flush retries.
    unawaited(db.recoverUnconfirmedOutbound());
  }

  final Ref _ref;
  final Random _rand = Random.secure();

  /// Accounts every inbound message lost to a failed persist (locked vault,
  /// DB error) and reports it through error_reporter вЂ” release included
  /// (audit Round 5 B.5).
  final LostInboundLedger _lostInbound = LostInboundLedger();

  /// Current local peer id, or `''` when the session hasn't initialised
  /// yet. Exposed as a synchronous getter so widgets that decide "is this
  /// bubble mine?" (e.g. reply preview self-vs-other resolution) don't
  /// need to depend on `local_profile_provider` directly.
  String get currentSelfIdOrEmpty =>
      _ref.read(currentPeerIdProvider) ?? '';

  /// Synchronously-updated mirror of `peers.blocked=1`. Kept in sync with
  /// `peersProvider` via the `ref.listen` subscription set up in the ctor.
  /// Read from the packet router's hot path so `pushInbound` can reject
  /// blocked senders without awaiting a DB round-trip.
  final Set<String> _blockedIds = <String>{};

  /// Handle on the `peersProvider` listener so we can detach in `dispose`.
  /// Riverpod's `ref.listen` returns a `ProviderSubscription` that must be
  /// closed explicitly вЂ” leaving it alive would leak the notifier's state
  /// into the next login cycle after logout / hot reload.
  late final ProviderSubscription _peersSub;

  /// Per-peer "typing stuck" safety timer. Without this a lost `typing=false`
  /// packet (remote crashed mid-type, ephemeral channel died, app went to
  /// background) would pin the В«РїРµС‡Р°С‚Р°РµС‚вЂ¦В» bubble forever. 8 s is just over
  /// the composer's own 3 s idle вЂ” a peer that keeps typing past their own
  /// stop-sentinel keeps re-arming this timer with each fresh `true`, so we
  /// only ever auto-clear truly silent peers.
  final Map<String, Timer> _typingIdleTimers = <String, Timer>{};

  // в”Ђв”Ђв”Ђ Ack queue в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// Batched ack persistence. When a peer dumps 30 msgs on reconnect we
  /// don't want 30 separate DB writes вЂ” collect idв†’status pairs for up to
  /// 450 ms, then fire one bulk update per status class.
  final Map<String, String> _ackBuffer = {};
  Timer? _ackTimer;

  /// Ack-timeout guard for outbound rows we just flipped to `'sent'`
  /// (audit Round 5 A.2). `dc.send()` only means "buffered on the wire" вЂ”
  /// if the receiver's ack never lands before the deadline, the row is
  /// demoted back to `'pending'` so the outbox re-sends it instead of
  /// stranding it in `'sent'` forever.
  late final SentAckGuard _sentAckGuard = SentAckGuard(
    timeout: sentAckTimeout,
    onDemote: (msgId) async {
      if (!mounted) return;
      try {
        final row = await db.getMessageById(msgId);
        // Only demote rows that are STILL un-acked `'sent'`. Anything else
        // ('pending' from a concurrent path, 'delivered'/'read' from a late
        // ack) is left untouched.
        final st = row?['status'];
        if (row != null && (st == 'sent' || st == 'inflight')) {
          await db.updateMessageStatus(msgId, 'pending');
        }
      } catch (_) {
        // DB unavailable вЂ” nothing smarter to do; the next flush trigger
        // re-reads pending state anyway.
      }
    },
  );

  /// Deadline between "we handed the envelope to the transport" and
  /// "receiver must have acked". Exposed so tests can shorten it.
  Duration sentAckTimeout = const Duration(seconds: 30);

  /// Enqueue a delivery/sent ack for [msgId]. [status] is either
  /// `'delivered'` or `'sent'`.
  void queueAckStatus(String msgId, String status) {
    if (msgId.isEmpty) return;
    final norm = status.isEmpty ? 'delivered' : status;
    // Any receiver ack confirms transport-level delivery вЂ” cancel the
    // demotion deadline for this outbound row (audit Round 5 A.2).
    _sentAckGuard.confirm(msgId);
    _ackBuffer[msgId] = norm;
    _ackTimer ??= Timer(const Duration(milliseconds: 450), _flushAckBuffer);
  }

  Future<void> _flushAckBuffer() async {
    _ackTimer = null;
    if (_ackBuffer.isEmpty) return;
    final batch = Map<String, String>.from(_ackBuffer);
    _ackBuffer.clear();

    final delivered = <String>[];
    final sent = <String>[];
    for (final e in batch.entries) {
      if (e.value == 'sent') {
        sent.add(e.key);
      } else {
        delivered.add(e.key);
      }
    }
    try {
      if (delivered.isNotEmpty) {
        await db.updateMessageStatusesBatch(delivered, 'delivered');
      }
      if (sent.isNotEmpty) {
        await db.updateMessageStatusesBatch(sent, 'sent');
      }
    } catch (_) {
      // Failure is survivable вЂ” worst case, UI shows stale "sending" dots
      // until the peer repeats an ack or we restart.
    }
  }

  // в”Ђв”Ђв”Ђ Inbound side в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// Persist a freshly-arrived message and bump the peer's lastSeenAt.
  /// The chat page's message stream picks up the Drift insert on the next
  /// tick, so there's no explicit UI notify here.
  ///
  /// Blocked peers: packet is silently dropped вЂ” no DB write, no
  /// lastSeenAt bump, no typing state leaks. The remote can't distinguish
  /// "blocked" from "offline" which is the intended UX. If the user later
  /// unblocks, messages arriving after that point come through normally;
  /// anything they sent while blocked is gone.
  Future<InboundPersistResult> pushInbound(
    String remoteId,
    Map<String, Object?> uiMsg,
  ) async {
    final normalized = normalizePeerId(remoteId);
    if (normalized.isEmpty) return InboundPersistResult.failed;
    if (_isPeerBlocked(normalized)) return InboundPersistResult.blocked;

    final safe = _clampChatMessage(Map<String, Object?>.from(uiMsg));
    final ts = (safe['ts'] as num?)?.toInt() ?? now();
    final msgId = (safe['id'] as String?) ?? '$normalized:$ts:${_shortId()}';

    try {
      await db.saveMessage({
        'id': msgId,
        'peerId': normalized,
        'timestamp': ts,
        'direction': 'in',
        'status': 'delivered',
        'payload': safe,
      });
    } catch (e) {
      _lostInbound.recordDrop(msgId: msgId, fromPeer: normalized, error: e);
      if (mounted) {
        state = state.copyWith(
          lostInboundCount: state.lostInboundCount + 1,
        );
      }
      return InboundPersistResult.failed;
    }

    _persistBestEffort(
      db.savePeer({'id': normalized, 'lastSeenAt': now()}),
      'inbound savePeer $normalized',
    );
    return InboundPersistResult.committed;
  }

  /// Exposed so the packet router can refuse traffic from a blocked peer
  /// before decrypt / Drop / heartbeat.
  bool isPeerBlocked(String peerId) => _isPeerBlocked(normalizePeerId(peerId));

  /// Synchronous block check off the in-memory `_blockedIds` mirror. The
  /// ctor's `ref.listen` keeps this set in lockstep with every Drift emit,
  /// so by the time control returns from `setPeerBlocked(true)` the write
  /// has landed *and* this set already contains the id. That closes the
  /// microtask race the `_ref.read(peersProvider).asData?.value` version
  /// had, where a packet dispatched between the DB write and the stream
  /// re-emit would see a stale "false" and leak through.
  bool _isPeerBlocked(String normalizedPeerId) =>
      _blockedIds.contains(normalizedPeerId);

  /// Patch an existing message row (delivery/edit/delete). Writes straight
  /// through to Drift; the message stream rebuilds the chat on next tick.
  void patchMessage(
    String remoteId,
    String msgId,
    Map<String, Object?> patch,
  ) {
    if (msgId.isEmpty) return;
    // Normalize `delivery: 'sent'|'delivered'|'read'` into the DB's `status`
    // column so the message stream renders the right tick.
    final mapped = <String, Object?>{...patch};
    final delivery = patch['delivery'];
    if (delivery is String && delivery.isNotEmpty) {
      mapped['status'] = delivery;
    }
    unawaited(db.updateMessage(msgId, mapped));
  }

  // в”Ђв”Ђв”Ђ Typing в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  void applyTyping(String remoteId, bool isTyping) {
    // Packets in flight when the notifier is torn down (logout, hot
    // reload) must not reach `state=` вЂ” that throws after dispose. The
    // bridge reset in `dispose()` covers the common path; this is a
    // belt-and-suspenders guard for in-flight callbacks.
    if (!mounted) return;
    final normalized = normalizePeerId(remoteId);
    if (normalized.isEmpty) return;
    // Blocked peers shouldn't surface a typing bubble either вЂ” the chat
    // view is hidden behind the block banner, but a stale В«РїРµС‡Р°С‚Р°РµС‚вЂ¦В»
    // floating above it would be confusing.
    if (_isPeerBlocked(normalized)) return;

    // Any new packet for this peer retires the previous safety timer вЂ” a
    // `false` came through (happy path) or a fresh `true` resets the 8 s
    // deadline (still actively typing).
    _typingIdleTimers.remove(normalized)?.cancel();

    final next = Map<String, bool>.from(state.typingByPeer);
    if (isTyping) {
      next[normalized] = true;
      _typingIdleTimers[normalized] = Timer(
        const Duration(seconds: 8),
        () => _expireTyping(normalized),
      );
    } else {
      next.remove(normalized);
    }
    state = state.copyWith(typingByPeer: next);
  }

  /// Force-clear a peer's typing flag if the safety timer fires before a
  /// real `typing=false` arrived. Rechecks current state first so a just-
  /// landed clear (via a fresh packet or `applyTyping(false)`) doesn't get
  /// clobbered by a stale timer callback. Also bails if the notifier was
  /// disposed between scheduling and firing вЂ” `Timer.cancel()` races with
  /// already-queued callbacks, so we can't rely on dispose alone.
  void _expireTyping(String normalized) {
    _typingIdleTimers.remove(normalized);
    if (!mounted) return;
    if (state.typingByPeer[normalized] != true) return;
    final next = Map<String, bool>.from(state.typingByPeer)
      ..remove(normalized);
    state = state.copyWith(typingByPeer: next);
  }

  /// Send an ephemeral typing packet to [remoteId]. No-op if there's no
  /// ephemeral channel open вЂ” typing indicators are best-effort.
  /// Skips blocked peers on both directions (nothing in, nothing out).
  Future<void> sendTyping(String remoteId, bool isTyping) async {
    final normalized = normalizePeerId(remoteId);
    if (normalized.isEmpty) return;
    if (_isPeerBlocked(normalized)) return;
    await _ref.read(connectionsNotifierProvider.notifier).sendEphemeral(
      normalized,
      {'type': 'typing', 'isTyping': isTyping, 'ts': now()},
    );
  }

  // в”Ђв”Ђв”Ђ Outbox в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// Pull the persisted pending rows for [remoteId]. The JS version kept
  /// an in-memory mirror (`outboxByPeer`) for the UI; Dart reads the
  /// reactive `pendingForPeerProvider` stream instead, so this is a no-op
  /// except for its side effect of "refresh peer's lastSeenAt when the
  /// chat opens" which isn't needed here. Kept for API parity so the
  /// packet router's `loadPendingForPeer` hook has a target.
  Future<void> loadPendingForPeer(String remoteId) async {
    // Intentionally empty. See comment above.
  }

  /// Drain the pending queue for a single peer. Called on reliable-open and
  /// when the user taps "retry" on a stuck message.
  /// Blocked peers: skip entirely вЂ” user flipped the block toggle, their
  /// pending queue stays on disk but we don't fire it. A future unblock
  /// will let the next trigger drain it.
  ///
  /// Voice/file/sticker retries rehydrate the wire payload from the blob
  /// tables: the original sender saved the raw bytes into `voice_blobs` /
  /// `file_blobs` under the msgId, so we can rebuild the envelope without
  /// asking the recorder / picker to keep state across the reconnect
  /// window. Sticker payloads live inline in `payload.sticker` and need
  /// no re-encode. If a blob has been evicted (e.g. user cleared chat
  /// storage), the row stays `pending` forever вЂ” we skip it rather than
  /// ship a broken envelope with a missing `b64`.
  Future<void> flushOutboxForPeer(String remoteId) async {
    final normalized = normalizePeerId(remoteId);
    if (normalized.isEmpty) return;
    if (_isPeerBlocked(normalized)) return;
    final conns = _ref.read(connectionsNotifierProvider.notifier);
    if (!_readyToShip(conns, normalized)) return;

    List<Map<String, Object?>> rows;
    try {
      rows = await db.getPendingMessages(peerId: normalized, limit: 200);
    } catch (_) {
      return;
    }
    if (rows.isEmpty) return;

    for (final r in rows) {
      final id = r['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final payloadRaw = r['payload'];
      final payload = payloadRaw is Map
          ? Map<String, Object?>.from(payloadRaw)
          : null;
      if (payload == null) continue;
      final type = (payload['type'] as String?) ?? 'text';

      if (type == 'file') {
        final att = payload['attachment'];
        if (att is Map && att['chunked'] == true) {
          final streamed = await _flushChunkedNativeFile(
            conns,
            normalized,
            id,
            payload,
          );
          if (!streamed) {
            unawaited(db.updateMessageStatus(id, 'failed'));
            continue;
          }
          unawaited(db.updateMessage(id, {
            'status': 'inflight',
            'outboxAttempt': ((r['outboxAttempt'] as num?)?.toInt() ?? 0) + 1,
            'outboxDeadline': now() + sentAckTimeout.inMilliseconds,
          }));
          _sentAckGuard.arm(id);
          continue;
        }
      }
      final envelope = await _buildOutboxEnvelope(id, payload, type);
      if (envelope == null) {
        // Row isn't recoverable вЂ” the underlying blob went missing
        // (chat storage cleared, DB migrated), b64 overshoots the wire
        // cap, or the payload is too corrupt to reassemble. Dead-letter
        // the row so the bubble stops showing the clock-icon forever:
        // MessageBubble already renders 'failed' as the broken-mic /
        // missing-attachment state, and the notifier will stop
        // re-flushing it on every reconnect.
        //
        // We don't delete the DB row вЂ” keeping it lets the user
        // long-press-delete in the UI, and lets a later "retry all"
        // flow pick it back up if the blob is somehow recovered.
        unawaited(db.updateMessageStatus(id, 'failed'));
        continue;
      }
      final ok = await conns.sendEncrypted(normalized, envelope);
      if (!ok) break;
      unawaited(db.updateMessage(id, {
        'status': 'inflight',
        'outboxAttempt': ((r['outboxAttempt'] as num?)?.toInt() ?? 0) + 1,
        'outboxDeadline': now() + sentAckTimeout.inMilliseconds,
      }));
      _sentAckGuard.arm(id);
    }
  }

  /// Build a wire-shape envelope for a pending row of [type]. Returns
  /// null if the row is unrecoverable (missing blob, malformed payload).
  ///
  /// This re-reads the persisted blob rather than trusting the payload
  /// to carry `b64` вЂ” the send path deliberately strips `b64` from the
  /// stored `payload.voice` / `payload.attachment` to keep the messages-
  /// table lean (voice_blobs / file_blobs hold the bytes, indexed by id).
  Future<Map<String, Object?>?> _buildOutboxEnvelope(
    String msgId,
    Map<String, Object?> payload,
    String type,
  ) async {
    final replyTo = payload['replyTo'];
    final common = <String, Object?>{
      'type': 'msg',
      'id': msgId,
      'text': (payload['text'] as String?) ?? '',
      'ts': payload['ts'],
      'from': payload['from'],
      if (replyTo is Map) 'replyTo': Map<String, Object?>.from(replyTo),
    };

    switch (type) {
      case 'text':
        return common;

      case 'sticker':
        final sticker = payload['sticker'];
        if (sticker is! Map) return null;
        return <String, Object?>{
          ...common,
          'msgType': 'sticker',
          'sticker': Map<String, Object?>.from(sticker),
        };

      case 'voice':
        final voice = payload['voice'];
        if (voice is! Map) return null;
        final blob = await db.getVoiceBlob(msgId);
        if (blob == null) return null;
        final bytes = blob['blob'];
        if (bytes is! Uint8List || bytes.isEmpty) return null;
        final b64 = await b64EncodeHeavy(bytes);
        if (b64.length > _maxVoiceB64Len) return null;
        final voiceMap = Map<String, Object?>.from(voice);
        return <String, Object?>{
          ...common,
          'msgType': 'voice',
          'voice': <String, Object?>{
            'duration': voiceMap['duration'] ?? 0,
            'mime': voiceMap['mime'] ?? 'audio/webm',
            'waveform': voiceMap['waveform'] ?? const <double>[],
            'transcript': voiceMap['transcript'] ?? '',
            'b64': b64,
          },
        };

      case 'file':
        final att = payload['attachment'];
        if (att is! Map) return null;
        final blob = await db.getFileBlob(msgId);
        if (blob == null) return null;
        final bytes = blob['blob'];
        if (bytes is! Uint8List || bytes.isEmpty) return null;
        final b64 = await b64EncodeHeavy(bytes);
        if (b64.length > _maxFileB64Len) return null;

        // Prefer the thumb data URL we persisted in the payload (cheap);
        // fall back to rebuilding from the raw bytes in file_blobs.thumb
        // if the payload lost it (e.g. an older row predating the Day-4
        // send path). Either way we re-check the size cap so a
        // round-tripped thumb can't blow out the wire clamp.
        final attMap = Map<String, Object?>.from(att);
        String? thumbDataUrl;
        final storedThumbUrl = attMap['thumb'];
        if (storedThumbUrl is String &&
            storedThumbUrl.isNotEmpty &&
            storedThumbUrl.length <= _maxFileThumbLen) {
          thumbDataUrl = storedThumbUrl;
        } else {
          final thumbBytes = blob['thumb'];
          if (thumbBytes is Uint8List && thumbBytes.isNotEmpty) {
            final candidate =
                'data:image/jpeg;base64,${base64Encode(thumbBytes)}';
            if (candidate.length <= _maxFileThumbLen) {
              thumbDataUrl = candidate;
            }
          }
        }

        return <String, Object?>{
          ...common,
          'msgType': 'file',
          'attachment': <String, Object?>{
            'name': attMap['name'] ?? 'file',
            'size': attMap['size'] ?? bytes.length,
            'mime': attMap['mime'] ?? 'application/octet-stream',
            'kind': attMap['kind'] ?? 'file',
            'thumb': thumbDataUrl,
            'width': attMap['width'] ?? 0,
            'height': attMap['height'] ?? 0,
            'duration': attMap['duration'] ?? 0,
            'b64': b64,
          },
        };
    }
    return null;
  }

  bool _readyToShip(ConnectionsNotifier conns, String peerId) =>
      conns.hasReliable(peerId) || conns.canDepositMailbox(peerId);

  List<int> _freshFileKey() {
    final rng = Random.secure();
    return List<int>.generate(32, (_) => rng.nextInt(256));
  }

  Future<bool> _flushChunkedNativeFile(
    ConnectionsNotifier conns,
    String peerId,
    String msgId,
    Map<String, Object?> payload,
  ) async {
    if (!conns.canUseNative(peerId)) return false;
    final att = payload['attachment'];
    if (att is! Map) return false;
    final path = att['localPath'];
    if (path is! String || path.isEmpty) return false;
    final fileId = (att['fileId'] as String?) ?? msgId;
    final fileKey = _freshFileKey();
    final streamed = await conns.sendChatAttachmentFromPath(
      peerId,
      path,
      fileKey: fileKey,
      fileId: fileId,
    );
    if (!streamed) return false;
    return conns.sendEncrypted(peerId, {
      'type': 'msg',
      'id': msgId,
      'text': (payload['text'] as String?) ?? '',
      'ts': payload['ts'],
      'from': payload['from'],
      'msgType': 'file',
      'attachment': <String, Object?>{
        'name': att['name'] ?? 'file',
        'size': att['size'] ?? 0,
        'mime': att['mime'] ?? 'application/octet-stream',
        'kind': att['kind'] ?? 'file',
        'thumb': att['thumb'],
        'width': att['width'] ?? 0,
        'height': att['height'] ?? 0,
        'duration': att['duration'] ?? 0,
        'chunked': true,
        'fileId': fileId,
        'fileKeyB64': base64Encode(fileKey),
      },
      if (payload['replyTo'] is Map)
        'replyTo': Map<String, Object?>.from(payload['replyTo'] as Map),
    });
  }

  // sendText (MVP path)

  /// Send a plain text message to [targetId]. Returns the generated message
  /// id on success, null on validation failure. Does NOT wait for delivery;
  /// the ack will flip the DB row's status asynchronously.
  /// Refuses to send to blocked peers вЂ” the composer is hidden in the UI
  /// when blocked, but this is the defence-in-depth check so a programmatic
  /// call path can't bypass it.
  ///
  /// [replyTo] is the quoted-message metadata the UI attaches when the user
  /// taps "РћС‚РІРµС‚РёС‚СЊ" on a peer's bubble. It's a free-form map mirroring the
  /// JS shape (`{id, from, fromName, type, text, stickerEmoji, ...}`) вЂ” we
  /// clamp only the free-text fields so a pathological reply blob can't
  /// bloat the persisted payload, and pass everything else through. The
  /// protocol side just echoes it back on the wire; the bubble reads it
  /// off `payload.replyTo`.
  Future<String?> sendText(
    String targetId,
    String text, {
    Map<String, Object?>? replyTo,
  }) async {
    final normalized = normalizePeerId(targetId);
    if (!isValidPeerId(normalized)) return null;
    if (_isPeerBlocked(normalized)) return null;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.length > _maxTextLen) return null;

    final selfId = _ref.read(currentPeerIdProvider) ?? '';
    if (selfId.isEmpty) return null;

    final ts = now();
    final msgId = '$selfId:$ts:${_shortId()}';
    final conns = _ref.read(connectionsNotifierProvider.notifier);
    final open = _readyToShip(conns, normalized);

    final sanitizedReply = _sanitizeReplyTo(replyTo);

    // Persist the outbound row first — pending status if the channel's
    // offline, sent otherwise. On refresh/app-restart the outbox picks up
    // pending rows from here.
    //
    // Historically we also mirrored the `delivery` state into the payload
    // JSON so the UI could read either field; that created a drift risk
    // because later mutations (e.g. `updateMessageStatus`) only touched
    // the `status` column, not the embedded mirror. The outbox mapper
    // (`pendingRowToOutboxEntry`) always hardcodes `'delivery': 'queued'`
    // on read, so the mirror was dead weight anyway. Status column is
    // the single source of truth now.
    final payload = <String, Object?>{
      'id': msgId,
      'from': selfId,
      'to': normalized,
      'text': trimmed,
      'ts': ts,
      'type': 'text',
      if (sanitizedReply != null) 'replyTo': sanitizedReply,
    };
    await db.saveMessage({
      'id': msgId,
      'peerId': normalized,
      'timestamp': ts,
      'direction': 'out',
      'status': 'pending',
      'payload': payload,
    });

    // Freshen the peer's lastSeenAt so the chat rises to the top of the
    // chat list as soon as the user hits send.
    unawaited(db.savePeer({'id': normalized, 'lastSeenAt': now()}));

    if (!open) {
      // Nothing to ship right now вЂ” the flusher will pick this up when the
      // reliable channel opens.
      return msgId;
    }

    final ok = await conns.sendEncrypted(normalized, {
      'type': 'msg',
      'id': msgId,
      'text': trimmed,
      'ts': ts,
      'from': selfId,
      if (sanitizedReply != null) 'replyTo': sanitizedReply,
    });
    if (!ok) {
      _sentAckGuard.disarm(msgId);
      unawaited(db.updateMessageStatus(msgId, 'pending'));
    } else {
      unawaited(db.updateMessage(msgId, {
        'status': 'inflight',
        'outboxAttempt': 1,
        'outboxDeadline': now() + sentAckTimeout.inMilliseconds,
      }));
      _sentAckGuard.arm(msgId);
    }
    return msgId;
  }

  // в”Ђв”Ђв”Ђ sendSticker в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// Send a sticker to [targetId]. [sticker] mirrors the shape the JS
  /// sticker picker produces: `{packId, packName, stickerId, url, emoji}`.
  /// Returns the generated message id on success, null on validation
  /// failure.
  ///
  /// The wire + persistence path piggybacks on the regular chat-message
  /// envelope вЂ” `msgType='sticker'`, `text=''`, and the sticker blob rides
  /// in `payload.sticker`. This matches `message_protocol.dart`'s inbound
  /// path so a sticker we send round-trips identically to one the peer
  /// sends us. Outbox currently only retries text; if the reliable channel
  /// is closed at send time we persist the row as `pending` and it will
  /// surface in the UI with the clock icon until the user manually retries
  /// after the channel reopens (the flusher's sticker branch is a Day 4
  /// item, noted at flushOutboxForPeer).
  Future<String?> sendSticker(
    String targetId,
    Map<String, Object?> sticker, {
    Map<String, Object?>? replyTo,
  }) async {
    final normalized = normalizePeerId(targetId);
    if (!isValidPeerId(normalized)) return null;
    if (_isPeerBlocked(normalized)) return null;

    // Minimal shape validation вЂ” a malformed sticker (missing url or
    // stickerId) would render as a blank bubble on the receiver.
    final url = sticker['url'];
    final stickerId = sticker['stickerId'];
    if (url is! String || url.isEmpty) return null;
    if (stickerId is! String || stickerId.isEmpty) return null;
    if (url.length > _maxStickerLen) return null;

    final selfId = _ref.read(currentPeerIdProvider) ?? '';
    if (selfId.isEmpty) return null;

    final ts = now();
    final msgId = '$selfId:$ts:${_shortId()}';
    final conns = _ref.read(connectionsNotifierProvider.notifier);
    final open = _readyToShip(conns, normalized);

    // Clamp free-text fields on the sticker blob itself (packName, emoji,
    // label) so a custom pack with 100KB of text fields can't blow up the
    // persisted row. The size cap on `url` above already bounds the big
    // field.
    final sanitizedSticker = <String, Object?>{
      'stickerId': stickerId,
      'url': url,
      'packId': _clipField(sticker['packId'], 64) ?? '',
      'packName': _clipField(sticker['packName'], 64) ?? '',
      'emoji': _clipField(sticker['emoji'], 16) ?? '',
      'label': _clipField(sticker['label'], 64) ?? '',
    };
    final sanitizedReply = _sanitizeReplyTo(replyTo);

    final payload = <String, Object?>{
      'id': msgId,
      'from': selfId,
      'to': normalized,
      'text': '',
      'ts': ts,
      'type': 'sticker',
      'sticker': sanitizedSticker,
      if (sanitizedReply != null) 'replyTo': sanitizedReply,
    };
    await db.saveMessage({
      'id': msgId,
      'peerId': normalized,
      'timestamp': ts,
      'direction': 'out',
      'status': 'pending',
      'payload': payload,
    });

    unawaited(db.savePeer({'id': normalized, 'lastSeenAt': now()}));

    if (!open) return msgId;

    final ok = await conns.sendEncrypted(normalized, {
      'type': 'msg',
      'id': msgId,
      'text': '',
      'ts': ts,
      'from': selfId,
      'msgType': 'sticker',
      'sticker': sanitizedSticker,
      if (sanitizedReply != null) 'replyTo': sanitizedReply,
    });
    if (!ok) {
      _sentAckGuard.disarm(msgId);
      unawaited(db.updateMessageStatus(msgId, 'pending'));
    } else {
      _sentAckGuard.arm(msgId);
    }
    return msgId;
  }

  // в”Ђв”Ђв”Ђ sendVoice в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// Send a voice message to [targetId]. Mirrors `sendSticker` / `sendText`
  /// for the persist-first + ship-if-open pattern; the raw audio bytes go
  /// into `voice_blobs` keyed by msgId so the flusher can rehydrate them
  /// on reconnect without asking the recorder to hold the recording in
  /// memory. Returns the generated message id on success, `null` on
  /// validation failure (blocked peer, invalid id, oversize, missing
  /// metadata).
  ///
  /// Size gate runs in two places: the raw-bytes cap below (fail fast,
  /// before we pay base64), and a b64 cap on the wire envelope just
  /// before send (the receiver's `_clampChatMessage` also rechecks it).
  ///
  /// [waveform] is в‰¤48 normalized doubles in 0..1. The recorder should
  /// already have compressed to that shape (`compressSamples` in the JS
  /// version). We don't re-compress here, but we do clamp values
  /// defensively so a pathological recorder can't coax a 1000-unit-tall
  /// bar past the UI.
  Future<String?> sendVoice(
    String targetId,
    Uint8List bytes, {
    required String mime,
    required double durationSec,
    required List<double> waveform,
    String transcript = '',
    Map<String, Object?>? replyTo,
  }) async {
    final normalized = normalizePeerId(targetId);
    if (!isValidPeerId(normalized)) return null;
    if (_isPeerBlocked(normalized)) return null;
    if (bytes.isEmpty) return null;
    if (bytes.length > _maxVoiceRawBytes) return null;
    if (mime.isEmpty) return null;
    if (durationSec < 0) return null;

    final selfId = _ref.read(currentPeerIdProvider) ?? '';
    if (selfId.isEmpty) return null;

    final ts = now();
    final msgId = '$selfId:$ts:${_shortId()}';
    final conns = _ref.read(connectionsNotifierProvider.notifier);
    final open = _readyToShip(conns, normalized);

    // Defensive clamp вЂ” recorder should produce values in 0..1 already,
    // but a broken input doesn't get to push the UI past that range.
    final safeWaveform = <double>[
      for (final v in waveform) v.isNaN ? 0.0 : v.clamp(0.0, 1.0).toDouble(),
    ];
    final safeTranscript =
        transcript.length > 2000 ? transcript.substring(0, 2000) : transcript;
    final sanitizedReply = _sanitizeReplyTo(replyTo);

    // Persist the blob first. Matches the inbound decoder's shape so an
    // own-sent voice row renders identically to one the peer sent us
    // (both ends read from voice_blobs via the same getVoiceBlob API).
    await db.saveVoiceBlob(
      msgId,
      bytes,
      mime: mime,
      duration: durationSec.toInt(),
      waveform: safeWaveform,
    );

    // Inline voice ref on the message payload вЂ” no b64 here, the bubble
    // reads the bytes from voice_blobs on play. Matches the inbound
    // decoder's `voiceRef` at message_protocol.dart:533-538.
    //
    // `duration` stays a double (seconds, 1-decimal precision) to match
    // the JS wire convention. Rounding to int here вЂ” as we used to do вЂ”
    // collapsed 0.3 s messages to 0 s and silently demoted the second
    // send of the same msgId (the outbox retry) to a different field
    // type than the first send, since the flusher re-reads this map.
    final voiceRef = <String, Object?>{
      'duration': durationSec,
      'mime': mime,
      'waveform': safeWaveform,
      'transcript': safeTranscript,
    };
    final payload = <String, Object?>{
      'id': msgId,
      'from': selfId,
      'to': normalized,
      'text': '',
      'ts': ts,
      'type': 'voice',
      'voice': voiceRef,
      if (sanitizedReply != null) 'replyTo': sanitizedReply,
    };
    await db.saveMessage({
      'id': msgId,
      'peerId': normalized,
      'timestamp': ts,
      'direction': 'out',
      'status': 'pending',
      'payload': payload,
    });

    unawaited(db.savePeer({'id': normalized, 'lastSeenAt': now()}));

    if (!open) return msgId;

    final b64 = await b64EncodeHeavy(bytes);
    if (b64.length > _maxVoiceB64Len) {
      // Raw check passed but base64 expansion blew the wire cap. Leave
      // the row as pending so the user can decide whether to re-record.
      unawaited(db.updateMessageStatus(msgId, 'pending'));
      return msgId;
    }

    final ok = await conns.sendEncrypted(normalized, {
      'type': 'msg',
      'id': msgId,
      'text': '',
      'ts': ts,
      'from': selfId,
      'msgType': 'voice',
      'voice': <String, Object?>{
        'duration': durationSec,
        'mime': mime,
        'waveform': safeWaveform,
        'transcript': safeTranscript,
        'b64': b64,
      },
      if (sanitizedReply != null) 'replyTo': sanitizedReply,
    });
    if (!ok) {
      _sentAckGuard.disarm(msgId);
      unawaited(db.updateMessageStatus(msgId, 'pending'));
    } else {
      _sentAckGuard.arm(msgId);
    }
    return msgId;
  }

  // в”Ђв”Ђв”Ђ sendFile в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// Send a file attachment to [targetId]. Mirrors the voice path вЂ” blob
  /// in `file_blobs`, metadata in `payload.attachment`, full b64 on the
  /// wire. Returns the generated message id on success, `null` on
  /// validation failure.
  ///
  /// [kind] is `'image' | 'video' | 'audio' | 'file'`. The receiver
  /// trusts this verbatim (see `messageProtocol.js:345`), so classify
  /// honestly вЂ” a `kind:'image'` with `mime:'application/pdf'` renders
  /// as a broken `<img>` on the peer.
  ///
  /// [thumbBytes] is optional raw JPEG bytes for an image/video preview.
  /// Wire format carries it as a `data:image/jpeg;base64,...` URL (not
  /// raw b64 вЂ” the opposite encoding convention from the main blob, same
  /// trap as the Day-3 sticker url vs dataUrl mismatch). If the encoded
  /// data URL exceeds `_maxFileThumbLen`, we drop it rather than
  /// truncating вЂ” a half-rendered thumbnail is worse than the generic
  /// icon fallback.
  Future<String?> sendFile(
    String targetId,
    Uint8List bytes, {
    required String name,
    required String mime,
    required String kind,
    int width = 0,
    int height = 0,
    double durationSec = 0,
    Uint8List? thumbBytes,
    Map<String, Object?>? replyTo,
  }) async {
    final normalized = normalizePeerId(targetId);
    if (!isValidPeerId(normalized)) return null;
    if (_isPeerBlocked(normalized)) return null;
    if (bytes.isEmpty) return null;
    if (bytes.length > _maxFileRawBytes) return null;
    if (name.isEmpty) return null;
    if (mime.isEmpty) return null;
    if (kind.isEmpty) return null;

    final selfId = _ref.read(currentPeerIdProvider) ?? '';
    if (selfId.isEmpty) return null;

    final ts = now();
    final msgId = '$selfId:$ts:${_shortId()}';
    final conns = _ref.read(connectionsNotifierProvider.notifier);
    final open = _readyToShip(conns, normalized);

    final safeName = name.length > _maxFileNameLen
        ? name.substring(0, _maxFileNameLen)
        : name;
    final size = bytes.length;

    // Pre-compute the thumb data URL once вЂ” we need it for both the wire
    // envelope and the persisted metadata (so an own-sent row can show
    // the preview without refetching from disk). We persist the raw
    // thumb bytes in file_blobs.thumb so the UI can also lazy-load from
    // there for older rows where the data URL round-tripped through the
    // receiver's clamp.
    String? thumbDataUrl;
    if (thumbBytes != null && thumbBytes.isNotEmpty) {
      final candidate =
          'data:image/jpeg;base64,${base64Encode(thumbBytes)}';
      if (candidate.length <= _maxFileThumbLen) {
        thumbDataUrl = candidate;
      }
      // If the thumb overshoots the cap we silently drop it вЂ” the tile
      // falls back to an icon. The alternative (refusing the whole send)
      // is user-hostile for a cosmetic preview failure.
    }

    final sanitizedReply = _sanitizeReplyTo(replyTo);

    await db.saveFileBlob(
      msgId,
      bytes,
      mime: mime,
      name: safeName,
      kind: kind,
      size: size,
      width: width,
      height: height,
      duration: durationSec.toInt(),
      thumb: thumbBytes,
    );

    // `duration` stays a double for parity with the JS wire convention
    // (seconds, fractional). Persisted as double so the outbox retry
    // re-encodes an identical wire envelope to the first attempt.
    final attachmentRef = <String, Object?>{
      'name': safeName,
      'size': size,
      'mime': mime,
      'kind': kind,
      'thumb': thumbDataUrl,
      'width': width,
      'height': height,
      'duration': durationSec,
    };
    final payload = <String, Object?>{
      'id': msgId,
      'from': selfId,
      'to': normalized,
      'text': '',
      'ts': ts,
      'type': 'file',
      'attachment': attachmentRef,
      if (sanitizedReply != null) 'replyTo': sanitizedReply,
    };
    await db.saveMessage({
      'id': msgId,
      'peerId': normalized,
      'timestamp': ts,
      'direction': 'out',
      'status': 'pending',
      'payload': payload,
    });

    unawaited(db.savePeer({'id': normalized, 'lastSeenAt': now()}));

    if (!open) return msgId;

    final b64 = await b64EncodeHeavy(bytes);
    if (b64.length > _maxFileB64Len) {
      unawaited(db.updateMessageStatus(msgId, 'pending'));
      return msgId;
    }

    final ok = await conns.sendEncrypted(normalized, {
      'type': 'msg',
      'id': msgId,
      'text': '',
      'ts': ts,
      'from': selfId,
      'msgType': 'file',
      'attachment': <String, Object?>{
        'name': safeName,
        'size': size,
        'mime': mime,
        'kind': kind,
        'thumb': thumbDataUrl,
        'width': width,
        'height': height,
        'duration': durationSec,
        'b64': b64,
      },
      if (sanitizedReply != null) 'replyTo': sanitizedReply,
    });
    if (!ok) {
      _sentAckGuard.disarm(msgId);
      unawaited(db.updateMessageStatus(msgId, 'pending'));
    } else {
      _sentAckGuard.arm(msgId);
    }
    return msgId;
  }

  /// Native path-streamed chat attachment. The file never becomes one
  /// Dart `Uint8List` on the wire or over Bare IPC. PeerJS live path
  /// still uses [sendFile] (base64). [fileKey] is ratcheted, never
  /// journaled.
  Future<String?> sendFileFromPath(
    String targetId,
    String path, {
    required String name,
    required String mime,
    required String kind,
    int width = 0,
    int height = 0,
    double durationSec = 0,
    Map<String, Object?>? replyTo,
  }) async {
    final normalized = normalizePeerId(targetId);
    if (!isValidPeerId(normalized)) return null;
    if (_isPeerBlocked(normalized)) return null;
    if (name.isEmpty || mime.isEmpty || kind.isEmpty) return null;

    final conns = _ref.read(connectionsNotifierProvider.notifier);
    if (!conns.canUseNative(normalized)) return null;

    final size = localPathLength(path);
    if (size == null || size <= 0) return null;
    if (size > _maxFileRawBytes) return null;

    final selfId = _ref.read(currentPeerIdProvider) ?? '';
    if (selfId.isEmpty) return null;

    final ts = now();
    final msgId = '$selfId:$ts:${_shortId()}';
    final safeName = name.length > _maxFileNameLen
        ? name.substring(0, _maxFileNameLen)
        : name;
    final sanitizedReply = _sanitizeReplyTo(replyTo);
    final fileId = msgId;
    final fileKey = _freshFileKey();

    final attachmentRef = <String, Object?>{
      'name': safeName,
      'size': size,
      'mime': mime,
      'kind': kind,
      'width': width,
      'height': height,
      'duration': durationSec,
      'chunked': true,
      'fileId': fileId,
      'localPath': path,
    };
    final payload = <String, Object?>{
      'id': msgId,
      'from': selfId,
      'to': normalized,
      'text': '',
      'ts': ts,
      'type': 'file',
      'attachment': attachmentRef,
      if (sanitizedReply != null) 'replyTo': sanitizedReply,
    };
    await db.saveMessage({
      'id': msgId,
      'peerId': normalized,
      'timestamp': ts,
      'direction': 'out',
      'status': 'pending',
      'payload': payload,
    });
    unawaited(db.savePeer({'id': normalized, 'lastSeenAt': now()}));

    if (!_readyToShip(conns, normalized)) return msgId;

    final streamed = await conns.sendChatAttachmentFromPath(
      normalized,
      path,
      fileKey: fileKey,
      fileId: fileId,
    );
    if (!streamed) {
      unawaited(db.updateMessageStatus(msgId, 'pending'));
      return msgId;
    }

    final ok = await conns.sendEncrypted(normalized, {
      'type': 'msg',
      'id': msgId,
      'text': '',
      'ts': ts,
      'from': selfId,
      'msgType': 'file',
      'attachment': <String, Object?>{
        'name': safeName,
        'size': size,
        'mime': mime,
        'kind': kind,
        'width': width,
        'height': height,
        'duration': durationSec,
        'chunked': true,
        'fileId': fileId,
        'fileKeyB64': base64Encode(fileKey),
      },
      if (sanitizedReply != null) 'replyTo': sanitizedReply,
    });
    if (!ok) {
      _sentAckGuard.disarm(msgId);
      unawaited(db.updateMessageStatus(msgId, 'pending'));
    } else {
      _sentAckGuard.arm(msgId);
    }
    return msgId;
  }

  // Reply helpers

  /// Clamp a `replyTo` blob into a predictable, size-bounded shape. The
  /// user can technically pick *any* bubble to reply to, including a
  /// 32KiB text we accepted from a peer. Shipping the full quoted body on
  /// the wire would inflate the reply message needlessly; we only need
  /// enough for the quote preview (first 280 chars) + the pointer fields
  /// (id, from, type) so the UI can scroll back to the original on tap.
  Map<String, Object?>? _sanitizeReplyTo(Map<String, Object?>? raw) {
    if (raw == null) return null;
    final id = raw['id'];
    // A reply without an id is useless for scroll-to-original; bail early
    // rather than persist a half-broken anchor.
    if (id is! String || id.isEmpty) return null;
    final type = raw['type'];
    final typeStr = type is String && type.isNotEmpty ? type : 'text';
    return <String, Object?>{
      'id': id,
      'from': _clipField(raw['from'], 128),
      'fromName': _clipField(raw['fromName'], 64),
      'type': typeStr,
      'text': _clipField(raw['text'], 280),
      if (raw['stickerEmoji'] is String)
        'stickerEmoji': _clipField(raw['stickerEmoji'], 16),
      if (raw['attachmentKind'] is String)
        'attachmentKind': _clipField(raw['attachmentKind'], 24),
      if (raw['attachmentName'] is String)
        'attachmentName': _clipField(raw['attachmentName'], 120),
    };
  }

  /// String-field clamp with null passthrough. Returns null iff input is
  /// not a string (so callers can pattern `?? ''` to default cleanly).
  String? _clipField(Object? v, int max) {
    if (v is! String) return null;
    if (v.length <= max) return v;
    return v.substring(0, max);
  }

  // в”Ђв”Ђв”Ђ Helpers в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// Short random hex вЂ” 8 bytes в†’ 16 chars. Used as the msgId suffix.
  /// `Random.secure()` to avoid collisions on rapid sends, matches the
  /// JS `crypto.getRandomValues` fallback path.
  String _shortId() {
    final bytes = List<int>.generate(8, (_) => _rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Clamp + sanitize an incoming UI message before we persist it. A
  /// hostile peer could otherwise send a 1 GB text or voice blob and
  /// exhaust device memory (the chat view can hold 500 entries per peer).
  Map<String, Object?> _clampChatMessage(Map<String, Object?> msg) {
    final text = msg['text'];
    if (text is String && text.length > _maxTextLen) {
      msg['text'] = '${text.substring(0, _maxTextLen)}вЂ¦';
    }
    final voice = msg['voice'];
    if (voice is Map && voice['b64'] is String) {
      final b64 = voice['b64'] as String;
      if (b64.length > _maxVoiceB64Len) {
        msg['voice'] = null;
      }
    }
    final sticker = msg['sticker'];
    if (sticker is Map && sticker['dataUrl'] is String) {
      final url = sticker['dataUrl'] as String;
      if (url.length > _maxStickerLen) {
        msg['sticker'] = null;
      }
    }
    final attachment = msg['attachment'];
    if (attachment is Map && attachment['thumb'] is String) {
      final thumb = attachment['thumb'] as String;
      if (thumb.length > _maxFileThumbLen) {
        final next = Map<String, Object?>.from(attachment);
        next['thumb'] = null;
        msg['attachment'] = next;
      }
    }
    return msg;
  }

  @override
  void dispose() {
    // Detach the peers listener first so no late `blocked` emit tries to
    // poke `state =` on a half-disposed notifier.
    _peersSub.close();
    _ackTimer?.cancel();
    _ackTimer = null;
    unawaited(_sentAckGuard.dispose());
    for (final t in _typingIdleTimers.values) {
      t.cancel();
    }
    _typingIdleTimers.clear();
    // Reset the connections-registry bridge to no-ops so an inbound packet
    // arriving after our disposal doesn't invoke closures that capture this
    // notifier's (now-defunct) `_ref`. Without this, a logoutв†’new-login
    // cycle could see the packet router fire `pushInbound` on a dead ref
    // and throw `Ref used after dispose`.
    try {
      _ref.read(connectionsNotifierProvider.notifier)
          .bindMessaging(MessagingBridge.empty);
    } catch (_) {
      // Container already torn down вЂ” nothing to unbind from.
    }
    // Best-effort final flush вЂ” fire-and-forget, the notifier is being torn
    // down anyway.
    unawaited(_flushAckBuffer());
    super.dispose();
  }
}

// в”Ђв”Ђв”Ђ Providers в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

final messagingNotifierProvider =
    StateNotifierProvider<MessagingNotifier, MessagingState>((ref) {
  return MessagingNotifier(ref);
});

/// Per-peer typing indicator. Selected off the notifier so a text-field
/// widget for peer A doesn't rebuild when peer B starts typing.
final typingForPeerProvider = Provider.family<bool, String>((ref, peerId) {
  final key = normalizePeerId(peerId);
  return ref.watch(
    messagingNotifierProvider.select((s) => s.typingByPeer[key] ?? false),
  );
});

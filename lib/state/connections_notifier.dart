// Port of `src/hooks/useConnections.js` — the PeerJS DataConnection registry,
// glare resolver, and packet-router plumbing. This is the single choke point
// where inbound traffic turns into UI state and outbound chat/profile traffic
// is handed off to [WireTransport] for encryption.
//
// Differences from the JS source worth calling out:
//
// 1. React used a `handlersRef` whose `.current` was set lazily by usePeer
//    after every sub-hook mounted, to work around circular-dep. In Dart we
//    just `ref.read(messagingNotifierProvider.notifier)` inside each
//    callback — Riverpod initialises the other notifier on first read and
//    there's no cycle as long as neither constructor reads the other.
//
// 2. `peer.on('connection')` and `peer.on('call')` are wired here via
//    `ref.listen(peerConnectionProvider)` so we reattach if the manager
//    swaps its PeerJS instance (host rotation, F5 zombie recovery, etc.).
//    Without that the registry would keep receiving events from a dead
//    stream while silently missing everything on the new instance.
//
// 3. `PeerDataConnection.onOpen/onClose/onError/onData` are Streams (not
//    EventEmitter `.on(name, cb)`), which means every subscription is a
//    `StreamSubscription` that needs cancelling. We stash them in a
//    `_ConnBinding` alongside the connection so rebinding on glare doesn't
//    leak listeners from the discarded peer connection.
//
// Registry ownership: the notifier lives for the container's lifetime (same
// as `peerConnectionProvider`) and tears down every open connection in
// `dispose()` so a hot-reload or process shutdown doesn't leave PeerJS
// threads dangling.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/bundle_cache.dart';
import '../core/wire_crypto.dart' show initWireSession;
import '../core/wire_session.dart' show isVerified;
import '../messaging/message_protocol.dart';
import '../core/orbits_drop.dart' show dropMaxBufferSize;
import '../peer/helpers.dart';
import '../peer/packet_router.dart';
import '../peer/room_plaintext_gate.dart';
import '../peer/peerjs_client.dart';
import '../calls/hyperswarm_signaling.dart';
import '../core/feature_flags.dart';
import '../peer/wire_transport.dart';
import '../devices/device_registry.dart';
import '../mailbox/blind_store.dart';
import '../mailbox/storage_peer_client.dart';
import '../replication/file_journal.dart';
import '../replication/memory_journal.dart';
import '../storage/db.dart' as db;
import '../transport/dual_stack_bridge.dart';
import '../transport/signed_capabilities.dart';
import '../transport/transport_api.dart';
import 'auth_notifier.dart';
import 'local_profile_provider.dart';
import 'peer_connection_provider.dart';

// ─── Public state ─────────────────────────────────────────────────

/// Snapshot of the connection registry the UI cares about. We emit the set
/// of currently-connected peerIds (reliable channel open) so widgets can
/// light up the green dot without reading the raw `Map<String, …>`.
class ConnectionsState {
  const ConnectionsState({
    required this.connectedPeerIds,
    this.lastConnectError,
  });

  const ConnectionsState.empty()
      : connectedPeerIds = const <String>{},
        lastConnectError = null;

  final Set<String> connectedPeerIds;

  /// Most recent failed dial — surfaced for diagnostics so a swallowed P2P
  /// error is observable (peerId + reason + timestamp). Null until something
  /// fails. This is an HONEST diagnostic, not a user-facing "contact not
  /// found": the chat header still derives в сети / не в сети purely from
  /// [connectedPeerIds].
  final ConnectError? lastConnectError;

  ConnectionsState copyWith({
    Set<String>? connectedPeerIds,
    Object? lastConnectError = _unset,
  }) =>
      ConnectionsState(
        connectedPeerIds: connectedPeerIds ?? this.connectedPeerIds,
        lastConnectError: identical(lastConnectError, _unset)
            ? this.lastConnectError
            : lastConnectError as ConnectError?,
      );
}

const Object _unset = Object();

/// A diagnostic record for a failed P2P dial.
class ConnectError {
  const ConnectError({
    required this.peerId,
    required this.channel,
    required this.message,
    required this.atMs,
  });
  final String peerId;
  final String channel; // 'reliable' | 'ephemeral'
  final String message;
  final int atMs;
}

// ─── Internal bookkeeping ────────────────────────────────────────

/// Everything we need to tear down a single attached connection cleanly.
class _ConnBinding {
  _ConnBinding({
    required this.conn,
    required this.channel,
    required this.subscriptions,
  });

  final PeerDataConnection conn;
  final String channel; // 'reliable' | 'ephemeral'
  final List<StreamSubscription<dynamic>> subscriptions;
  Timer? connectTimer;

  Future<void> dispose() async {
    connectTimer?.cancel();
    connectTimer = null;
    for (final sub in subscriptions) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    subscriptions.clear();
    try {
      await conn.close();
    } catch (_) {}
  }
}

// ─── Notifier ─────────────────────────────────────────────────────

class ConnectionsNotifier extends StateNotifier<ConnectionsState> {
  ConnectionsNotifier(this._ref) : super(const ConnectionsState.empty()) {
    _wire = WireTransport(selfPeerId: () => _selfPeerId());

    // React to the PeerJS instance lifecycle. Every time a new PeerJsClient
    // is born (initial open, host rotation, zombie recovery) we re-subscribe
    // to its connection/call streams. Tearing down the old subscriptions is
    // critical — a rotated peer keeps firing into /dev/null otherwise.
    _ref.listen<PeerConnectionState>(
      peerConnectionProvider,
      (prev, next) => _bindToCurrentPeer(),
      fireImmediately: true,
    );

    // Sign-out: close everything. We don't touch the peer manager here;
    // it already transitioned to idle via its own auth listener.
    _ref.listen<AuthState>(
      authNotifierProvider,
      (prev, next) {
        if (prev is AuthAuthed && next is! AuthAuthed) {
          _teardownAll();
        }
      },
    );
  }

  final Ref _ref;
  late final WireTransport _wire;

  /// Messaging callbacks. Swapped in once by [MessagingNotifier] during its
  /// constructor — see `bindMessaging`. Stays as the no-op bridge otherwise.
  MessagingBridge _messaging = MessagingBridge.empty;

  /// Orbits-Drop file-transfer callbacks, swapped in by [DropNotifier] via
  /// [bindDrop]. No-op until then so an early file frame can't crash.
  DropBridge _drop = DropBridge.empty;

  /// Room-protocol callbacks, swapped in by [RoomManager] via [bindRoom].
  /// No-op until then so an early `room_*` packet can't crash.
  RoomBridge _room = RoomBridge.empty;

  DualStackBridge? _dual;
  MemoryJournal? _nativeJournal;
  void Function(String from, CallSignal signal)? _callHandler;

  /// Keyed by `connKey(peerId, channel)`.
  final Map<String, _ConnBinding> _bindings = {};

  /// Reliable targets requested via [openReliable] *before* the PeerJS client
  /// finished opening. Flushed the instant `peer.onOpen` fires so a chat
  /// opened on cold-boot automatically dials the moment the server ACKs our
  /// identity — otherwise the dial is silently dropped and the chat sticks
  /// on "не в сети" until the user pokes another action. Ephemeral targets
  /// aren't queued: they're best-effort and the chat view re-kicks them on
  /// the next typing event anyway.
  final Set<String> _pendingReliableTargets = <String>{};

  /// Subscriptions to the currently-bound `PeerJsClient` (onConnection,
  /// onCall). Cancelled and rebuilt when the peer manager swaps instances.
  final List<StreamSubscription<dynamic>> _peerSubs = [];
  PeerJsClient? _boundPeer;

  WireTransport get wire => _wire;

  /// Register the messaging-layer callbacks. Called once by
  /// `MessagingNotifier` during its construction. Subsequent calls replace
  /// the bridge — useful for tests, not expected in production.
  void bindMessaging(MessagingBridge bridge) {
    _messaging = bridge;
  }

  /// Register the Drop file-transfer callbacks. Called once by [DropNotifier].
  void bindDrop(DropBridge bridge) {
    _drop = bridge;
  }

  /// Register the room-protocol callbacks. Called once by [RoomManager].
  void bindRoom(RoomBridge bridge) {
    _room = bridge;
  }

  /// Attach the Holepunch carrier. No-op for the live PeerJS path until
  /// [isHyperswarmTransportEnabled] is true and a discovery secret exists.
  void bindNativeTransport(
    OrbitsTransport transport, {
    MemoryJournal? journal,
    String deviceId = 'local-device',
    FileJournal? durableJournal,
    BlindMailboxStore? mailbox,
    StoragePeerClient? storagePeer,
    String? mailboxToken,
    String? mailboxWriterKey,
    CapabilityRecord? localCapabilities,
    DeviceRegistry? devices,
  }) {
    _nativeJournal = journal ?? MemoryJournal(deviceId);
    _dual = DualStackBridge(
      transport: transport,
      journal: _nativeJournal!,
      selfPeerId: _selfPeerId,
      selfDeviceId: deviceId,
      durableJournal: durableJournal,
      mailbox: mailbox,
      storagePeer: storagePeer,
      mailboxToken: mailboxToken,
      mailboxWriterKey: mailboxWriterKey,
      localCapabilities: localCapabilities,
      devices: devices ?? deviceRegistry,
      onPacket: _dispatchNativeInbound,
      isBlocked: (rid) => _messaging.isPeerBlocked(rid),
    )
      ..onPresence = (peerId, up) {
        if (!mounted) return;
        _refreshConnectedIds();
        if (up) unawaited(_postNativeOpen(peerId));
      }
      ..onCallSignal = (signal, from) {
        _lastCallSignal = (from: from, signal: signal);
        _callHandler?.call(from, signal);
      }
      ..onDrop = (peerId, packet) {
        _drop.handleInbound(peerId, packet);
      }
      ..attach();
  }

  Future<void> unbindNativeTransport() async {
    await _dual?.detach();
    _dual = null;
    _nativeJournal = null;
  }

  ({String from, CallSignal signal})? _lastCallSignal;

  ({String from, CallSignal signal})? get lastCallSignal => _lastCallSignal;

  MemoryJournal? get nativeJournal => _nativeJournal;

  DualStackBridge? get nativeBridge => _dual;

  bool canUseNative(String peerId) => _dual?.canUseNative(peerId) == true;

  void bindCallHandler(void Function(String from, CallSignal signal)? handler) {
    _callHandler = handler;
  }

  // ─── Public API ────────────────────────────────────────────────

  /// Look up a live connection by peerId + channel. Null if never attached
  /// or already torn down.
  PeerDataConnection? getConn(String remoteId, String channel) {
    final key = connKey(remoteId, channel);
    return _bindings[key]?.conn;
  }

  /// Resolve + encrypt + send on the reliable channel. Returns false if we
  /// don't have a reliable connection to this peer.
  Future<bool> sendEncrypted(String remoteId, Object? msg) async {
    final dual = _dual;
    if (dual != null && dual.nativeEnabled) {
      if (dual.canUseNative(remoteId)) {
        try {
          return await dual.sendEncrypted(remoteId, msg);
        } catch (_) {
          if (!isPeerjsFallbackEnabled()) return false;
        }
      } else if (dual.hasMailbox && dual.secrets.get(remoteId) != null) {
        try {
          return await dual.sendEncrypted(remoteId, msg);
        } catch (_) {
          if (!isPeerjsFallbackEnabled()) return false;
        }
      }
    }
    final conn = getConn(remoteId, 'reliable');
    if (conn == null) return false;
    return _wire.sendEncryptedOn(conn, remoteId, msg);
  }

  /// Same on the ephemeral channel (typing / heartbeat).
  Future<bool> sendEphemeral(String remoteId, Object? msg) async {
    final dual = _dual;
    if (dual != null && dual.canUseNative(remoteId)) {
      try {
        return await dual.sendEphemeral(remoteId, msg);
      } catch (_) {
        if (!isPeerjsFallbackEnabled()) return false;
      }
    }
    final conn = getConn(remoteId, 'ephemeral');
    if (conn == null) return false;
    return _wire.sendEphemeralOn(conn, remoteId, msg);
  }

  /// Whether a reliable channel to [remoteId] is open (used by Drop to gate
  /// the peer picker / send button).
  bool hasReliable(String remoteId) {
    if (_dual?.isNativeConnected(remoteId) == true) return true;
    final conn = getConn(remoteId, 'reliable');
    return conn != null && conn.open;
  }

  /// Send a raw Orbits-Drop packet on the reliable channel — a control [Map]
  /// (JSON) or a binary chunk [Uint8List]. Bypasses the per-message ratchet by
  /// design (chunks are framed binary, protected in transit by the DataChannel
  /// DTLS layer). Returns false if no open reliable connection exists.
  bool sendDrop(String remoteId, Object packet) {
    final dual = _dual;
    if (dual != null && dual.canUseNative(remoteId)) {
      unawaited(dual.sendDrop(remoteId, packet));
      return true;
    }
    final conn = getConn(remoteId, 'reliable');
    if (conn == null || !conn.open) return false;
    return conn.send(packet);
  }

  /// Native large-file path. PeerJS Drop still uses [sendDrop] with bytes.
  Future<bool> sendFileFromPath(
    String remoteId,
    TransportFileDescriptor file,
  ) async {
    final dual = _dual;
    if (dual != null && dual.canUseNative(remoteId)) {
      return dual.sendFileFromPath(remoteId, file);
    }
    return false;
  }

  /// Send a plaintext room-protocol control [packet] on the reliable channel.
  /// Like [sendDrop] it bypasses the per-message ratchet by design: room
  /// traffic is DTLS-protected in transit and must NOT go through the wire
  /// ratchet, because the `verified`/TOFU gate on `decryptInbound` would
  /// reject packets from guests who aren't verified contacts. Returns false if
  /// no open reliable connection exists.
  bool sendRoomPacket(String remoteId, Map<String, Object?> packet) {
    final dual = _dual;
    if (dual != null && dual.canUseNative(remoteId)) {
      return sendGuardedRoomPacket(
        packet,
        connected: true,
        send: (p) => dual.sendRoomPacket(remoteId, p),
      );
    }
    final conn = getConn(remoteId, 'reliable');
    return sendGuardedRoomPacket(
      packet,
      connected: conn != null && conn.open,
      send: (p) => conn!.send(p),
    );
  }

  Future<void> sendCallSignal(String remoteId, CallSignal signal) async {
    final dual = _dual;
    if (dual != null && dual.canUseNative(remoteId)) {
      await dual.sendCallSignal(remoteId, signal);
    }
  }

  /// Backpressure for Drop: resolve once the reliable channel's send buffer
  /// drains below [dropMaxBufferSize]. No-ops when the platform doesn't report
  /// `bufferedAmount`. Capped (~10s) so a wedged channel can't hang the loop —
  /// the next `conn.send` will then surface the dead channel.
  Future<void> waitForDropDrain(String remoteId) async {
    final dc = getConn(remoteId, 'reliable')?.dataChannel;
    if (dc == null) return;
    for (var i = 0; i < 200; i++) {
      final buffered = dc.bufferedAmount ?? 0;
      if (buffered <= dropMaxBufferSize) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Proactively open the ephemeral side-channel to [targetId]. No-op if a
  /// working ephemeral connection already exists, or if the peer manager
  /// isn't ready.
  void openEphemeral(String targetId) {
    _openChannel(targetId, reliable: false);
  }

  /// Proactively open the reliable chat channel to [targetId]. Called by
  /// the chat page on mount so the user sees "online" + message delivery
  /// without having to send the first message to kick the dialer. No-op
  /// if an open reliable connection already exists or the peer manager
  /// isn't ready.
  void openReliable(String targetId) {
    _openChannel(targetId, reliable: true);
  }

  /// Shared implementation for the two public open-channel helpers.
  /// Keeps the "validate → lookup existing → dial via PeerJsClient →
  /// attach listeners" sequence in one place so reliable and ephemeral
  /// can't drift apart accidentally.
  void _openChannel(String targetId, {required bool reliable}) {
    // Guard against UI-driven calls after the notifier was disposed — the
    // chat page's postFrameCallback could land on a torn-down container
    // during hot-reload or signout, and we don't want to leak into
    // `_pendingReliableTargets` on an object nobody will flush.
    if (!mounted) return;
    final normalized = normalizePeerId(targetId);
    if (!isValidPeerId(normalized)) return;
    if (normalized == _selfPeerId()) return;
    final channel = reliable ? 'reliable' : 'ephemeral';
    final existing = getConn(normalized, channel);
    // TODO(day2+): tighten dedup — also skip when `existing != null` but
    // `!existing.open` (in-flight dial) to close the brief double-dial
    // window between `peer.connect` and `conn.onOpen`. Glare resolver
    // cleans the duplicate up today, so this is cosmetic only.
    if (existing != null && existing.open) return;
    if (reliable) {
      unawaited(_dual?.dial(normalized));
    }
    final peer = _boundPeer;
    if (peer == null || peer.destroyed || !peer.open) {
      // PeerJS not ready yet (cold-boot race: user taps chat row faster
      // than the server ACKs). Stash reliable requests so the onOpen hook
      // in `_bindToCurrentPeer` can flush them the moment we're live.
      if (reliable) _pendingReliableTargets.add(normalized);
      return;
    }

    // `connect` is async on PeerJsClient (builds an RTCPeerConnection). We
    // fire-and-forget; when the RTC side resolves we attach listeners.
    unawaited(() async {
      try {
        final conn = await peer.connect(
          normalized,
          reliable: reliable,
          label: channel,
          metadata: {'channel': channel, 'initiator': true},
        );
        await attachConn(conn, channel);
      } catch (e) {
        // Don't fail silently (audit P0 item 7). Opening can fail for many
        // reasons (peer offline, ICE/TURN can't traverse NAT, signaling
        // dropped). The chat header still shows "не в сети" via
        // connectedPeerIds; here we ALSO log + record the reason so
        // diagnostics can answer "why didn't it connect?".
        debugPrint('[conn] openChannel($normalized, $channel) failed: $e');
        if (mounted) {
          state = state.copyWith(
            lastConnectError: ConnectError(
              peerId: normalized,
              channel: channel,
              message: e.toString(),
              atMs: now(),
            ),
          );
        }
      }
    }());
  }

  /// Wire up event listeners + packet router for a freshly created or
  /// accepted [PeerDataConnection]. Idempotent: if a different connection
  /// already holds the same key, glare resolution decides which to keep.
  Future<void> attachConn(PeerDataConnection conn, String channel) async {
    final remoteId = normalizePeerId(conn.peer);
    if (remoteId.isEmpty) return;
    if (_messaging.isPeerBlocked(remoteId)) {
      try {
        unawaited(conn.close());
      } catch (_) {}
      return;
    }
    final ch = channel == 'ephemeral' ? 'ephemeral' : 'reliable';
    final key = connKey(remoteId, ch);
    final myId = _selfPeerId();

    if (!_resolveGlare(key, conn, myId, remoteId)) return;

    // If a previous binding survived glare (i.e. we're keeping the old
    // connection), we've already returned. If we're keeping the new one,
    // blow away the loser's listeners.
    //
    // Guard: when the same `conn` object is re-attached (rare but possible
    // if a caller double-invokes after an onClose fires), `_resolveGlare`
    // returns true via its `existing.conn == conn` short-circuit — and we
    // must not dispose the binding here, because disposing would cancel
    // the still-live listeners and close the connection we just decided
    // to keep. Only tear down stale bindings whose conn differs from the
    // incoming one.
    final stale = _bindings.remove(key);
    if (stale != null && stale.conn != conn) {
      unawaited(stale.dispose());
    }

    // Build the per-connection packet router context. Each callback reads
    // the messaging / peer-status side through `_ref.read(...)` so we don't
    // capture stale references.
    final routerCtx = _buildRouterCtx(conn, remoteId);
    final onData = createPacketHandler(ch, remoteId, routerCtx);

    // Track the binding early so callbacks fired during `listen()` setup
    // can look themselves up.
    final binding = _ConnBinding(
      conn: conn,
      channel: ch,
      subscriptions: <StreamSubscription<dynamic>>[],
    );
    _bindings[key] = binding;

    // Connection timeout (audit Round 5 A.5) — now for BOTH channels. The
    // reliable budget matches the JS 15s; the ephemeral side-channel used to
    // have NO budget and could linger forever as a half-open dial.
    binding.connectTimer = Timer(const Duration(seconds: 15), () {
      final cur = _bindings[key];
      if (cur == null || cur.conn != conn) return;
      if (conn.open) return;
      unawaited(cur.dispose());
      _bindings.remove(key);
      if (ch == 'reliable') {
        _markPeerOffline(remoteId);
        // Ephemeral side-channel to the same peer often dies with it.
        final ephKey = connKey(remoteId, 'ephemeral');
        final eph = _bindings[ephKey];
        if (eph != null && !eph.conn.open) {
          _bindings.remove(ephKey);
          unawaited(eph.dispose());
        }
      }
    });

    // Wire events.
    binding.subscriptions.add(conn.onOpen.listen((_) {
      binding.connectTimer?.cancel();
      binding.connectTimer = null;
      if (ch == 'reliable') {
        _markPeerOnline(remoteId);
        _refreshConnectedIds();
        unawaited(_postReliableOpen(conn, remoteId));
      } else {
        // Ephemeral open — no handshake, just note the latency channel is up.
      }
    }));

    binding.subscriptions.add(conn.onClose.listen((_) {
      binding.connectTimer?.cancel();
      binding.connectTimer = null;
      final cur = _bindings[key];
      if (cur != null && cur.conn == conn) {
        _bindings.remove(key);
      }
      if (ch == 'reliable') {
        _markPeerOffline(remoteId);
        _refreshConnectedIds();
        try {
          _drop.resetPeer?.call(remoteId);
        } catch (_) {}
      }
    }));

    binding.subscriptions.add(conn.onError.listen((_) {
      binding.connectTimer?.cancel();
      binding.connectTimer = null;
      if (ch == 'reliable') _markPeerOffline(remoteId);
    }));

    binding.subscriptions.add(conn.onData.listen((data) {
      // Errors inside the router bubble up here as async exceptions on the
      // stream — we swallow them so a single malformed packet doesn't kill
      // the subscription and freeze the channel.
      unawaited(Future.sync(() => onData(data)).catchError((_) {}));
    }));
  }

  // ─── Glare resolver ───────────────────────────────────────────

  /// Returns true if `conn` should keep the slot in `_bindings`. When two
  /// connections race (both sides called `.connect` around the same time),
  /// PeerJS hands us duplicates. We pick a deterministic winner based on
  /// initiator flag + lexicographic peer id order (matches JS verbatim).
  bool _resolveGlare(
    String key,
    PeerDataConnection conn,
    String myId,
    String remoteId,
  ) {
    final existing = _bindings[key];
    if (existing == null || existing.conn == conn) return true;

    final PeerDataConnection preferred;
    if (myId.isEmpty) {
      // Identity isn't known yet (boot-before-identity race, or a
      // zombie-recovery path where the PeerJS client comes up before
      // `currentPeerIdProvider` emits). The initiator heuristic can't run
      // because `shouldKeepInitiator` would be a one-sided guess that
      // disagrees with the remote. Fall back to connectionId tie-break,
      // which both sides compute consistently from the same PeerJS
      // connection identifier.
      preferred = conn.connectionId.compareTo(existing.conn.connectionId) < 0
          ? conn
          : existing.conn;
    } else {
      final initiator = conn.initiator;
      final existingInitiator = existing.conn.initiator;
      final shouldKeepInitiator = myId.compareTo(remoteId) < 0;

      if (initiator == shouldKeepInitiator &&
          existingInitiator != shouldKeepInitiator) {
        preferred = conn;
      } else if (existingInitiator == shouldKeepInitiator &&
          initiator != shouldKeepInitiator) {
        preferred = existing.conn;
      } else {
        // Both have the same initiator role — break the tie on connectionId.
        preferred = conn.connectionId.compareTo(existing.conn.connectionId) < 0
            ? conn
            : existing.conn;
      }
    }

    if (preferred == conn) {
      return true;
    }
    // Keep existing; close the new one.
    try {
      unawaited(conn.close());
    } catch (_) {}
    return false;
  }

  // ─── Router ctx builder ───────────────────────────────────────

  /// A small set of sentinel values are kept in-scope so the router ctx
  /// doesn't have to re-read them for every packet. The heavier state
  /// (messages, profiles) always goes through `_ref.read(...)` so it stays
  /// fresh.
  final Set<String> _seenMsgIds = <String>{};

  ReliableInboundCtx _reliableCtx(String remoteId) {
    return ReliableInboundCtx(
        selfPeerId: _selfPeerId(),
        localProfile: () => _localProfileJson(),
        seenMsgIds: _seenMsgIds,
        isPeerBlocked: (rid) => _messaging.isPeerBlocked(rid),
        persistInbound: (rid, uiMsg) => _messaging.pushInbound(rid, uiMsg),
        pushMessage: (rid, uiMsg) => _messaging.pushInbound(rid, uiMsg),
        updateMessage: (rid, id, patch) =>
            _messaging.patchMessage(rid, id, patch),
        setProfilesByPeer: (_) {
          // Profile state isn't modelled in this slice — profiles are
          // persisted in Drift via `upsertPeer`, and the chat list reads
          // them from there. Safe to no-op.
        },
        setMessagesByPeer: (_) {
          // Same — messages live in Drift, the stream provider handles
          // reactive rebuilds.
        },
        upsertPeer: (rid, patch) async {
          // Mirror the JS flow: peer row lives in Drift, one write per
          // upsert. Failure is non-fatal (usually a closed DB during
          // teardown) so we swallow.
          try {
            await db.savePeer({'id': rid, ...patch});
          } catch (_) {}
        },
        queueAckStatus: (id, status) =>
            _messaging.queueAckStatus(id, status),
        // The ReliableInboundCtx field fixes `remoteId` up-front via closure
        // (it's a per-peer ctx), so the dispatched callback takes just the
        // payload map. Our local `sendEncrypted` helper still takes both
        // since it has to route to the right connection — bridge the shapes
        // here rather than changing either contract.
        sendEncrypted: (msg) => unawaited(sendEncrypted(remoteId, msg)),
        notifyNewMessage: ({
          required String from,
          required String text,
          required String tag,
        }) {
          // Push notifications land in a later slice.
        },
        hapticMessage: () {
          // Haptics helper already exists in core/haptics.dart; wired in
          // the messaging UX slice.
        },
        playReceiveSound: () {
          // Same — sound cue hooks live in a future audio slice.
        },
        isAppInForeground: () => true,
    );
  }

  PacketRouterCtx _buildRouterCtx(PeerDataConnection conn, String remoteId) {
    return PacketRouterCtx(
      conn: conn.send,
      flushOutbox: () => _messaging.flushOutboxForPeer(remoteId),
      reliable: _reliableCtx(remoteId),
      ephemeral: EphemeralInboundCtx(
        applyTyping: (isTyping) =>
            _messaging.applyTyping(remoteId, isTyping),
        onHeartbeat: () {
          if (_messaging.isPeerBlocked(remoteId)) return;
          unawaited(db.savePeer({'id': remoteId, 'lastSeenAt': now()}));
        },
      ),
      dropInbound: (rid, packet) => _drop.handleInbound(rid, packet),
      dropAllowed: (rid) => isVerified(rid) && !_messaging.isPeerBlocked(rid),
      isBlocked: (rid) => _messaging.isPeerBlocked(rid),
      roomInbound: (rid, packet) => _room.handleInbound(rid, packet),
    );
  }

  // ─── Reliable-open follow-up ──────────────────────────────────

  Future<void> _postReliableOpen(
    PeerDataConnection conn,
    String remoteId,
  ) async {
    await _wire.initiateHandshakeOnOpen(conn, remoteId);
    final bridge = _messaging;
    unawaited(bridge.loadPendingForPeer(remoteId));
    unawaited(bridge.flushOutboxForPeer(remoteId));
    unawaited(sendEncrypted(
      remoteId,
      {'type': 'profile_req', 'nonce': now()},
    ));
    try {
      final cached = await getCachedBundle(remoteId);
      if (cached == null) {
        unawaited(sendEncrypted(
          remoteId,
          {'type': 'bundle_req', 'nonce': now()},
        ));
      }
    } catch (_) {
      // Bundle cache is a read-through cache — missing row is fine.
    }
  }

  // ─── Peer-row status writes ───────────────────────────────────

  void _markPeerOnline(String remoteId) {
    unawaited(db.savePeer({
      'id': remoteId,
      'lastSeenAt': now(),
    }));
  }

  void _markPeerOffline(String remoteId) {
    unawaited(db.savePeer({
      'id': remoteId,
      'lastSeenAt': now(),
    }));
    _refreshConnectedIds();
  }

  Future<void> _dispatchNativeInbound(String remoteId, Object? data) async {
    if (_messaging.isPeerBlocked(remoteId)) return;
    if (isRoomPacket(data) && data is Map) {
      _room.handleInbound(remoteId, Map<String, Object?>.from(data));
      return;
    }
    await dispatchReliableInbound(
      data,
      (msg) => unawaited(sendEncrypted(remoteId, msg)),
      remoteId,
      _reliableCtx(remoteId),
    );
    _messaging.flushOutboxForPeer(remoteId);
  }

  Future<void> _postNativeOpen(String remoteId) async {
    try {
      final hello = await initWireSession(
        peerId: remoteId,
        myPeerId: _selfPeerId(),
      );
      await sendEncrypted(remoteId, hello.hello);
    } catch (_) {}
    final bridge = _messaging;
    unawaited(bridge.loadPendingForPeer(remoteId));
    unawaited(bridge.flushOutboxForPeer(remoteId));
  }

  void _refreshConnectedIds() {
    final next = <String>{};
    for (final b in _bindings.values) {
      if (b.channel == 'reliable' && b.conn.open) {
        next.add(normalizePeerId(b.conn.peer));
      }
    }
    next.addAll(_dual?.connected ?? const <String>{});
    if (next.length == state.connectedPeerIds.length &&
        next.every(state.connectedPeerIds.contains)) {
      return; // no change
    }
    state = state.copyWith(connectedPeerIds: next);
  }

  // ─── Peer-manager binding ─────────────────────────────────────

  void _bindToCurrentPeer() {
    final current = _ref.read(peerConnectionProvider.notifier).rawPeer;
    if (current == _boundPeer) return;

    // Tear down old subs.
    for (final s in _peerSubs) {
      try {
        s.cancel();
      } catch (_) {}
    }
    _peerSubs.clear();
    // Connections attached to the previous peer are dead now.
    _teardownAll();

    _boundPeer = current;
    if (current == null) return;

    _peerSubs.add(current.onConnection.listen((conn) {
      final ch = (conn.metadata['channel'] as String?) == 'ephemeral'
          ? 'ephemeral'
          : 'reliable';
      unawaited(attachConn(conn, ch));
    }));

    // Flush any reliable dials that were queued while PeerJS was still
    // coming up. If the client is already open (host rotation landing on
    // an already-ready peer) flush synchronously; otherwise wait for the
    // server's id ACK exactly once — later re-ACKs on the same client
    // (server reconnects) should no-op, otherwise we'd re-dial targets
    // that are already in-flight from the first flush.
    if (current.open) {
      _flushPendingReliable();
    } else {
      late final StreamSubscription<String> openSub;
      openSub = current.onOpen.listen((_) {
        openSub.cancel();
        _peerSubs.remove(openSub);
        if (!mounted) return;
        _flushPendingReliable();
      });
      _peerSubs.add(openSub);
    }

    // Incoming-call handling lives in `CallsNotifier` (lib/state/calls_provider.dart)
    // so this registry only owns DataConnection lifecycle. The calls notifier
    // listens to the same peer-instance stream and reacts to `peer.onCall`
    // independently — no cross-module coupling needed.
  }

  /// Dial every reliable target that was queued before the PeerJS client
  /// finished opening. Snapshot + clear up front so a re-add from inside
  /// `_openChannel` (e.g. the peer goes back to not-ready in the middle of
  /// the loop) can't cause an infinite re-entry.
  void _flushPendingReliable() {
    if (_pendingReliableTargets.isEmpty) return;
    final targets = List<String>.from(_pendingReliableTargets);
    _pendingReliableTargets.clear();
    for (final t in targets) {
      _openChannel(t, reliable: true);
    }
  }

  void _teardownAll() {
    final all = List<_ConnBinding>.from(_bindings.values);
    _bindings.clear();
    // Drop queued dials too — after a sign-out or peer-instance swap the
    // old targets may be stale (e.g. different identity) and at best are a
    // re-dial the user didn't ask for. The next chat open will re-queue.
    _pendingReliableTargets.clear();
    for (final b in all) {
      unawaited(b.dispose());
    }
    _seenMsgIds.clear();
    if (state.connectedPeerIds.isNotEmpty) {
      state = const ConnectionsState.empty();
    }
  }

  String _selfPeerId() {
    return _ref.read(currentPeerIdProvider) ?? '';
  }

  Map<String, Object?>? _localProfileJson() {
    final u = _ref.read(localProfileProvider);
    if (u == null) return null;
    return {
      'peerId': u.peerId,
      'displayName': u.displayName,
      'bio': u.bio,
      if (u.avatarDataUrl != null) 'avatarDataUrl': u.avatarDataUrl,
    };
  }

  @override
  void dispose() {
    for (final s in _peerSubs) {
      try {
        s.cancel();
      } catch (_) {}
    }
    _peerSubs.clear();
    unawaited(_dual?.detach());
    _teardownAll();
    super.dispose();
  }
}

// ─── Providers ────────────────────────────────────────────────────

final connectionsNotifierProvider =
    StateNotifierProvider<ConnectionsNotifier, ConnectionsState>((ref) {
  return ConnectionsNotifier(ref);
});

/// Just the set of peers we have a live reliable channel to. Used by the
/// chat list's `isOnline` check.
final connectedPeerIdsProvider = Provider<Set<String>>((ref) {
  return ref.watch(
    connectionsNotifierProvider.select((s) => s.connectedPeerIds),
  );
});

// ─── Messaging bridge ───────────────────────────────────────────

/// Callback bag supplied by the messaging layer once it's constructed.
/// Mirrors the `handlersRef.current` object from JS usePeer — Dart doesn't
/// need a mutable ref, just a single setter on the notifier. Until the
/// messaging layer calls [ConnectionsNotifier.bindMessaging], the registry
/// uses [MessagingBridge.empty] which no-ops every callback so the first
/// packet arriving before messaging boots doesn't crash.
class MessagingBridge {
  const MessagingBridge({
    required this.pushInbound,
    required this.patchMessage,
    required this.queueAckStatus,
    required this.flushOutboxForPeer,
    required this.loadPendingForPeer,
    required this.applyTyping,
    this.isPeerBlocked = _notBlocked,
  });

  final Future<InboundPersistResult> Function(
    String remoteId,
    Map<String, Object?> uiMsg,
  ) pushInbound;
  final void Function(String remoteId, String id, Map<String, Object?> patch)
      patchMessage;
  final void Function(String msgId, String status) queueAckStatus;
  final Future<void> Function(String remoteId) flushOutboxForPeer;
  final Future<void> Function(String remoteId) loadPendingForPeer;
  final void Function(String remoteId, bool isTyping) applyTyping;
  final bool Function(String peerId) isPeerBlocked;

  static bool _notBlocked(String _) => false;

  static MessagingBridge get empty => MessagingBridge(
        pushInbound: (_, __) async => InboundPersistResult.failed,
        patchMessage: (_, __, ___) {},
        queueAckStatus: (_, __) {},
        flushOutboxForPeer: (_) async {},
        loadPendingForPeer: (_) async {},
        applyTyping: (_, __) {},
      );
}

// ─── Drop bridge ────────────────────────────────────────────────

/// Callback bag supplied by the Orbits-Drop layer ([DropNotifier]) so the
/// connection registry can forward inbound file-transfer frames without a
/// provider cycle. No-ops until [ConnectionsNotifier.bindDrop] is called.
class DropBridge {
  const DropBridge({
    required this.handleInbound,
    this.resetPeer,
  });

  /// Receives a control [Map] (`file-start`/`file-end`/`file-abort`) or a
  /// binary chunk [Uint8List] for [remoteId].
  final void Function(String remoteId, Object packet) handleInbound;

  /// Drop in-flight transfers for [remoteId] (disconnect / block).
  final void Function(String remoteId)? resetPeer;

  static DropBridge get empty => const DropBridge(handleInbound: _noop);
  static void _noop(String _, Object __) {}
}

// ─── Room bridge ────────────────────────────────────────────────

/// Callback bag supplied by [RoomManager] so the connection registry can
/// forward inbound `room_*` control packets without a provider cycle. No-ops
/// until [ConnectionsNotifier.bindRoom] is called.
class RoomBridge {
  const RoomBridge({required this.handleInbound});

  /// Receives a plaintext `room_*` control map for [remoteId]. Returns a
  /// Future so callers can await full settlement (production fires it
  /// forget-style; the router's `roomInbound` is a `void` hook).
  final Future<void> Function(String remoteId, Map<String, Object?> packet)
      handleInbound;

  static RoomBridge get empty => const RoomBridge(handleInbound: _noop);
  static Future<void> _noop(String _, Map<String, Object?> __) async {}
}

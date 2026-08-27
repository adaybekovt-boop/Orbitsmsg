// Port of src/peer/peerConnectionManager.js — owns the PeerJS lifecycle:
// instance creation, signaling host rotation, reconnect backoff, online /
// visibility handlers. Wraps [PeerJsClient] from peerjs_client.dart.
//
// The React build swallows transient signal-server noise after the first
// successful connect to avoid scaring the user; we keep that state machine
// here (_hasEverConnected, _signalNoiseStreak, _signalNoiseClearTimer) so
// behavior stays consistent across platforms.

import 'dart:async';
import 'dart:math';

import 'helpers.dart';
import 'multi_tab_lock.dart';
import 'peerjs_client.dart';
import 'signaling.dart';

typedef VoidCb = void Function();
typedef StatusCb = void Function(String status);
typedef StringCb = void Function(String? s);
typedef ErrorCb = void Function(Object err);
typedef PeerCb = void Function(String peerId, PeerJsClient peer);

/// The callback bag. Matches the shape of the `callbacks` object in JS.
class PeerManagerCallbacks {
  final StatusCb? setStatus;
  final StringCb? setError;
  final StringCb? setPeerId;
  final StringCb? setSignalingHost;
  final PeerCb? onOpen;
  final void Function(PeerDataConnection conn)? onConnection;
  final void Function(PeerMediaConnection call)? onCall;
  final ErrorCb? onError;
  final VoidCb? onMultiTabLost;
  final void Function(PeerJsClient? peer)? onBeforeDestroy;
  final VoidCb? onVisible;

  const PeerManagerCallbacks({
    this.setStatus,
    this.setError,
    this.setPeerId,
    this.setSignalingHost,
    this.onOpen,
    this.onConnection,
    this.onCall,
    this.onError,
    this.onMultiTabLost,
    this.onBeforeDestroy,
    this.onVisible,
  });
}

class PeerConnectionManager {
  final String desiredPeerId;
  final PeerEnv env;
  final PeerManagerCallbacks cb;

  /// Mirror of JS `isDropInProgressRef` — used to skip reconnect/disconnect
  /// while a file transfer is live, so we don't destroy the DataChannel.
  bool isDropInProgress = false;

  PeerJsClient? peer;
  MultiTabLock? multiTabLock;
  List<String>? signalingHosts;
  int signalingIndex = 0;
  Timer? _reconnectTimer;
  int reconnectAttempt = 0;
  int networkErrStreak = 0;

  /// How many times we've rotated the signaling host without a successful
  /// connect since the last OPEN. Drives the explicit "all hosts unreachable"
  /// signal (audit finding 5) so we don't loop the same 3 public relays
  /// silently forever. Reset to 0 on a successful OPEN.
  int _hostRotationCount = 0;
  int _lastNetworkErrAt = 0;
  bool _hasEverConnected = false;
  int _signalNoiseStreak = 0;
  Timer? _signalNoiseClearTimer;
  Timer? _initialConnectTimer;
  bool _swapping = false;
  List<StreamSubscription<dynamic>>? _subs;
  final Random _jitter = Random.secure();

  // ── Swap throttle (audit M5) ──
  // `swapPeerId` tears down the whole client+socket and rebuilds it. An
  // `unavailable-id` flap combined with host rotation could otherwise spin a
  // tight destroy/recreate loop against the public relay. Cap swaps per window.
  static const int _maxSwapsPerWindow = 6;
  static const int _swapWindowMs = 30000;
  final List<int> _swapTimes = <int>[];

  PeerConnectionManager({
    required String desiredPeerId,
    required this.env,
    required this.cb,
  }) : desiredPeerId = normalizePeerId(desiredPeerId);

  String get currentPeerId => peer?.id ?? desiredPeerId;

  /// Start the PeerJS pipeline. Returns null if a multi-tab lock conflict was
  /// detected (caller should set status=multitab).
  Future<PeerJsClient?> start() async {
    signalingHosts ??= buildSignalingHosts(env);
    final currentHost = signalingHosts![signalingIndex];
    cb.setSignalingHost?.call(env.peerServer ?? currentHost);

    multiTabLock = MultiTabLock(
      desiredPeerId,
      onLost: () {
        cb.setStatus?.call('multitab');
        cb.setError?.call('Открыта другая вкладка с этим Peer ID');
        unawaited(peer?.destroy());
        peer = null;
        cb.onMultiTabLost?.call();
      },
    );
    final acquired = await multiTabLock!.acquire();
    if (!acquired) {
      cb.setStatus?.call('multitab');
      cb.setError?.call('Открыта другая вкладка с этим Peer ID');
      return null;
    }

    cb.setStatus?.call('connecting');
    cb.setError?.call(null);
    reconnectAttempt = 0;

    final newPeer = await _createPeerNow(desiredPeerId);
    peer = newPeer;
    _attachHandlers(newPeer);
    await newPeer.start();

    // Initial connection timeout: if the signaling server doesn't respond
    // within 30s, surface an error instead of spinning "connecting" forever.
    _initialConnectTimer?.cancel();
    _initialConnectTimer = Timer(const Duration(seconds: 30), () {
      _initialConnectTimer = null;
      final p = peer;
      if (p != null && !p.open && !p.destroyed) {
        cb.setStatus?.call('disconnected');
        cb.setError
            ?.call('Не удалось подключиться к серверу — проверьте интернет');
      }
    });

    return newPeer;
  }

  /// Full teardown. Cancels timers, detaches stream subscriptions, releases
  /// the multi-tab lock and destroys the peer. Safe to call multiple times.
  Future<void> stop() async {
    _initialConnectTimer?.cancel();
    _reconnectTimer?.cancel();
    _signalNoiseClearTimer?.cancel();
    _initialConnectTimer = null;
    _reconnectTimer = null;
    _signalNoiseClearTimer = null;

    final lock = multiTabLock;
    multiTabLock = null;
    if (lock != null) unawaited(lock.release());

    final p = peer;
    peer = null;
    _detachHandlers();
    if (p != null) {
      try {
        await p.destroy();
      } catch (_) {}
    }
  }

  /// Recreate peer under a new id. Used for host rotation and
  /// `unavailable-id` recovery. Mirrors swapPeerId in JS.
  Future<void> swapPeerId(String nextId) async {
    if (_swapping) return;
    if (isDropInProgress) return;
    // Rate-limit full client rebuilds. If we've swapped too often recently,
    // skip this one and fall back to a backed-off plain reconnect so a flapping
    // id/host can't drive a reconnect storm (audit M5).
    final now = DateTime.now().millisecondsSinceEpoch;
    _swapTimes.removeWhere((t) => now - t > _swapWindowMs);
    if (_swapTimes.length >= _maxSwapsPerWindow) {
      _scheduleReconnect('error');
      return;
    }
    _swapTimes.add(now);
    _swapping = true;
    try {
      final old = peer;
      _detachHandlers();
      if (old != null) {
        try {
          await old.destroy();
        } catch (_) {}
      }
      final np = await _createPeerNow(nextId);
      peer = np;
      _attachHandlers(np);
      try {
        await np.start();
      } catch (_) {}
    } finally {
      _swapping = false;
    }
  }

  /// Trigger a reconnect on the current peer (network-change path).
  void reconnectNow() {
    final p = peer;
    if (p == null || p.destroyed) return;
    try {
      p.reconnect();
    } catch (_) {}
  }

  // ─── Reconnect / error state machine ─────────────────────────────
  //
  // Mirrors onError() in peerConnectionManager.js:129-222 — the UX logic
  // must be preserved verbatim:
  //   - unavailable-id → fast silent retry for ~16s (F5 zombie recovery)
  //   - signal-server/socket-error after first connect → swallow up to 5x,
  //     show "connecting…" not red banner, auto-clear after 10s of quiet
  //   - network errors → streak counter, rotate hosts after 2 hits if allowed
  //   - every other error → show via mapPeerError

  void _scheduleReconnect(String reason) {
    if (isDropInProgress) return;
    final p = peer;
    if (p != null && p.open && reason != 'offline') return;
    _reconnectTimer?.cancel();
    final attempt = reconnectAttempt;
    reconnectAttempt = (attempt + 1).clamp(0, 10);
    final delay = computeBackoffMs(attempt);
    cb.setStatus?.call(reason == 'offline' ? 'disconnected' : 'connecting');
    _reconnectTimer = Timer(Duration(milliseconds: delay), () {
      if (isDropInProgress) return;
      final cur = peer;
      if (cur == null || cur.destroyed) return;
      if (cur.open) {
        reconnectAttempt = 0;
        cb.setStatus?.call('connected');
        cb.setError?.call(null);
        return;
      }
      try {
        cur.reconnect();
      } catch (_) {}
    });
  }

  Future<PeerJsClient> _createPeerNow(String id) async {
    final host = signalingHosts?[signalingIndex] ?? '';
    final endpoint = resolveEndpoint(host: host, env: env);
    final rtc = buildRtcConfig(env);
    if (rtc.iceTransportPolicy != 'relay' && env.relayOnly) {
      throw const RelayOnlyUnavailable();
    }
    return PeerJsClient(
      id: id,
      endpoint: endpoint,
      iceServers: rtc.iceServers,
      iceTransportPolicy: rtc.iceTransportPolicy,
    );
  }

  // ─── Handler plumbing ────────────────────────────────────────────

  void _attachHandlers(PeerJsClient p) {
    _subs = <StreamSubscription<dynamic>>[
      p.onOpen.listen(_handleOpen),
      p.onDisconnected.listen((_) => _scheduleReconnect('disconnected')),
      p.onClose.listen((_) => cb.setStatus?.call('disconnected')),
      p.onError.listen(_handleError),
      p.onConnection.listen((c) => cb.onConnection?.call(c)),
      p.onCall.listen((c) => cb.onCall?.call(c)),
    ];
  }

  void _detachHandlers() {
    final subs = _subs;
    _subs = null;
    if (subs == null) return;
    for (final s in subs) {
      try {
        s.cancel();
      } catch (_) {}
    }
  }

  void _handleOpen(String id) {
    _initialConnectTimer?.cancel();
    _initialConnectTimer = null;
    reconnectAttempt = 0;
    networkErrStreak = 0;
    _lastNetworkErrAt = 0;
    _hostRotationCount = 0;
    _hasEverConnected = true;
    _signalNoiseStreak = 0;
    _signalNoiseClearTimer?.cancel();
    _signalNoiseClearTimer = null;
    final normalized = normalizePeerId(id);
    cb.setPeerId?.call(normalized);
    cb.setStatus?.call('connected');
    cb.setError?.call(null);
    final p = peer;
    if (p != null) cb.onOpen?.call(normalized, p);
  }

  void _handleError(PeerError err) {
    // ── unavailable-id: silent fast-retry (F5 zombie recovery) ─────
    if (err.type == 'unavailable-id') {
      _reconnectTimer?.cancel();
      final attempt = reconnectAttempt;
      reconnectAttempt = (attempt + 1).clamp(0, 15);
      // Keep the first few retries fast (F5 / zombie-id recovery: the server
      // may still briefly hold the old id), then fall back to exponential
      // backoff so we don't hammer the public relay (audit M5).
      final delay = attempt < 3
          ? 1500 + _jitter.nextInt(1000)
          : computeBackoffMs(attempt - 3, base: 2000, maxMs: 30000);
      cb.setStatus?.call('connecting');
      if (attempt < 8) {
        cb.setError?.call(null);
      } else {
        cb.setError?.call('Переподключаемся к серверу…');
      }
      _reconnectTimer = Timer(Duration(milliseconds: delay), () {
        unawaited(swapPeerId(currentPeerId));
      });
      return;
    }

    // ── Generic error handling ────────────────────────────────────
    final isSignalNoise =
        err.type == 'server-error' || err.type == 'socket-error';
    final transient = isSignalNoise ||
        err.type == 'network' ||
        err.type == 'peer-unavailable';

    final p = peer;
    if (transient && p != null && p.open) {
      cb.onError?.call(err);
    } else if (isSignalNoise &&
        _hasEverConnected &&
        _signalNoiseStreak < 5) {
      _signalNoiseStreak += 1;
      cb.setStatus?.call('connecting');
      cb.setError?.call(null);
      _signalNoiseClearTimer?.cancel();
      _signalNoiseClearTimer = Timer(const Duration(seconds: 10), () {
        _signalNoiseClearTimer = null;
        _signalNoiseStreak = 0;
      });
      cb.onError?.call(err);
    } else {
      if (isSignalNoise) _signalNoiseStreak += 1;
      cb.setError?.call(mapPeerError(err.toMap()));
      cb.onError?.call(err);
    }

    final t = DateTime.now().millisecondsSinceEpoch;
    if (err.type == 'network' ||
        err.type == 'server-error' ||
        err.type == 'socket-error') {
      if (p != null && p.open) return;
      final delta = t - _lastNetworkErrAt;
      _lastNetworkErrAt = t;
      networkErrStreak = delta < 12000 ? networkErrStreak + 1 : 1;
      final hosts = signalingHosts;
      if (hosts != null &&
          canRotateHosts(env, hosts) &&
          networkErrStreak >= 2) {
        networkErrStreak = 0;
        signalingIndex = (signalingIndex + 1) % hosts.length;
        _hostRotationCount += 1;
        if (_hostRotationCount >= hosts.length * 2) {
          // Cycled through every signaling host ≥2× with no successful
          // connect — surface an explicit "all servers unreachable" signal
          // instead of looping the same hosts silently (audit finding 5).
          // Reconnect/backoff still continues underneath.
          cb.setError?.call(
            'Не удаётся подключиться ни к одному серверу связи. '
            'Проверьте интернет или настройте свой сервер.',
          );
          _hostRotationCount = 0; // re-warn once per full re-cycle, not per hop
        }
        final nextHost = hosts[signalingIndex];
        cb.setSignalingHost?.call(nextHost);
        cb.setStatus?.call('connecting');
        unawaited(swapPeerId(currentPeerId));
        return;
      }
      _scheduleReconnect('error');
    }
  }
}

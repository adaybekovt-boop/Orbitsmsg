// Riverpod lifecycle wrapper around [PeerConnectionManager]. Translates the
// bag-of-callbacks constructor PeerJS prefers into something the widget tree
// can read: a single `PeerConnectionState` value that the PeerStatusPill and
// header can watch with a one-liner.
//
// Why a StateNotifier instead of `Provider + manual state`:
//   - We need to emit status/error/peerId/signalingHost updates, the manager
//     hands us those via callbacks, and a StateNotifier lets us fold all
//     four into one reactive state object without four separate providers.
//   - `ref.listen(authNotifierProvider)` + notifier lifecycle makes it easy
//     to `start()` on AuthAuthed and `stop()` on logout/wipe without the
//     widget tree having to orchestrate anything.
//
// The manager itself stays a plain Dart class — it's already well-tested by
// the peer package and shouldn't know about Riverpod.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../peer/connectivity_watch_stub.dart'
    if (dart.library.html) '../peer/connectivity_watch_web.dart';
import '../peer/peer_connection_manager.dart';
import '../peer/peerjs_client.dart';
import '../peer/relay_transport.dart';
import '../peer/signaling.dart';
import '../peer/ws_relay_transport.dart';
import 'auth_notifier.dart';

/// Snapshot of the peer subsystem. Mirrors the flat-ish object the JS
/// `PeerProvider` exposed via `useConnections()`.
class PeerConnectionState {
  const PeerConnectionState({
    required this.status,
    required this.peerId,
    required this.signalingHost,
    required this.error,
  });

  const PeerConnectionState.idle()
      : status = 'idle',
        peerId = null,
        signalingHost = null,
        error = null;

  /// One of: idle / connecting / connected / disconnected / multitab.
  /// Kept as a String (not enum) for parity with the JS layer — the pill
  /// widget already has a string→color mapping we'll reuse.
  final String status;
  final String? peerId;
  final String? signalingHost;
  final String? error;

  PeerConnectionState copyWith({
    String? status,
    Object? peerId = _unset,
    Object? signalingHost = _unset,
    Object? error = _unset,
  }) =>
      PeerConnectionState(
        status: status ?? this.status,
        peerId: identical(peerId, _unset) ? this.peerId : peerId as String?,
        signalingHost: identical(signalingHost, _unset)
            ? this.signalingHost
            : signalingHost as String?,
        error: identical(error, _unset) ? this.error : error as String?,
      );
}

/// Sentinel so copyWith can tell "caller passed null" from "caller omitted".
const Object _unset = Object();

class PeerConnectionNotifier extends StateNotifier<PeerConnectionState> {
  PeerConnectionNotifier({required this.env})
      : super(const PeerConnectionState.idle()) {
    _installWatchdog();
  }

  final PeerEnv env;
  PeerConnectionManager? _manager;
  bool _disposed = false;

  // ── Connectivity watchdog ──
  // On web the browser owns WS keepalive (no pingInterval), so a half-open
  // socket after a network drop lingers until the slow TCP timeout. We nudge
  // an immediate reconnect on two real signals — the app returning to the
  // foreground (lifecycle `resumed`, cross-platform) and the browser `online`
  // event (web) — instead of a silence timer, which would false-positive on a
  // healthy-but-idle link and spin a reconnect storm (audit M5). The nudge is
  // gated to the `disconnected` state so it never disturbs a live connection
  // or an in-flight `connecting` attempt.
  _ResumeObserver? _resumeObserver;
  Object? _onlineHandle;

  void _installWatchdog() {
    try {
      final obs = _ResumeObserver(_nudgeReconnect);
      WidgetsBinding.instance.addObserver(obs);
      _resumeObserver = obs;
    } catch (_) {
      // No binding (e.g. headless test harness) — skip; not load-bearing.
    }
    _onlineHandle = watchOnline(_nudgeReconnect);
  }

  void _nudgeReconnect() {
    if (_disposed) return;
    // Only act when we KNOW we're offline. 'connected' must not be disturbed;
    // 'connecting' is already retrying; 'idle'/'multitab' aren't our concern.
    if (state.status != 'disconnected') return;
    _manager?.reconnectNow();
  }

  /// Serialize overlapping `start()` calls. Without this, two rapid calls
  /// with different ids would both see `_manager == null` during each
  /// other's async teardown window and construct a second manager. The lock
  /// is a Future chain: each call awaits the previous one's completion
  /// before reading `_manager`.
  Future<void> _startChain = Future.value();

  /// Start (or restart) the peer pipeline for `peerId`. Safe to call
  /// repeatedly — subsequent calls with the same id are no-ops, and calls
  /// with a different id tear down and recreate.
  Future<void> start(String peerId) {
    final next = _startChain.then((_) => _startLocked(peerId));
    // Don't let one failure poison the chain — every pending caller should
    // still get its own shot.
    _startChain = next.catchError((_) {});
    return next;
  }

  Future<void> _startLocked(String peerId) async {
    if (_disposed) return;
    final existing = _manager;
    if (existing != null && existing.desiredPeerId == peerId) return;
    if (existing != null) await _teardown();

    final manager = PeerConnectionManager(
      desiredPeerId: peerId,
      env: env,
      cb: PeerManagerCallbacks(
        setStatus: (s) {
          if (!_disposed) state = state.copyWith(status: s);
        },
        setError: (e) {
          if (!_disposed) state = state.copyWith(error: e);
        },
        setPeerId: (id) {
          if (!_disposed) state = state.copyWith(peerId: id);
        },
        setSignalingHost: (h) {
          if (!_disposed) state = state.copyWith(signalingHost: h);
        },
        onOpen: (_, __) {
          // Status is already switched to 'connected' inside the manager via
          // setStatus; nothing else to wire here until wire-transport lands.
        },
        onError: (_) {
          // Same — manager already routed the user-facing string to setError.
        },
      ),
    );
    _manager = manager;
    state = const PeerConnectionState.idle().copyWith(
      status: 'connecting',
      peerId: peerId,
    );
    try {
      await manager.start();
    } catch (err) {
      if (!_disposed) {
        state = state.copyWith(
          status: 'disconnected',
          error: 'Ошибка старта: $err',
        );
      }
    }
  }

  /// Stop the pipeline and reset to idle. Called on logout/wipe. Chained
  /// through the same serializer as `start()` so a quick logout-then-login
  /// can't leave the pipeline in a half-torn state.
  Future<void> stop() {
    final next = _startChain.then((_) => _stopLocked());
    _startChain = next.catchError((_) {});
    return next;
  }

  Future<void> _stopLocked() async {
    if (_manager == null) {
      if (!_disposed) state = const PeerConnectionState.idle();
      return;
    }
    await _teardown();
    if (!_disposed) state = const PeerConnectionState.idle();
  }

  /// Manual nudge from a "reconnect" button.
  void reconnectNow() => _manager?.reconnectNow();

  /// Direct peer handle — exposed for the wire-transport layer that will
  /// listen on `onConnection` / `onCall` once ported. UI code shouldn't
  /// reach into this.
  PeerJsClient? get rawPeer => _manager?.peer;

  Future<void> _teardown() async {
    final m = _manager;
    _manager = null;
    if (m != null) {
      try {
        await m.stop();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final obs = _resumeObserver;
    if (obs != null) {
      try {
        WidgetsBinding.instance.removeObserver(obs);
      } catch (_) {}
      _resumeObserver = null;
    }
    unwatchOnline(_onlineHandle);
    _onlineHandle = null;
    // Fire-and-forget — we can't await in dispose(), but the manager's stop()
    // is resilient to being cancelled mid-flight.
    unawaited(_teardown());
    super.dispose();
  }
}

/// Observes app-lifecycle transitions and fires [onResume] when the app/tab
/// returns to the foreground — the cross-platform half of the connectivity
/// watchdog (the web `online` event covers network-restored-while-foregrounded).
class _ResumeObserver extends WidgetsBindingObserver {
  _ResumeObserver(this.onResume);
  final void Function() onResume;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}

/// Env knobs come from `--dart-define` at build time. All fields are
/// optional — the manager falls back to public PeerJS hosts if nothing is
/// provided. Overriding only the TURN credentials is a common prod setup.
///
/// We avoid `bool.hasEnvironment` entirely: DDC (the web dev compiler) only
/// tolerates it inside a const expression, and wrapping these in a ternary
/// trips DDC's "can only be used as a const constructor" runtime check.
/// Instead each knob gets a sentinel default and we treat empty as "absent".
String? _envString(String value) => value.isEmpty ? null : value;
int? _envInt(int value) => value < 0 ? null : value;

/// Split a comma/space/semicolon-separated env value into a clean list, or null
/// when empty. Used for `TURN_URLS`.
List<String>? _envList(String value) {
  if (value.isEmpty) return null;
  final parts = value
      .split(RegExp(r'[,;\s]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  return parts.isEmpty ? null : parts;
}

const _peerServerRaw = String.fromEnvironment('PEER_SERVER');
const _peerHostRaw = String.fromEnvironment('PEER_HOST');
const _peerPathRaw = String.fromEnvironment('PEER_PATH');
const _peerPortRaw = int.fromEnvironment('PEER_PORT', defaultValue: -1);
const _peerSecureSet = bool.fromEnvironment('PEER_SECURE_SET');
const _peerSecureRaw = bool.fromEnvironment('PEER_SECURE');
const _turnUrlRaw = String.fromEnvironment('TURN_URL');
const _turnUrlsRaw = String.fromEnvironment('TURN_URLS');
const _turnUserRaw = String.fromEnvironment('TURN_USERNAME');
const _turnCredRaw = String.fromEnvironment('TURN_CREDENTIAL');

final _env = PeerEnv(
  peerServer: _envString(_peerServerRaw),
  peerHost: _envString(_peerHostRaw),
  peerPath: _envString(_peerPathRaw),
  peerPort: _envInt(_peerPortRaw),
  // PEER_SECURE is a tri-state: unset / true / false. Callers that need to
  // force it off pass `--dart-define=PEER_SECURE_SET=true --dart-define=PEER_SECURE=false`.
  peerSecure: _peerSecureSet ? _peerSecureRaw : null,
  turnUrl: _envString(_turnUrlRaw),
  // Multiple TURN transports (udp/tcp/tls-443) under one credential.
  turnUrls: _envList(_turnUrlsRaw),
  turnUsername: _envString(_turnUserRaw),
  turnCredential: _envString(_turnCredRaw),
  relayOnly: const bool.fromEnvironment('RELAY_ONLY', defaultValue: false),
);

/// Whether a usable TURN relay is configured in THIS build (≥1 URL + creds,
/// via `--dart-define`). Without TURN, WebRTC across different NATs/networks
/// (phone mobile-data ↔ PC behind a router) can fail — surfaced in diagnostics.
final turnConfiguredProvider =
    Provider<bool>((ref) => hasTurnConfigured(_env));

/// Number of distinct TURN URLs (transports) configured. 0 when none.
final turnUrlCountProvider = Provider<int>((ref) => turnUrlsFor(_env).length);

/// Whether this build requests relay-only ICE.
final relayOnlyProvider = Provider<bool>((ref) => _env.relayOnly);

/// True when RELAY_ONLY was set but no usable TURN exists — a misconfiguration:
/// the app falls back to a normal ICE policy (so it still connects directly)
/// and shows a warning rather than producing a config that can't connect.
final relayOnlyMisconfiguredProvider =
    Provider<bool>((ref) => relayOnlyMisconfigured(_env));

// ─── Encrypted text relay fallback (Phase 2) ────────────────────────
const _relayUrlRaw = String.fromEnvironment('RELAY_URL');
final _relayUrl = _envString(_relayUrlRaw);

/// The encrypted-text relay fallback transport. Disabled (no-op) unless
/// `RELAY_URL` is set — the app is fully functional WebRTC-only without it.
/// Overridable in tests with a fake transport.
final relayTransportProvider = Provider<RelayTransport>((ref) {
  final url = _relayUrl;
  if (url == null || url.isEmpty) return const DisabledRelayTransport();
  final t = WsRelayTransport(url);
  ref.onDispose(() => unawaited(t.dispose()));
  return t;
});

/// Whether an encrypted relay fallback is configured for this build.
final relayConfiguredProvider =
    Provider<bool>((ref) => ref.watch(relayTransportProvider).isConfigured);

final peerConnectionProvider =
    StateNotifierProvider<PeerConnectionNotifier, PeerConnectionState>((ref) {
  final notifier = PeerConnectionNotifier(env: _env);

  // Watch auth: start the pipeline when the user unlocks, stop on
  // logout/wipe. `ref.listen` (not watch) so we fire side-effects only on
  // transitions, not on every rebuild of an unrelated consumer.
  ref.listen<AuthState>(
    authNotifierProvider,
    (prev, next) {
      if (next is AuthAuthed) {
        unawaited(notifier.start(next.user.peerId));
      } else if (prev is AuthAuthed && next is! AuthAuthed) {
        unawaited(notifier.stop());
      }
    },
    fireImmediately: true,
  );

  return notifier;
});

/// Convenience selector — most UI only cares about the single status string.
final peerStatusProvider = Provider<String>((ref) {
  return ref.watch(peerConnectionProvider.select((s) => s.status));
});

// Port of `src/peer/multiTabLock.js`.
//
// Guards a peerId against being claimed by a second live instance (a second
// browser tab on web, a second copy of the app on desktop). The moment
// another instance writes a fresher token under the same lock key, [onLost]
// fires and the caller should drop the PeerJS connection before the server
// boots us with `unavailable-id`.
//
// Storage strategy:
// - Web / desktop / mobile — [SharedPreferences]. On web this layers on
//   `localStorage`, which is what the JS build uses, so a browser user who
//   opens the Flutter web build in a second tab sees the same conflict
//   record. On native it's per-app storage; a second copy of the app would
//   typically not even start (single-instance launch modes on Android / iOS),
//   so the lock mostly guards against simultaneous launches across devices
//   that somehow share the same peerId — which is still a server-side
//   collision worth detecting.
//
// What we drop relative to the JS version:
// - `window.addEventListener('storage', ...)` — not a thing outside a
//   browser. We fall back to a polling refresh (every [_refreshMs]) that
//   re-reads the slot on each tick; takeovers are detected within one
//   refresh cycle. Worst-case detection latency is [_refreshMs] instead of
//   "immediate", which is fine for this use case.
// - `navigator.locks.request(...)` keep-alive — only meaningful to stop a
//   browser from freezing background-tab connections. Native Flutter has
//   no equivalent hazard.
// - `sessionStorage`-based F5 detection — page reloads are a web concept.
//   On native, an app restart gets a fresh process + new token, and the
//   previous lock (if still fresh) will rightly be respected.
//
// Wire format stays identical so a JS-side tab and a Flutter-web tab can
// observe each other's locks:
//
//   key:   'orbits_peer_lock:<peerId>'      (from StorageKeys.peerLockPrefix)
//   value: '{"token":"<hex>","ts":<ms>}'

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';
import 'web_lock_stub.dart'
    if (dart.library.js_interop) 'web_lock_web.dart';

const int _refreshMs = 2000;
const int _staleMs = 4500;

class _LockRecord {
  const _LockRecord({required this.token, required this.ts});
  final String token;
  final int ts;
}

/// Advisory "only one live instance of this peerId" lock backed by
/// [SharedPreferences]. Not a mutex — two near-simultaneous acquires from
/// cold start can both briefly believe they own the slot until the next
/// refresh tick catches the collision. That's acceptable: the PeerJS
/// signaling server will reject the second one with `unavailable-id` and
/// [onLost] will fire anyway once it loses the token race.
class MultiTabLock {
  MultiTabLock(this.peerId, {this.onLost})
      : _lockKey = '${StorageKeys.peerLockPrefix}$peerId',
        _token = _generateToken();

  /// The peerId whose slot we're guarding. Exposed for debug / logging.
  final String peerId;

  /// Fires exactly once when we detect a competing fresh token. After this
  /// the internal refresh timer is cancelled, so the object effectively
  /// self-disables — the caller should invoke [release] as part of their
  /// teardown anyway.
  final void Function()? onLost;

  final String _lockKey;
  final String _token;

  /// Web Locks API name (browser only). Distinct namespace from the
  /// SharedPreferences [_lockKey] — the two mechanisms run in parallel.
  String get _webLockName => 'orbits_peer_lock_$peerId';

  Timer? _refreshTimer;
  bool _lost = false;

  // ─── Public API ───────────────────────────────────────────────────

  /// Try to claim the slot. Returns `true` if the slot was empty, stale
  /// (last refresh > [_staleMs] ago), or already held by us; `false` if a
  /// different fresh token is present — caller should surface the multitab
  /// UI state instead of connecting.
  Future<bool> acquire() async {
    // Web Locks API first (browser): a true exclusive lock that's race-free at
    // cold start, where two tabs launching together can both win the
    // SharedPreferences check. On native this is a no-op that returns true.
    // If another tab holds the exclusive lock, bail before connecting.
    final webGranted = await acquireWebLock(_webLockName);
    if (!webGranted) return false;

    final prefs = await SharedPreferences.getInstance();
    final existing = _readLock(prefs);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (existing != null &&
        existing.token != _token &&
        now - existing.ts < _staleMs) {
      return false;
    }
    await _writeLock(prefs);
    _startRefreshTimer();
    return true;
  }

  /// Write our token immediately. Useful on app-foreground / visibility
  /// transitions so a sleeping tab that just woke up doesn't have to wait
  /// up to [_refreshMs] before refreshing its claim.
  Future<void> touch() async {
    if (_lost) return;
    final prefs = await SharedPreferences.getInstance();
    await _writeLock(prefs);
  }

  /// Stop refreshing and clear the slot (only if we still own it — we
  /// never want to overwrite someone else's fresh claim on the way out).
  Future<void> release() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    // Drop the browser Web Lock (no-op on native). Safe to call even if we
    // never held it.
    releaseWebLock(_webLockName);
    if (_lost) return;
    final prefs = await SharedPreferences.getInstance();
    final cur = _readLock(prefs);
    if (cur != null && cur.token == _token) {
      await prefs.remove(_lockKey);
    }
  }

  // ─── Internals ────────────────────────────────────────────────────

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(milliseconds: _refreshMs),
      (_) => unawaited(_tick()),
    );
  }

  Future<void> _tick() async {
    if (_lost) return;
    final prefs = await SharedPreferences.getInstance();
    final cur = _readLock(prefs);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (cur != null &&
        cur.token != _token &&
        now - cur.ts < _staleMs) {
      _lost = true;
      _refreshTimer?.cancel();
      _refreshTimer = null;
      try {
        onLost?.call();
      } catch (_) {
        // Caller exceptions are not this module's problem — the JS version
        // also ignores them (the handler is called outside any try frame).
      }
      return;
    }
    await _writeLock(prefs);
  }

  Future<void> _writeLock(SharedPreferences prefs) async {
    final payload = jsonEncode({
      'token': _token,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    await prefs.setString(_lockKey, payload);
  }

  _LockRecord? _readLock(SharedPreferences prefs) {
    final raw = prefs.getString(_lockKey);
    if (raw == null) return null;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map) return null;
      final token = parsed['token'];
      final ts = parsed['ts'];
      if (token is! String || ts is! num) return null;
      return _LockRecord(token: token, ts: ts.toInt());
    } catch (_) {
      return null;
    }
  }

  /// 16 hex chars of CSPRNG randomness — ~64 bits of entropy, same
  /// ballpark as `Math.random().toString(36).slice(2)` in the JS version
  /// but using `Random.secure()` instead of a non-crypto PRNG.
  static String _generateToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(8, (_) => rng.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

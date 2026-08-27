// Wraps the authed app subtree and re-locks the vault after idle / background.
//
// Two triggers, both honest and safe:
//   • Foreground inactivity: a Timer(idleTimeout) reset on every pointer event;
//     when it fires, lock.
//   • Return from background: on pause we stamp the wall clock; on resume, if
//     we were away >= idleTimeout, lock. (Wall-clock, not a Timer — OS suspends
//     Dart timers in the background, so a backgrounded Timer can't be trusted.)
//
// Locking clears only the in-memory KEK and returns to the password screen
// (see AuthNotifier.lock) — the profile and all data stay on disk. We never
// clear the KEK WHILE backgrounded (background network ops may still need it);
// the re-lock happens on the way back to the foreground or after foreground
// idle, when nothing is mid-flight.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/auth_notifier.dart';
import '../../state/auto_lock_provider.dart';

class AutoLockScope extends ConsumerStatefulWidget {
  const AutoLockScope({
    super.key,
    required this.child,
    this.onLock,
    this.clock,
  });

  final Widget child;

  /// Test seam: called instead of [AuthNotifier.lock] when provided.
  final Future<void> Function()? onLock;

  /// Test seam: wall clock used for the background-elapsed check.
  final DateTime Function()? clock;

  @override
  ConsumerState<AutoLockScope> createState() => _AutoLockScopeState();
}

class _AutoLockScopeState extends ConsumerState<AutoLockScope>
    with WidgetsBindingObserver {
  Timer? _idleTimer;
  DateTime? _backgroundedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    _resetIdleTimer();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    _onActivity();
    return false;
  }

  AutoLockSettings get _settings => ref.read(autoLockProvider);
  DateTime _now() => widget.clock?.call() ?? DateTime.now();

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    final s = _settings;
    if (!s.enabled) return;
    _idleTimer = Timer(s.idleTimeout, _lock);
  }

  void _onActivity([PointerEvent? _]) {
    if (_settings.enabled) _resetIdleTimer();
  }

  Future<void> _lock() async {
    _idleTimer?.cancel();
    if (widget.onLock != null) {
      await widget.onLock!();
    } else {
      await ref.read(authNotifierProvider.notifier).lock();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        final bg = _backgroundedAt;
        _backgroundedAt = null;
        final s = _settings;
        if (s.enabled && bg != null && _now().difference(bg) >= s.idleTimeout) {
          _lock();
        } else {
          _resetIdleTimer();
        }
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _idleTimer?.cancel();
        _backgroundedAt = _now();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // Transient / teardown — don't arm or disarm on these.
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // React to the toggle flipping at runtime without needing a remount.
    ref.listen<AutoLockSettings>(autoLockProvider, (prev, next) {
      if (next.enabled) {
        _resetIdleTimer();
      } else {
        _idleTimer?.cancel();
      }
    });
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onActivity,
      onPointerMove: _onActivity,
      child: widget.child,
    );
  }
}

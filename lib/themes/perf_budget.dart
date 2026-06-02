// Flutter port of `git_push/src/themes/usePerformanceBudget.js`.
//
// Single source of truth for "how hard can the active theme push the device
// right now". Background widgets read a `PerfBudget` and clamp their
// particle counts / disable motion accordingly.
//
// Inputs that can shift the tier mid-session:
//   - `MediaQuery.disableAnimations` (Flutter's prefers-reduced-motion)
//   - `WidgetsBinding.lifecycleState` (paused/inactive → freeze)
//   - device class (cores + ram, sniffed at boot via `Platform`)
//   - live frame timing (`SchedulerBinding.addTimingsCallback`) — degrade
//     once if the rolling fps drops below the manifest's `minFPS`.
//
// What we don't do (yet):
//   - Battery API. Flutter web has no equivalent of `navigator.getBattery`
//     and the mobile equivalents need a plugin (`battery_plus`). Skipping
//     for the launch — PerfBudget still degrades on FPS drop, which is the
//     symptom we actually care about.
//
// Surface:
//   - `perfBudgetProvider(manifest)` — Riverpod family that yields a
//     `PerfBudget` and keeps it live for the manifest in question.
//   - `PerfBudget.frozen` static — convenience for the "respect reduce-motion"
//     branch in widgets that don't want to wire the provider.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/power_saver_provider.dart';
import 'manifest.dart';

/// Tiered performance modes, mirroring the JS string union
/// `'full' | 'reduced' | 'frozen'`.
enum PerfTier {
  /// Full motion + max particles for the device class.
  full,

  /// Half-speed / fewer particles. Triggered by FPS drop, low-end device,
  /// or low battery (when the platform reports it).
  reduced,

  /// No motion. Static frame only — used when reduce-motion is on or the
  /// app is backgrounded.
  frozen,
}

/// Coarse device class read once at boot. Drives the manifest's particle
/// budget lookup (desktop > mobile > lowEnd).
enum _DeviceClass { desktop, mobile, lowEnd }

@immutable
class PerfBudget {
  const PerfBudget({
    required this.tier,
    required this.particles,
    required this.fpsCap,
    required this.motion,
    required this.reason,
  });

  /// Convenience for "respect reduce-motion at all costs". Use when wiring
  /// a static fallback widget — same shape any caller expects.
  static const PerfBudget frozen = PerfBudget(
    tier: PerfTier.frozen,
    particles: 0,
    fpsCap: 0,
    motion: false,
    reason: 'frozen',
  );

  final PerfTier tier;

  /// Max particle count the background should render. Already clamped to
  /// the device class — widgets just consume.
  final int particles;

  /// `0` = uncapped. Reduced tier suggests 30 fps.
  final int fpsCap;

  /// `false` → background should render a static frame and not animate.
  final bool motion;

  /// Why we're in the current tier — surfaced through telemetry / the
  /// debug overlay. Don't gate UX on this; use [tier] / [motion] instead.
  final String reason;
}

/// Family provider — one instance per active manifest. The provider
/// holds onto a `_PerfBudgetController` that listens to platform signals
/// and emits new `PerfBudget` values as they change.
///
/// `autoDispose` matters here: every theme switch creates a new family
/// member, and each controller owns a `WidgetsBinding` observer + a
/// `SchedulerBinding.addTimingsCallback` subscription. Without
/// autoDispose those linger forever — a user toggling between Graphite
/// and Sakura five times would end up with five live ticker callbacks
/// fighting for the same `state` slot. With autoDispose the previously-
/// active manifest's controller is torn down within one frame of the
/// last `ref.watch` going away.
final perfBudgetProvider = StateNotifierProvider.autoDispose
    .family<_PerfBudgetController, PerfBudget, ThemeManifest>(
  (ref, manifest) => _PerfBudgetController(manifest, ref),
);

/// Force the frozen tier when power-saver (lite mode) is on — the user has
/// explicitly asked for minimum load, so no animated background / motion
/// regardless of device class. Pure + [visibleForTesting].
@visibleForTesting
PerfBudget applyPowerSaver(PerfBudget base, bool powerSaver) {
  if (!powerSaver) return base;
  return const PerfBudget(
    tier: PerfTier.frozen,
    particles: 0,
    fpsCap: 0,
    motion: false,
    reason: 'power-saver',
  );
}

class _PerfBudgetController extends StateNotifier<PerfBudget>
    with WidgetsBindingObserver {
  _PerfBudgetController(this._manifest, this._ref)
      : super(_initialBudget(_manifest, _classifyDevice())) {
    _deviceClass = _classifyDevice();
    _liteMode = _ref.read(powerSaverProvider);
    _ref.listen<bool>(powerSaverProvider, (_, next) {
      if (_liteMode == next) return;
      _liteMode = next;
      _emit();
    });
    WidgetsBinding.instance.addObserver(this);
    _startFpsMonitor();
    _emit();
  }

  final ThemeManifest _manifest;
  final Ref _ref;
  late final _DeviceClass _deviceClass;
  bool _appVisible = true;
  bool _reducedMotion = false;
  bool _fpsDegraded = false;
  bool _liteMode = false;

  // FPS monitor state — two-second rolling window.
  TimingsCallback? _timingsCb;
  int _framesInWindow = 0;
  int _lowWindows = 0;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasVisible = _appVisible;
    _appVisible = state == AppLifecycleState.resumed;
    if (wasVisible != _appVisible) _emit();
  }

  /// Called by the app's `MediaQuery` watcher whenever
  /// `disableAnimations` flips. The notifier doesn't pull from MediaQuery
  /// itself because it's not in the widget tree.
  void setReducedMotion(bool value) {
    if (_reducedMotion == value) return;
    _reducedMotion = value;
    _emit();
  }

  void _startFpsMonitor() {
    if (_manifest.background == null) return;
    // Two-second rolling window measured via wall clock. The exact frame
    // phase (build vs raster) doesn't matter — we just want a count of
    // frames that landed in the period.
    _timingsCb = (List<FrameTiming> timings) {
      if (_fpsDegraded || !_appVisible || _reducedMotion) return;
      _framesInWindow += timings.length;
      final elapsed = DateTime.now().difference(_lastTickWall);
      if (elapsed.inMilliseconds < 2000) return;

      final fps = _framesInWindow * 1000 / elapsed.inMilliseconds;
      if (fps < _manifest.performance.minFPS) {
        _lowWindows += 1;
        if (_lowWindows >= 2) {
          _fpsDegraded = true;
          _emit();
        }
      } else {
        _lowWindows = 0;
      }
      _framesInWindow = 0;
      _lastTickWall = DateTime.now();
    };
    _lastTickWall = DateTime.now();
    SchedulerBinding.instance.addTimingsCallback(_timingsCb!);
  }

  DateTime _lastTickWall = DateTime.now();

  void _emit() {
    state = applyPowerSaver(
      _resolveBudget(
        manifest: _manifest,
        device: _deviceClass,
        reducedMotion: _reducedMotion,
        visible: _appVisible,
        fpsDegraded: _fpsDegraded,
      ),
      _liteMode,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_timingsCb != null) {
      SchedulerBinding.instance.removeTimingsCallback(_timingsCb!);
    }
    super.dispose();
  }
}

PerfBudget _initialBudget(ThemeManifest m, _DeviceClass dc) {
  return _resolveBudget(
    manifest: m,
    device: dc,
    reducedMotion: false,
    visible: true,
    fpsDegraded: false,
  );
}

PerfBudget _resolveBudget({
  required ThemeManifest manifest,
  required _DeviceClass device,
  required bool reducedMotion,
  required bool visible,
  required bool fpsDegraded,
}) {
  // Tier cascade — most-restrictive wins.
  if (reducedMotion) {
    return const PerfBudget(
      tier: PerfTier.frozen,
      particles: 0,
      fpsCap: 0,
      motion: false,
      reason: 'reduced-motion',
    );
  }
  if (!visible) {
    return const PerfBudget(
      tier: PerfTier.frozen,
      particles: 0,
      fpsCap: 0,
      motion: false,
      reason: 'app-hidden',
    );
  }

  PerfTier tier = PerfTier.full;
  String reason = 'default';
  if (device == _DeviceClass.lowEnd) {
    tier = PerfTier.reduced;
    reason = 'low-end-device';
  }
  if (fpsDegraded) {
    tier = PerfTier.reduced;
    reason = 'fps-drop';
  }

  final perf = manifest.performance;
  late final int particles;
  if (tier == PerfTier.reduced) {
    particles = perf.maxParticlesLowEnd;
  } else if (device == _DeviceClass.mobile) {
    particles = perf.maxParticlesMobile;
  } else {
    particles = perf.maxParticlesDesktop;
  }

  return PerfBudget(
    tier: tier,
    particles: particles,
    fpsCap: tier == PerfTier.reduced ? 30 : 0,
    motion: true,
    reason: reason,
  );
}

_DeviceClass _classifyDevice() {
  if (kIsWeb) {
    // Browser path — no `Platform`. Treat web-on-desktop as desktop and
    // web-on-mobile as mobile via `defaultTargetPlatform`. We can't read
    // hardwareConcurrency / deviceMemory through dart:io, so we trust the
    // platform hint. Lowering further requires platform JS interop which
    // we'll add when battery API does.
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return _DeviceClass.mobile;
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return _DeviceClass.desktop;
    }
  }
  // Native: peek at processor count. < 4 logical cores → low-end (matches
  // the JS heuristic; we'd need a native plugin for RAM so we skip that
  // half of the check).
  try {
    final cores = Platform.numberOfProcessors;
    if (cores < 4) return _DeviceClass.lowEnd;
  } catch (_) {
    // `Platform` unavailable → assume desktop.
  }
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return _DeviceClass.mobile;
  }
  return _DeviceClass.desktop;
}

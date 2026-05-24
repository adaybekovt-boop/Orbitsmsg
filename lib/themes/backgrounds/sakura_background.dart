// Flutter port of `SakuraBackground.jsx` — falling cherry blossom petals
// over a warm washi canvas.
//
// Strategy: one `Ticker`, one `CustomPainter`, N petals. Each petal carries
// pre-randomised parameters (sway amplitude, rotation rate, fall duration);
// the painter advances them by elapsed time and paints them as filled
// ellipses with a hand-rotated transform. We pick ellipses (not the JS SVG
// paths) because Canvas-side path rasterisation is more expensive than
// drawing primitives — and at petal-size (6-16px) the detail loss is
// invisible.
//
// PerfBudget integration:
//   - `motion: false`        → render base gradient only, no ticker.
//   - `tier: frozen`         → 0 petals.
//   - `particles == N`       → spawn N petals; the painter clamps internally.
//   - On reduced tier the ticker still runs but rebuilds at 30fps cap.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../manifest.dart';
import '../orbits_tokens.dart';
import '../perf_budget.dart';

class SakuraBackground extends ConsumerStatefulWidget {
  const SakuraBackground({super.key, required this.manifest});

  final ThemeManifest manifest;

  @override
  ConsumerState<SakuraBackground> createState() => _SakuraBackgroundState();
}

class _SakuraBackgroundState extends ConsumerState<SakuraBackground>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;
  List<_Petal> _petals = const [];
  int _spawnedFor = -1;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) {
      if (!mounted) return;
      setState(() => _elapsed = d);
    });
    // The ticker is started lazily in build() only when there's motion to
    // animate — see the start/stop control there.
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _ensurePetals(int count) {
    if (_spawnedFor == count) return;
    final rnd = math.Random(0xCBA1B0); // stable seed → same field on rebuild
    _petals = List.generate(count, (i) => _Petal.random(rnd));
    _spawnedFor = count;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final budget = ref.watch(perfBudgetProvider(widget.manifest));
    final motion =
        budget.motion && budget.tier != PerfTier.frozen;
    final count = motion ? budget.particles : 0;
    _ensurePetals(count);

    // Only run the per-frame ticker while there are petals to move; a
    // frozen/reduced-motion background must do zero per-frame work.
    if (count > 0) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
    }

    return IgnorePointer(
      ignoring: true,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Warm washi canvas with two faint sakura blushes.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: const Alignment(-0.6, -1.0),
                end: const Alignment(0.4, 1.0),
                colors: [
                  tokens.bg,
                  Color.lerp(tokens.bg, tokens.surface, 0.5) ?? tokens.bg,
                  tokens.surface,
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.6, -0.7),
                radius: 0.9,
                colors: [
                  tokens.accent2.withValues(alpha: 0.22),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.55],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.6, 0.7),
                radius: 0.9,
                colors: [
                  tokens.accent.withValues(alpha: 0.14),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.55],
              ),
            ),
          ),
          // Petal field. We rebuild on each tick (setState-driven), but
          // CustomPaint reuses the same painter instance — Flutter
          // recognises the constructor params and skips repaint when
          // nothing's changed.
          //
          // The `RepaintBoundary` is critical: without it, the per-tick
          // painter invalidation propagates up the layer tree and forces
          // the static gradient layers below + every Scaffold child above
          // to repaint at 60 fps. With the boundary, only the petals'
          // own composited layer redraws — the rest of the screen sits
          // on cached textures.
          if (count > 0)
            RepaintBoundary(
              child: CustomPaint(
                painter: _PetalsPainter(
                  petals: _petals,
                  elapsedSeconds: _elapsed.inMicroseconds / 1e6,
                  accent: tokens.accent,
                  accent2: tokens.accent2,
                  danger: tokens.danger,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Per-petal pre-randomised constants. All time-dependent values are
/// derived in the painter from `elapsedSeconds`; this struct just holds the
/// invariants (start position, sizes, durations, hue index).
class _Petal {
  _Petal({
    required this.leftFraction,
    required this.startYFraction,
    required this.delaySeconds,
    required this.fallSeconds,
    required this.swaySeconds,
    required this.spinSeconds,
    required this.size,
    required this.opacity,
    required this.swayAmplitude,
    required this.fillIndex,
  });

  factory _Petal.random(math.Random r) {
    return _Petal(
      leftFraction: -0.025 + r.nextDouble() * 1.05,
      startYFraction: -0.10 - r.nextDouble() * 0.30,
      delaySeconds: r.nextDouble() * 16.0,
      fallSeconds: 10.0 + r.nextDouble() * 14.0,
      swaySeconds: 3.0 + r.nextDouble() * 5.0,
      spinSeconds: 6.0 + r.nextDouble() * 10.0,
      size: 6.0 + r.nextDouble() * 10.0,
      opacity: 0.15 + r.nextDouble() * 0.30,
      swayAmplitude: 30.0 + r.nextDouble() * 50.0,
      fillIndex: r.nextInt(3),
    );
  }

  final double leftFraction;
  final double startYFraction;
  final double delaySeconds;
  final double fallSeconds;
  final double swaySeconds;
  final double spinSeconds;
  final double size;
  final double opacity;
  final double swayAmplitude;
  final int fillIndex;
}

class _PetalsPainter extends CustomPainter {
  _PetalsPainter({
    required this.petals,
    required this.elapsedSeconds,
    required this.accent,
    required this.accent2,
    required this.danger,
  });

  final List<_Petal> petals;
  final double elapsedSeconds;
  final Color accent;
  final Color accent2;
  final Color danger;

  @override
  void paint(Canvas canvas, Size size) {
    if (petals.isEmpty) return;

    // Three pink hues — sampled from the Sakura manifest's accent palette
    // so they automatically follow the active theme. We keep three so the
    // field has visual variety without going full random-rgba.
    final fills = <Color>[
      accent.withValues(alpha: 0.55), // sakura
      accent2.withValues(alpha: 0.55), // softer beni
      danger.withValues(alpha: 0.45), // deep beni
    ];

    final fallExtent = size.height + 80; // 100% start + 115vh end ≈ +115%
    for (final p in petals) {
      // Local time inside the [0, fallSeconds] cycle, accounting for delay.
      final raw = (elapsedSeconds - p.delaySeconds) % p.fallSeconds;
      final local = raw < 0 ? raw + p.fallSeconds : raw;
      final fallT = local / p.fallSeconds;

      // Vertical position — linear fall from startY through bottom + 15%.
      final startY = p.startYFraction * size.height;
      final y = startY + fallT * fallExtent;
      if (y < -size.height || y > size.height + 100) continue;

      // Sway — left-right cosine that oscillates with `swaySeconds` period.
      final swayT = (local % p.swaySeconds) / p.swaySeconds;
      final sway =
          math.cos(swayT * 2 * math.pi) * p.swayAmplitude;
      final x = p.leftFraction * size.width + sway;

      // Rotation — full spin every `spinSeconds`.
      final spinT = (local % p.spinSeconds) / p.spinSeconds;
      final angle = spinT * 2 * math.pi;

      // Fade in/out at the edges of the lifecycle so petals don't pop.
      double alpha = 1;
      if (fallT < 0.03) alpha = fallT / 0.03;
      if (fallT > 0.85) alpha = (1 - fallT) / 0.15;
      alpha = (alpha * p.opacity).clamp(0.0, 1.0);

      final color = fills[p.fillIndex % fills.length];
      final paint = Paint()
        ..color = color.withValues(alpha: color.a * alpha);

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(angle);
      // Petal as a soft ellipse — width = size, height = size * 0.85 so it
      // reads as petal-shaped rather than perfectly round.
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: p.size,
          height: p.size * 0.85,
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _PetalsPainter old) =>
      old.elapsedSeconds != elapsedSeconds ||
      old.petals != petals ||
      old.accent != accent ||
      old.accent2 != accent2 ||
      old.danger != danger;
}

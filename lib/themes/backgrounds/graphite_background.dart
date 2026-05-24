// Flutter port of `git_push/src/themes/catalog/classic/GraphiteBackground.jsx`.
//
// Three slow-drifting coloured "orbs" + a faint static grain over the
// graphite canvas. Web CSS used `filter: blur(100px)` keyframe drift; we
// approximate with `RadialGradient`s at low opacity (cheap on web GPU,
// no per-frame ImageFilter cost) and animate translate offsets via a
// `Ticker`.
//
// PerfBudget gating:
//   - `motion: false`      → render a static frame (orbs at midpoint).
//   - `tier: frozen`       → skip the orbs entirely (saves a layer).
//   - `particles == 0`     → only the grain renders.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../manifest.dart';
import '../orbits_tokens.dart';
import '../perf_budget.dart';

class GraphiteBackground extends ConsumerStatefulWidget {
  const GraphiteBackground({super.key, required this.manifest});

  final ThemeManifest manifest;

  @override
  ConsumerState<GraphiteBackground> createState() =>
      _GraphiteBackgroundState();
}

class _GraphiteBackgroundState extends ConsumerState<GraphiteBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // 44s long-period drift cycles; we use a single controller and pull the
    // three orbs off it at different phases. Ticker keeps spinning even at
    // reduced tier — we just damp `motion` in the painter to freeze.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 44),
    );
    // Started/stopped in build() based on the perf budget — a frozen or
    // reduced-motion tier must not keep a vsync callback firing every frame.
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final budget = ref.watch(perfBudgetProvider(widget.manifest));
    final showOrbs =
        budget.tier != PerfTier.frozen && budget.particles > 0;
    final motion = budget.motion;

    // Drive the drift controller only when orbs are actually moving; a frozen
    // frame (t = 0.5) needs no per-frame ticks.
    if (showOrbs && motion) {
      if (!_controller.isAnimating) _controller.repeat();
    } else if (_controller.isAnimating) {
      _controller.stop();
    }

    return IgnorePointer(
      ignoring: true,
      child: ColoredBox(
        color: tokens.bg,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showOrbs)
              // RepaintBoundary so the slowly-drifting orbs don't drag the
              // app shell into per-frame repaints. The painter's
              // `shouldRepaint` already gates on `t`, but the layer-level
              // boundary ensures the dirtiness stays scoped to this single
              // composited texture.
              RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final t = motion ? _controller.value : 0.5;
                    return CustomPaint(
                      painter: _GraphiteOrbsPainter(
                        t: t,
                        accent: tokens.accent,
                        success: tokens.success,
                        accent2: tokens.accent2,
                      ),
                    );
                  },
                ),
              ),
            // Faint static grain — single repaint, no per-frame work.
            // Pulled up to `text` colour at 2.5% alpha so it reads as
            // warmth on the dark canvas without competing with the UI.
            // Static, so no boundary needed — it sits in the parent layer.
            CustomPaint(
              painter: _NoiseGrainPainter(
                seed: 5,
                color: tokens.text.withValues(alpha: 0.025),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Three gradient orbs that translate on long sine cycles. Painting via
/// `RadialGradient.createShader` is cheap; the heavy CSS `blur(100px)` is
/// replicated by giving the gradient a wide soft falloff (full alpha → 0
/// out to radius * 1.0).
class _GraphiteOrbsPainter extends CustomPainter {
  _GraphiteOrbsPainter({
    required this.t,
    required this.accent,
    required this.success,
    required this.accent2,
  });

  final double t; // 0..1 phase
  final Color accent;
  final Color success;
  final Color accent2;

  @override
  void paint(Canvas canvas, Size size) {
    // Phase offsets — different periods so orbs don't drift in lockstep.
    final p1 = math.sin(t * 2 * math.pi);
    final p2 = math.sin(t * 2 * math.pi * (44 / 38));
    final p3 = math.sin(t * 2 * math.pi * (44 / 32));

    _paintOrb(
      canvas,
      center: Offset(
        -100 + 60 * (p1 + 1) / 2,
        -100 + 40 * (p1 + 1) / 2,
      ),
      radius: 250 * (1 + 0.075 * p1),
      color: accent,
      maxAlpha: 0.06 + 0.03 * ((p1 + 1) / 2),
    );
    _paintOrb(
      canvas,
      center: Offset(
        size.width + 100 - 50 * (p2 + 1) / 2,
        size.height + 150 - 40 * (p2 + 1) / 2,
      ),
      radius: 300 * (1 + 0.05 * p2),
      color: success,
      maxAlpha: 0.05 + 0.02 * ((p2 + 1) / 2),
    );
    _paintOrb(
      canvas,
      center: Offset(
        size.width * 0.5 - 40 * (p3 + 1) / 2,
        size.height * 0.4 - 60 * (p3 + 1) / 2,
      ),
      radius: 200 * (1 + 0.10 * p3),
      color: accent2,
      maxAlpha: 0.04 + 0.02 * ((p3 + 1) / 2),
    );
  }

  void _paintOrb(
    Canvas canvas, {
    required Offset center,
    required double radius,
    required Color color,
    required double maxAlpha,
  }) {
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: maxAlpha),
          color.withValues(alpha: 0),
        ],
        stops: const [0.0, 1.0],
      ).createShader(rect);
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(covariant _GraphiteOrbsPainter old) =>
      old.t != t ||
      old.accent != accent ||
      old.success != success ||
      old.accent2 != accent2;
}

/// Cheap pseudo-grain — paints ~600 1px specks across the canvas using a
/// deterministic LCG so the pattern is stable between frames. Paints once
/// (no animation) and the parent caches the layer via `CustomPaint`'s
/// implicit RepaintBoundary.
class _NoiseGrainPainter extends CustomPainter {
  _NoiseGrainPainter({required this.seed, required this.color});
  final int seed;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    var s = seed * 1103515245 + 12345;
    int next() {
      s = s * 1103515245 + 12345;
      return (s >> 16) & 0x7fff;
    }

    const count = 600;
    for (var i = 0; i < count; i++) {
      final x = (next() / 0x7fff) * size.width;
      final y = (next() / 0x7fff) * size.height;
      canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _NoiseGrainPainter old) =>
      old.seed != seed || old.color != color;
}

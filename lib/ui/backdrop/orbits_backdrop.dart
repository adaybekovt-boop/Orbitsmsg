// OrbitsBackdrop — the app-wide atmospheric layer painted *behind* everything
// (mounted once at MaterialApp.builder via each manifest's `background`).
//
// Why it exists: Liquid Glass only reads as glass when there is luminance
// variation *behind* the translucent/painted surface. Over a flat single-colour
// canvas even a real BackdropFilter shows nothing — which is why the first pass
// looked like "no glass at all".
//
// This is deliberately calm and STRICTLY monochrome — no blobs/orbs/bokeh, no
// colour. Just layered luminance (a soft top light + a gentle diagonal field),
// a bottom depth vignette, and a very fine grain so large flat areas don't band
// or look dead. Static (no ticker) so it costs nothing per frame.
//   • Dark  → graphite/near-black depth (never blue slate).
//   • Light → soft off-white / silver depth.

import 'dart:math' show Random;
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';

/// Const-friendly top-level builder so a `const ThemeManifest` can reference it
/// as `background: orbitsBackdropBuilder` (a top-level tear-off is a constant).
Widget orbitsBackdropBuilder(BuildContext context) => const OrbitsBackdrop();

class OrbitsBackdrop extends StatelessWidget {
  const OrbitsBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return RepaintBoundary(
      child: CustomPaint(
        isComplex: true,
        willChange: false,
        size: Size.infinite,
        painter: _BackdropPainter(base: t.bg, isDark: isDark),
      ),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({required this.base, required this.isDark});

  final Color base;
  final bool isDark;

  // Fixed grain pattern in unit space [0..1]² — generated once with a fixed
  // seed so it never flickers between repaints. Scaled to size at paint time.
  static final List<Offset> _grainUnit = _genGrain();
  static List<Offset> _genGrain() {
    final r = Random(7);
    return List<Offset>.generate(
      900,
      (_) => Offset(r.nextDouble(), r.nextDouble()),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // 1. Base canvas.
    canvas.drawRect(rect, Paint()..color = base);

    // 2. Soft top light — a gentle vertical field, brightest at the very top,
    //    gone by mid-screen.
    final topLight =
        Colors.white.withValues(alpha: isDark ? 0.055 : 0.62);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: [topLight, const Color(0x00FFFFFF)],
        ).createShader(rect),
    );

    // 3. Gentle diagonal luminance field — top-left a touch brighter than
    //    bottom-right, for quiet dimensionality (single light source).
    final diag = Colors.white.withValues(alpha: isDark ? 0.035 : 0.34);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [diag, const Color(0x00FFFFFF)],
          stops: const [0.0, 0.6],
        ).createShader(rect),
    );

    // 4. Bottom depth vignette (monochrome).
    final sink = Colors.black.withValues(alpha: isDark ? 0.40 : 0.05);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.center,
          end: Alignment.bottomCenter,
          colors: [const Color(0x00000000), sink],
        ).createShader(rect),
    );

    // 5. Very fine grain so big flat fields don't band or look dead.
    final grain = (isDark ? Colors.white : Colors.black)
        .withValues(alpha: isDark ? 0.018 : 0.012);
    final pts = <Offset>[
      for (final u in _grainUnit) Offset(u.dx * size.width, u.dy * size.height),
    ];
    canvas.drawPoints(
      PointMode.points,
      pts,
      Paint()
        ..color = grain
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.square,
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.base != base || old.isDark != isDark;
}

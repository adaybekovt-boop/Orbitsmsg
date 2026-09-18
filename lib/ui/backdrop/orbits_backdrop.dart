// OrbitsBackdrop — photographic scenery from the React design, painted
// once behind the app so glass surfaces have real luminance to refract.
//
// Dark: space planet horizon (Drop uses the asteroid field).
// Light: alpine daylight panorama.
// Overlay rings stay subtle; the photos are the source of truth.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../themes/orbits_tokens.dart';
import 'orbits_wallpaper.dart';

/// Drop tab swaps the dark wallpaper to the asteroid plate.
final orbitsDropSceneryProvider = StateProvider<bool>((ref) => false);

/// Const-friendly top-level builder so a `const ThemeManifest` can reference it.
Widget orbitsBackdropBuilder(BuildContext context) => const OrbitsBackdrop();

class OrbitsBackdrop extends ConsumerWidget {
  const OrbitsBackdrop({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final drop = ref.watch(orbitsDropSceneryProvider);
    final asset = isDark
        ? (drop ? OrbitsWallpaper.spaceAsteroids : OrbitsWallpaper.spaceHorizon)
        : OrbitsWallpaper.alpineDaylight;
    final tokens = OrbitsTokens.of(context);

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: isDark ? const Color(0xFF000000) : tokens.bg),
          Positioned.fill(
            child: Image.asset(
              asset,
              key: ValueKey<String>(asset),
              fit: BoxFit.cover,
              alignment: Alignment.center,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          const Positioned.fill(child: IgnorePointer(child: _OrbitRings())),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? const [
                          Color(0x33000000),
                          Color(0x00000000),
                          Color(0x66000000),
                        ]
                      : const [
                          Color(0x14FFFFFF),
                          Color(0x00FFFFFF),
                          Color(0x22FFFFFF),
                        ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrbitRings extends StatelessWidget {
  const _OrbitRings();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      painter: _OrbitRingPainter(isDark: isDark),
      size: Size.infinite,
    );
  }
}

class _OrbitRingPainter extends CustomPainter {
  _OrbitRingPainter({required this.isDark});
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final paint1 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: isDark ? 0.08 : 0.16);
    final paint2 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: isDark ? 0.04 : 0.10);

    canvas.save();
    canvas.translate(size.width * 0.78, size.height * 0.92);
    canvas.rotate(-0.48);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 1400, height: 550),
      paint1,
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 1700, height: 650),
      paint2,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OrbitRingPainter old) => old.isDark != isDark;
}

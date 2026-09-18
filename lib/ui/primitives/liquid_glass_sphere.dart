import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';
import 'orbits_glass_surface.dart';

/// React empty-state sphere: volume, caustic, specular — painted, not SVG.
class LiquidGlassSphere extends StatelessWidget {
  const LiquidGlassSphere({super.key, this.size = 110});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: OrbitsGlassSurface(
        role: OrbitsGlassRole.card,
        realBlur: true,
        refract: true,
        borderRadius: BorderRadius.circular(size / 2),
        child: CustomPaint(
          painter: _SpherePainter(
            isDark: Theme.of(context).brightness == Brightness.dark,
            highlight: OrbitsTokens.of(context).glassHighlight,
          ),
        ),
      ),
    );
  }
}

class _SpherePainter extends CustomPainter {
  _SpherePainter({required this.isDark, required this.highlight});
  final bool isDark;
  final Color highlight;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final c = Offset(size.width / 2, size.height / 2 - r * 0.04);

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(c.dx, size.height - r * 0.12),
        width: r * 1.35,
        height: r * 0.28,
      ),
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                Colors.black.withValues(alpha: isDark ? 0.55 : 0.18),
                Colors.transparent,
              ],
            ).createShader(
              Rect.fromCircle(
                center: Offset(c.dx, size.height - r * 0.12),
                radius: r * 0.7,
              ),
            ),
    );

    canvas.drawCircle(
      c,
      r * 0.78,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.4),
          radius: 1.05,
          colors: [
            Colors.white.withValues(alpha: isDark ? 0.55 : 0.82),
            Colors.white.withValues(alpha: isDark ? 0.16 : 0.36),
            Colors.black.withValues(alpha: isDark ? 0.18 : 0.05),
            Colors.white.withValues(alpha: isDark ? 0.28 : 0.48),
          ],
          stops: const [0.0, 0.28, 0.78, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r * 0.78)),
    );
    canvas.drawCircle(
      c,
      r * 0.78,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: isDark ? 0.7 : 0.95),
            Colors.white.withValues(alpha: isDark ? 0.12 : 0.28),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r * 0.78)),
    );

    canvas.drawCircle(
      c + Offset(r * 0.16, r * 0.22),
      r * 0.42,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                Colors.white.withValues(alpha: isDark ? 0.28 : 0.45),
                Colors.transparent,
              ],
            ).createShader(
              Rect.fromCircle(
                center: c + Offset(r * 0.16, r * 0.22),
                radius: r * 0.42,
              ),
            ),
    );

    canvas.drawOval(
      Rect.fromCenter(
        center: c + Offset(-r * 0.22, -r * 0.28),
        width: r * 0.42,
        height: r * 0.22,
      ),
      Paint()..color = highlight.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_SpherePainter old) =>
      old.isDark != isDark || old.highlight != highlight;
}

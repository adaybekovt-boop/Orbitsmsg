import 'dart:math' as math;

import 'package:flutter/material.dart';

/// React `OrbitLogo` — circle, tilted orbit, satellite.
class OrbitsLogo extends StatelessWidget {
  const OrbitsLogo({super.key, this.size = 26, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final paintColor = color ?? IconTheme.of(context).color ?? Colors.white;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _OrbitLogoPainter(color: paintColor)),
    );
  }
}

class _OrbitLogoPainter extends CustomPainter {
  _OrbitLogoPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = Offset(s / 2, s / 2);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * (2.3 / 64)
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(c, s * (16 / 64), stroke);

    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-35 * math.pi / 180);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: s * (58 / 64),
        height: s * (22 / 64),
      ),
      stroke,
    );
    canvas.restore();

    canvas.drawCircle(
      Offset(s * (53 / 64), s * (16 / 64)),
      s * (4 / 64),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_OrbitLogoPainter old) => old.color != color;
}

// OrbitsGlassSwitch — Apple-Liquid-Glass toggle. A translucent glass capsule
// with a glass thumb and a barely-visible prismatic edge (light refraction,
// NOT an RGB gaming glow). Built from plain Flutter primitives — no shader
// packages, no CupertinoSwitch.
//
// Palette discipline (per brand brief): the capsule + thumb are black/white/
// gray glass; the accent appears ONLY in the on-state track; the prismatic
// rim is a thin, low-opacity sweep that's stronger on on/hover and faint when
// off. Reads as glass catching light, not a colour LED.
//
// Reuse: [PrismaticEdgePainter] is exported so other glass controls (chips,
// segmented buttons) can share the same refraction rim.

import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';

enum OrbitsGlassSwitchSize { compact, regular }

class _SwitchMetrics {
  const _SwitchMetrics(this.width, this.height, this.thumb, this.pad);
  final double width;
  final double height;
  final double thumb;
  final double pad;
}

_SwitchMetrics _metricsFor(OrbitsGlassSwitchSize size) {
  switch (size) {
    case OrbitsGlassSwitchSize.compact:
      return const _SwitchMetrics(44, 26, 21, 2.5);
    case OrbitsGlassSwitchSize.regular:
      return const _SwitchMetrics(52, 32, 26, 3);
  }
}

class OrbitsGlassSwitch extends StatefulWidget {
  const OrbitsGlassSwitch({
    super.key,
    required this.value,
    this.onChanged,
    this.enabled = true,
    this.tooltip,
    this.size = OrbitsGlassSwitchSize.regular,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;
  final String? tooltip;
  final OrbitsGlassSwitchSize size;
  final String? semanticLabel;

  @override
  State<OrbitsGlassSwitch> createState() => _OrbitsGlassSwitchState();
}

class _OrbitsGlassSwitchState extends State<OrbitsGlassSwitch> {
  bool _hover = false;
  bool _pressed = false;

  bool get _interactive => widget.enabled && widget.onChanged != null;

  void _toggle() {
    if (!_interactive) return;
    widget.onChanged!(!widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    final m = _metricsFor(widget.size);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final on = widget.value;
    final radius = m.height / 2;

    // ── Track fill ──
    final Gradient trackGradient = on
        ? LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(t.accent, Colors.white, 0.22)!,
              t.accent,
            ],
          )
        : LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.alphaBlend(t.glassHighlight, t.glassTint),
              t.glassTint,
            ],
          );
    final trackBorder = on
        ? t.accentAlpha(0.55)
        : t.glassBorder.withValues(alpha: (_hover ? 0.9 : 0.6));

    // ── Prismatic rim intensity ──
    final edgeOpacity = !_interactive
        ? 0.0
        : ((on ? 0.28 : 0.12) + (_hover ? 0.08 : 0.0)).clamp(0.0, 1.0);

    // ── Thumb ──
    final thumbBase = isDark
        ? const Color(0xFFE7EAF0) // light graphite-white
        : Colors.white;
    final thumbColor = on ? Colors.white : thumbBase;

    Widget capsule = SizedBox(
      width: m.width,
      height: m.height,
      child: Stack(
        children: [
          // Track surface
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: trackGradient,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: trackBorder, width: 1),
                boxShadow: [
                  BoxShadow(
                    color: t.glassShadow,
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),
          // Prismatic refraction rim
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: edgeOpacity,
                duration: t.durationShort,
                curve: t.curveStandard,
                child: CustomPaint(
                  painter: PrismaticEdgePainter(
                    radius: radius,
                    strokeWidth: 1.4,
                  ),
                ),
              ),
            ),
          ),
          // Thumb
          AnimatedAlign(
            duration: const Duration(milliseconds: 210),
            curve: t.curveStandard,
            alignment: on ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.all(m.pad),
              child: _GlassThumb(
                size: m.thumb,
                color: thumbColor,
                glowColor: on ? t.accent : null,
                shadow: t.glassShadow,
                isDark: isDark,
              ),
            ),
          ),
        ],
      ),
    );

    capsule = AnimatedScale(
      scale: _pressed && _interactive ? t.pressScale : 1.0,
      duration: t.durationFast,
      curve: Curves.easeOut,
      child: capsule,
    );

    Widget result = MouseRegion(
      cursor:
          _interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (_interactive && !_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (_hover) setState(() => _hover = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown:
            _interactive ? (_) => setState(() => _pressed = true) : null,
        onTapUp: _interactive ? (_) => setState(() => _pressed = false) : null,
        onTapCancel:
            _interactive ? () => setState(() => _pressed = false) : null,
        onTap: _toggle,
        child: capsule,
      ),
    );

    result = Semantics(
      toggled: on,
      enabled: _interactive,
      label: widget.semanticLabel,
      child: result,
    );

    if (!_interactive) {
      result = Opacity(opacity: 0.45, child: result);
    }

    final tip = widget.tooltip;
    if (tip != null && tip.isNotEmpty) {
      result = Tooltip(message: tip, child: result);
    }
    return result;
  }
}

class _GlassThumb extends StatelessWidget {
  const _GlassThumb({
    required this.size,
    required this.color,
    required this.shadow,
    required this.isDark,
    this.glowColor,
  });

  final double size;
  final Color color;
  final Color shadow;
  final bool isDark;
  final Color? glowColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Top-left inner highlight → subtle glass knob, not a flat disc.
        gradient: RadialGradient(
          center: const Alignment(-0.4, -0.5),
          radius: 0.95,
          colors: [
            Color.lerp(color, Colors.white, isDark ? 0.10 : 0.35)!,
            color,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: shadow,
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
          if (glowColor != null)
            BoxShadow(
              color: glowColor!.withValues(alpha: 0.45),
              blurRadius: 8,
              spreadRadius: -1,
            ),
        ],
      ),
    );
  }
}

/// Paints a thin, soft prismatic ring around a rounded-rect glass control —
/// the "light refraction at the edge" of Apple Liquid Glass. Colours are soft
/// cyan→blue→violet→pink→warm-white; visibility is driven by the caller's
/// opacity (kept low so it reads as glass, never as an RGB strip).
class PrismaticEdgePainter extends CustomPainter {
  const PrismaticEdgePainter({required this.radius, this.strokeWidth = 1.4});

  final double radius;
  final double strokeWidth;

  static const List<Color> _colors = [
    Color(0xFF8FD3FF), // soft cyan
    Color(0xFF9AB0FF), // soft blue
    Color(0xFFC9A8FF), // soft violet
    Color(0xFFFFB3D1), // soft pink
    Color(0xFFFFE7C2), // warm white
    Color(0xFF8FD3FF), // loop back to cyan (seamless)
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(strokeWidth / 2),
      Radius.circular(radius),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = const SweepGradient(
        colors: _colors,
        transform: GradientRotation(-1.2),
      ).createShader(rect)
      // Soften the stroke so it reads as a glow, not a hard line.
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(PrismaticEdgePainter old) =>
      old.radius != radius || old.strokeWidth != strokeWidth;
}

// OrbitsGlassSurface — the single Liquid-Glass primitive every chrome surface
// is built from (app bar, nav bar, sidebar, sheet, dialog, card, button, pill,
// chat bubble, input).
//
// Design notes (see the redesign brief / DeepResearch):
//   • Real `BackdropFilter` blur is used ONLY for large, rarely-rebuilt chrome
//     (app bar / nav bar / sidebar / sheet / dialog / input) AND only where the
//     token `allowRealBlur` is true (Android/iOS/macOS via Impeller, plus
//     Windows). Only Web/CanvasKit falls back to painted fake-glass with no
//     BackdropFilter.
//   • Small / repeated surfaces (card, button, pill, chat bubble) are ALWAYS
//     painted fake-glass — never a BackdropFilter per list row.
//   • Blur sigma is a static token; it is never tweened per frame.
//   • The look = translucent gradient tint (brighter at the top = specular
//     sheen) + 1-px border + soft ambient shadow. No decorative orbs/blobs.
//
// Platform sniffing is via the token (`allowRealBlur`, set in
// theme_data_factory from kIsWeb/defaultTargetPlatform) — this widget never
// touches dart:io, so it stays web-safe.

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';

enum OrbitsGlassRole {
  appBar,
  navBar,
  sidebar,
  card,
  button,
  pill,
  sheet,
  dialog,
  chatBubble,
  input,
}

class OrbitsGlassSurface extends StatelessWidget {
  const OrbitsGlassSurface({
    super.key,
    required this.child,
    this.role = OrbitsGlassRole.card,
    this.padding,
    this.borderRadius,
    this.selected = false,
    this.tint,
    this.fill,
    this.intensity = 1.0,
    this.realBlur,
    this.prismatic = false,
    this.live,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final OrbitsGlassRole role;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;

  /// Active/selected state — slightly stronger tint + accent-leaning border.
  final bool selected;

  /// Optional extra colour mixed into the *translucent* tint (e.g. a faint
  /// accent wash on a secondary button).
  final Color? tint;

  /// When set, the surface is an (almost) opaque "material" filled with this
  /// colour instead of translucent glass — used for primary / destructive
  /// buttons so the action reads crisply. Still gets the sheen + border +
  /// shadow, but no BackdropFilter (it's opaque).
  final Color? fill;

  /// 0..1+ multiplier on the tint/border strength.
  final double intensity;

  /// Override the role-based real-blur decision. `null` ⇒ use the role default
  /// (`_roleWantsRealBlur`). Set `true` for a large, standalone card that is
  /// NOT inside a scrolling list (e.g. the onboarding panel) so it gets a real
  /// BackdropFilter; set `false` to force painted fake-glass.
  final bool? realBlur;

  /// Opt-in thin specular edge catch for *interactive / selected* controls only
  /// (buttons, active toggles): a barely-visible white glint that runs along
  /// the rim like light catching a glass edge. STRICTLY monochrome — pure white
  /// at low alpha, never a spectral/rainbow RGB effect — so the surface stays
  /// black-and-white. (The field keeps its `prismatic` name for call-site
  /// compatibility.)
  final bool prismatic;

  /// Pointer-reactive "live" specular: a soft light catch that follows the
  /// cursor across the surface (Apple `.interactive()` glass). `null` ⇒
  /// role-based default (`_roleWantsLive`): on for large surfaces, off for
  /// buttons/pills/bubbles. Costs nothing at rest — it only paints while a
  /// mouse is hovering, so it's effectively desktop/web-only (touch has no
  /// hover; mobile gets its liveness from the real backdrop blur).
  final bool? live;

  final Clip clipBehavior;

  /// Roles that get the pointer-reactive live sheen by default.
  static bool _roleWantsLive(OrbitsGlassRole role) {
    switch (role) {
      case OrbitsGlassRole.appBar:
      case OrbitsGlassRole.navBar:
      case OrbitsGlassRole.sidebar:
      case OrbitsGlassRole.sheet:
      case OrbitsGlassRole.dialog:
      case OrbitsGlassRole.input:
      case OrbitsGlassRole.card:
        return true;
      case OrbitsGlassRole.button:
      case OrbitsGlassRole.pill:
      case OrbitsGlassRole.chatBubble:
        return false;
    }
  }

  /// Roles allowed to use a real BackdropFilter (large, low-churn chrome).
  static bool _roleWantsRealBlur(OrbitsGlassRole role) {
    switch (role) {
      case OrbitsGlassRole.appBar:
      case OrbitsGlassRole.navBar:
      case OrbitsGlassRole.sidebar:
      case OrbitsGlassRole.sheet:
      case OrbitsGlassRole.dialog:
      case OrbitsGlassRole.input:
        return true;
      case OrbitsGlassRole.card:
      case OrbitsGlassRole.button:
      case OrbitsGlassRole.pill:
      case OrbitsGlassRole.chatBubble:
        return false;
    }
  }

  double _radiusFor(OrbitsTokens t) {
    switch (role) {
      case OrbitsGlassRole.pill:
        return 999;
      case OrbitsGlassRole.button:
      case OrbitsGlassRole.input:
        return t.radiusButton;
      case OrbitsGlassRole.sheet:
      case OrbitsGlassRole.dialog:
        return t.radiusModal;
      case OrbitsGlassRole.appBar:
      case OrbitsGlassRole.navBar:
        return t.radiusModal;
      case OrbitsGlassRole.sidebar:
        return t.radiusCard;
      case OrbitsGlassRole.card:
      case OrbitsGlassRole.chatBubble:
        return t.radiusCard;
    }
  }

  /// Ambient shadow elevation-ish blur, per role.
  double _shadowBlur() {
    switch (role) {
      case OrbitsGlassRole.sheet:
      case OrbitsGlassRole.dialog:
        return 32;
      case OrbitsGlassRole.appBar:
      case OrbitsGlassRole.navBar:
      case OrbitsGlassRole.sidebar:
        return 18;
      case OrbitsGlassRole.card:
      case OrbitsGlassRole.chatBubble:
        return 14;
      case OrbitsGlassRole.button:
      case OrbitsGlassRole.pill:
      case OrbitsGlassRole.input:
        return 10;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    final radius = borderRadius ?? BorderRadius.circular(_radiusFor(t));
    final isFilled = fill != null;

    // Accessibility (Reduce Transparency / high-contrast): glass collapses to
    // an opaque plate — no blur, no translucency — so text keeps full contrast
    // (deep-research UX rule + WCAG 2.2). Honoured app-wide via this primitive.
    final highContrast = MediaQuery.maybeOf(context)?.highContrast ?? false;
    if (highContrast) return _solidPlate(t, radius);

    final useRealBlur = !isFilled &&
        t.allowRealBlur &&
        (realBlur ?? _roleWantsRealBlur(role)) &&
        t.glassBlurSigma > 0;

    // ── Material + edge-optics colours ──────────────────────────────────────
    // `sheen`  = top-left specular catch on the fill.
    // `rimHi`  = bright Fresnel rim on the light-facing edge (top-left).
    // `rimLo`  = dim rim on the shadow-facing edge (bottom-right).
    final Color base;
    final Color sheen;
    final Color rimHi;
    final Color rimLo;
    if (isFilled) {
      final f = fill!;
      base = f;
      sheen = Color.lerp(f, Colors.white, 0.16)!;
      rimHi = Color.lerp(f, Colors.white, 0.45)!.withValues(alpha: 0.75);
      rimLo = Color.lerp(f, Colors.black, 0.18)!.withValues(alpha: 0.45);
    } else {
      // Real-blur surfaces stay a light film (blur does the work); painted
      // fake-glass needs a heavier film since there's no blur behind it.
      final tintBoost = useRealBlur ? 1.0 : 1.6;
      var b = t.glassTint.withValues(
        alpha: (t.glassTint.a * tintBoost * intensity).clamp(0.0, 1.0),
      );
      if (tint != null) {
        b = Color.alphaBlend(tint!.withValues(alpha: 0.16 * intensity), b);
      }
      if (selected) {
        b = Color.alphaBlend(t.accentAlpha(0.16), b);
      }
      base = b;
      sheen = Color.lerp(base, t.glassHighlight, 0.55 * intensity)!;
      rimHi = selected
          ? t.accentAlpha(0.65)
          : t.glassHighlight.withValues(
              alpha: (t.glassHighlight.a * 1.7 * intensity).clamp(0.0, 1.0));
      rimLo = selected
          ? t.accentAlpha(0.18)
          : t.glassBorder.withValues(
              alpha: (t.glassBorder.a * 0.7 * intensity).clamp(0.0, 1.0));
    }

    // Inner specular highlight (a soft bright line just inside the top edge)
    // and the opt-in prismatic edge opacity (interactive/selected only).
    final Color innerHi = isFilled
        ? Colors.white.withValues(alpha: 0.28)
        : t.glassHighlight.withValues(
            alpha: (t.glassHighlight.a * 1.2 * intensity).clamp(0.0, 1.0));
    final double prismaticOpacity =
        (prismatic || selected) ? (selected ? 0.16 : 0.12) : 0.0;

    // Fill gradient runs top-left → bottom-right so the specular sheen sits
    // under a single (top-left) light source, matching the rim below.
    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [sheen, base],
          stops: const [0.0, 0.7],
        ),
        borderRadius: radius,
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );

    surface = ClipRRect(
      borderRadius: radius,
      clipBehavior: clipBehavior,
      child: useRealBlur
          ? BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: t.glassBlurSigma,
                sigmaY: t.glassBlurSigma,
              ),
              child: surface,
            )
          : surface,
    );

    // Edge optics painted on top → the "thickness" that makes it read as glass
    // rather than a flat translucent oval: directional rim + inner top
    // highlight + (optional) thin prismatic catch.
    surface = CustomPaint(
      foregroundPainter: _GlassEdgePainter(
        radius: radius,
        rimHi: rimHi,
        rimLo: rimLo,
        innerHi: innerHi,
        prismaticOpacity: prismaticOpacity,
      ),
      child: surface,
    );

    // Pointer-reactive live sheen — a soft light catch that follows the cursor,
    // so the glass feels alive on desktop/web (where there's no real backdrop
    // refraction). Paints only while hovered; no-op at rest and on touch.
    if (live ?? _roleWantsLive(role)) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      surface = _LiveSheen(
        radius: radius,
        color: Colors.white.withValues(alpha: isDark ? 0.17 : 0.26),
        child: surface,
      );
    }

    // Ambient shadow lives on an outer box so it isn't clipped away.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: t.glassShadow,
            blurRadius: _shadowBlur(),
            offset: Offset(0, _shadowBlur() / 3),
          ),
        ],
      ),
      child: surface,
    );
  }

  /// Opaque high-contrast fallback (Reduce Transparency).
  Widget _solidPlate(OrbitsTokens t, BorderRadius radius) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill ?? t.surface,
        borderRadius: radius,
        border: Border.all(color: t.border),
        boxShadow: [
          BoxShadow(
            color: t.glassShadow,
            blurRadius: _shadowBlur(),
            offset: Offset(0, _shadowBlur() / 3),
          ),
        ],
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
  }
}

/// Paints the glass edge optics on top of the (blurred or painted) surface:
///   1. a directional rim — bright on the light-facing edge (top-left), dim on
///      the far edge (bottom-right): the Fresnel rim that gives "thickness";
///   2. a soft inner specular highlight just inside the top edge;
///   3. an optional, very subtle prismatic (spectral) catch for interactive /
///      selected controls — a thin optical highlight, never an RGB effect.
/// Cheap: a couple of stroked RRects + one line, no per-frame blur, no backdrop
/// sampling.
class _GlassEdgePainter extends CustomPainter {
  _GlassEdgePainter({
    required this.radius,
    required this.rimHi,
    required this.rimLo,
    required this.innerHi,
    required this.prismaticOpacity,
  });

  final BorderRadius radius;
  final Color rimHi;
  final Color rimLo;
  final Color innerHi;
  final double prismaticOpacity;
  static const double _w = 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final outer = radius.toRRect(rect).deflate(_w / 2);

    // 1. Directional monochrome rim.
    canvas.drawRRect(
      outer,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _w
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [rimHi, rimLo],
        ).createShader(rect),
    );

    // 2. Thin specular edge catch (interactive / selected only). STRICTLY
    // monochrome — a moving white light glints along the rim like a real glass
    // edge under a single light source. No spectral/rainbow colour: the app's
    // palette is black-and-white, so the catch is pure white at varying alpha.
    if (prismaticOpacity > 0) {
      final glint = Colors.white.withValues(alpha: prismaticOpacity);
      final glintSoft = Colors.white.withValues(alpha: prismaticOpacity * 0.55);
      canvas.drawRRect(
        outer,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _w
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.6)
          ..shader = SweepGradient(
            transform: const GradientRotation(-1.25),
            colors: [
              const Color(0x00FFFFFF),
              glintSoft,
              glint,
              glintSoft,
              glint,
              glintSoft,
              const Color(0x00FFFFFF),
            ],
            stops: const [0.0, 0.16, 0.34, 0.52, 0.7, 0.86, 1.0],
          ).createShader(rect),
      );
    }

    // 3. Inner top specular highlight — a soft bright line just inside the top.
    if (innerHi.a > 0) {
      final inset = radius.topLeft.x.clamp(8.0, 30.0);
      const y = 1.5;
      final p1 = Offset(inset, y);
      final p2 = Offset(size.width - inset, y);
      if (p2.dx > p1.dx) {
        canvas.drawLine(
          p1,
          p2,
          Paint()
            ..strokeWidth = 1.0
            ..shader = LinearGradient(
              colors: [const Color(0x00FFFFFF), innerHi, const Color(0x00FFFFFF)],
              stops: const [0.0, 0.5, 1.0],
            ).createShader(Rect.fromPoints(p1, p2)),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GlassEdgePainter old) =>
      old.rimHi != rimHi ||
      old.rimLo != rimLo ||
      old.innerHi != innerHi ||
      old.prismaticOpacity != prismaticOpacity ||
      old.radius != radius;
}

/// Wraps a glass surface with a pointer-reactive specular catch: a soft light
/// blob that follows the cursor and fades in/out on hover. Only the thin
/// overlay repaints as the mouse moves (the wrapped child is built once); at
/// rest nothing animates, and on touch devices (no hover) it never shows.
class _LiveSheen extends StatefulWidget {
  const _LiveSheen({
    required this.radius,
    required this.color,
    required this.child,
  });

  final BorderRadius radius;
  final Color color;
  final Widget child;

  @override
  State<_LiveSheen> createState() => _LiveSheenState();
}

class _LiveSheenState extends State<_LiveSheen>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<Offset?> _pos = ValueNotifier<Offset?>(null);
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );

  void _track(Offset p) {
    _pos.value = p;
    if (_fade.status != AnimationStatus.forward && _fade.value < 1.0) {
      _fade.forward();
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _pos.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      opaque: false,
      onEnter: (e) => _track(e.localPosition),
      onHover: (e) => _track(e.localPosition),
      onExit: (_) => _fade.reverse(),
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_fade, _pos]),
                  builder: (context, _) {
                    final o = _fade.value;
                    final p = _pos.value;
                    if (o <= 0.001 || p == null) {
                      return const SizedBox.shrink();
                    }
                    return ClipRRect(
                      borderRadius: widget.radius,
                      child: CustomPaint(
                        painter: _SheenPainter(
                          center: p,
                          color: widget.color,
                          opacity: o,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheenPainter extends CustomPainter {
  _SheenPainter({
    required this.center,
    required this.color,
    required this.opacity,
  });

  final Offset center;
  final Color color;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide * 0.95;
    final core = color.withValues(alpha: color.a * opacity);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [core, core.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(_SheenPainter old) =>
      old.center != center ||
      old.opacity != opacity ||
      old.color != color;
}

// Port of the JS `--orb-*-rgb` CSS-variable token system into a Flutter
// `ThemeExtension`. Every colour/shape/typography/motion knob a screen
// might want comes from here — if a manifest doesn't define a value we
// fall back to a sensible default in the factory, never a hard-coded
// literal at the call site.
//
// Usage:
//
//   final tokens = OrbitsTokens.of(context);
//   Container(color: tokens.success);
//
// We also expose `tokens.successAlpha(0.25)` etc. as small helpers so
// the call site reads like the JS `rgba(var(--orb-success-rgb), 0.25)`.
//
// Pairs with `theme_data_factory.dart` which mounts an `OrbitsTokens`
// instance onto every `ThemeData` we hand to `MaterialApp`. See
// `themes/registry.dart` for the catalog of manifests that produce
// these tokens.

import 'package:flutter/material.dart';

@immutable
class OrbitsTokens extends ThemeExtension<OrbitsTokens> {
  const OrbitsTokens({
    required this.bg,
    required this.surface,
    required this.border,
    required this.text,
    required this.muted,
    required this.accent,
    required this.accent2,
    required this.success,
    required this.danger,
    required this.scrim,
    required this.deliveryRead,
    required this.bubbleOut,
    required this.radiusButton,
    required this.radiusCard,
    required this.radiusModal,
    required this.shadowCard,
    required this.blurSurface,
    required this.fontHeading,
    required this.fontBody,
    required this.fontMono,
    required this.letterSpacingHeading,
    required this.lineHeightBody,
    required this.durationShort,
    required this.durationMedium,
    required this.durationLong,
    required this.easing,
    // Liquid Glass + motion (2026-05 redesign). Defaulted so older call sites
    // and tests that build tokens by hand don't have to spell every field.
    this.glassBlurSigma = 24,
    this.allowRealBlur = true,
    this.glassTint = const Color(0x1FFFFFFF),
    this.glassBorder = const Color(0x33FFFFFF),
    this.glassHighlight = const Color(0x40FFFFFF),
    this.glassShadow = const Color(0x40000000),
    this.pressScale = 0.97,
    this.curveStandard = Curves.easeOutCubic,
    this.curveEmphasized = Curves.easeOutBack,
    this.curveDecelerate = Curves.easeOutCirc,
    this.durationFast = const Duration(milliseconds: 130),
  });

  // ── palette ────────────────────────────────────────────────────────
  /// Page-canvas fill. Equivalent to `--orb-bg-rgb`.
  final Color bg;

  /// Card / panel / sheet surface. Equivalent to `--orb-surface-rgb`.
  final Color surface;

  /// Hairline divider / outline. Equivalent to `--orb-border-rgb`.
  final Color border;

  /// Primary on-canvas text. Equivalent to `--orb-text-rgb`.
  final Color text;

  /// Secondary / muted copy. Equivalent to `--orb-muted-rgb`.
  final Color muted;

  /// Brand accent — primary buttons, send-bubble fill, focus rings.
  /// Equivalent to `--orb-accent-rgb`.
  final Color accent;

  /// Secondary accent — used by warnings / "connecting" state. Mapped
  /// to `--orb-accent2-rgb` in JS; some manifests reuse `accent`.
  final Color accent2;

  /// Semantic success colour (online dot, "delivered" tick).
  /// Equivalent to `--orb-success-rgb`.
  final Color success;

  /// Semantic destructive colour (multitab error, "delete forever",
  /// danger-zone CTA). Equivalent to `--orb-danger-rgb`.
  final Color danger;

  /// Fixed semi-transparent dark scrim used over user media (image
  /// preview overlays, full-screen call backdrop). Stays roughly
  /// black-ish across themes so photo content stays legible.
  final Color scrim;

  /// "Read" double-tick blue. Mirrors JS `text-blue-200` per the JS
  /// chat. Some manifests fold this into `accent`; light themes pin
  /// it to a brand blue regardless.
  final Color deliveryRead;

  /// Outgoing message-bubble fill (see [ThemeTokenColors.bubbleOut]). A deep
  /// graphite-blue glass tone in dark, confident dark ink in light — never the
  /// blinding near-white `accent`.
  final Color bubbleOut;

  // ── shape ──────────────────────────────────────────────────────────
  final double radiusButton;
  final double radiusCard;
  final double radiusModal;

  /// `BoxShadow` list applied to the card surface in elevated states.
  /// Empty list = no shadow (matches JS `'none'`).
  final List<BoxShadow> shadowCard;

  /// Blur applied behind translucent surfaces (sheets, modals).
  /// `0` disables (Matrix has crisp/no-blur surfaces, Sakura softens).
  final double blurSurface;

  // ── typography ─────────────────────────────────────────────────────
  /// Font family used by titles + section headers.
  final String fontHeading;

  /// Font family used by body / chat text. This drives `ThemeData.textTheme`.
  final String fontBody;

  /// Monospace family — peer ids, hex strings, code-ish UI.
  final String fontMono;

  /// CSS `em` letter-spacing for headings, expressed as a Flutter
  /// pixel offset at the heading font size (we approximate by
  /// multiplying em by the heading size at use-site).
  final double letterSpacingHeading;

  /// Body line-height multiplier. Equivalent to CSS unitless
  /// `line-height: 1.55`.
  final double lineHeightBody;

  // ── motion ─────────────────────────────────────────────────────────
  final Duration durationShort;
  final Duration durationMedium;
  final Duration durationLong;

  /// Cubic-bezier easing curve for every motion transition. Built from
  /// the manifest's `ease: [c1, c2, c3, c4]`.
  final Curve easing;

  // ── liquid glass ───────────────────────────────────────────────────
  /// Gaussian blur sigma for real-blur glass surfaces. Only used when
  /// [allowRealBlur] is true (Android). 0 ⇒ no blur even on the real path.
  final double glassBlurSigma;

  /// Whether the platform should attempt a real `BackdropFilter` blur for
  /// large glass surfaces. False on Web/Windows ⇒ painted fake-glass only.
  final bool allowRealBlur;

  /// Base translucent fill painted over the (blurred or plain) backdrop.
  /// [OrbitsGlassSurface] scales its alpha per role.
  final Color glassTint;

  /// 1-px specular border colour for glass surfaces.
  final Color glassBorder;

  /// Top inner-highlight line colour (the "light catching the edge").
  final Color glassHighlight;

  /// Soft ambient shadow colour under floating glass.
  final Color glassShadow;

  // ── motion (Apple-ish) ─────────────────────────────────────────────
  /// Scale applied while a glass button is pressed (e.g. 0.97).
  final double pressScale;

  /// Standard ease (Apple-ish settle) — most transitions.
  final Curve curveStandard;

  /// Emphasised, slightly springy ease — sticker/sheet pop.
  final Curve curveEmphasized;

  /// Decelerate ease — incoming/entrance motion.
  final Curve curveDecelerate;

  /// Snappy tap-feedback duration (~120-140ms).
  final Duration durationFast;

  // ── helpers ────────────────────────────────────────────────────────
  /// Look up the active tokens. Throws if no theme has been applied —
  /// ensures every screen runs under a real manifest in dev.
  static OrbitsTokens of(BuildContext context) {
    final t = Theme.of(context).extension<OrbitsTokens>();
    assert(t != null,
        'OrbitsTokens missing — wrap MaterialApp in buildOrbitsTheme(...)');
    return t!;
  }

  /// `success` with a custom alpha. Mirrors `rgba(var(--orb-success-rgb), α)`.
  Color successAlpha(double alpha) => success.withValues(alpha: alpha);
  Color dangerAlpha(double alpha) => danger.withValues(alpha: alpha);
  Color accentAlpha(double alpha) => accent.withValues(alpha: alpha);
  Color accent2Alpha(double alpha) => accent2.withValues(alpha: alpha);
  Color mutedAlpha(double alpha) => muted.withValues(alpha: alpha);

  // ── ThemeExtension contract ────────────────────────────────────────
  @override
  OrbitsTokens copyWith({
    Color? bg,
    Color? surface,
    Color? border,
    Color? text,
    Color? muted,
    Color? accent,
    Color? accent2,
    Color? success,
    Color? danger,
    Color? scrim,
    Color? deliveryRead,
    Color? bubbleOut,
    double? radiusButton,
    double? radiusCard,
    double? radiusModal,
    List<BoxShadow>? shadowCard,
    double? blurSurface,
    String? fontHeading,
    String? fontBody,
    String? fontMono,
    double? letterSpacingHeading,
    double? lineHeightBody,
    Duration? durationShort,
    Duration? durationMedium,
    Duration? durationLong,
    Curve? easing,
    double? glassBlurSigma,
    bool? allowRealBlur,
    Color? glassTint,
    Color? glassBorder,
    Color? glassHighlight,
    Color? glassShadow,
    double? pressScale,
    Curve? curveStandard,
    Curve? curveEmphasized,
    Curve? curveDecelerate,
    Duration? durationFast,
  }) {
    return OrbitsTokens(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      border: border ?? this.border,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      accent: accent ?? this.accent,
      accent2: accent2 ?? this.accent2,
      success: success ?? this.success,
      danger: danger ?? this.danger,
      scrim: scrim ?? this.scrim,
      deliveryRead: deliveryRead ?? this.deliveryRead,
      bubbleOut: bubbleOut ?? this.bubbleOut,
      radiusButton: radiusButton ?? this.radiusButton,
      radiusCard: radiusCard ?? this.radiusCard,
      radiusModal: radiusModal ?? this.radiusModal,
      shadowCard: shadowCard ?? this.shadowCard,
      blurSurface: blurSurface ?? this.blurSurface,
      fontHeading: fontHeading ?? this.fontHeading,
      fontBody: fontBody ?? this.fontBody,
      fontMono: fontMono ?? this.fontMono,
      letterSpacingHeading: letterSpacingHeading ?? this.letterSpacingHeading,
      lineHeightBody: lineHeightBody ?? this.lineHeightBody,
      durationShort: durationShort ?? this.durationShort,
      durationMedium: durationMedium ?? this.durationMedium,
      durationLong: durationLong ?? this.durationLong,
      easing: easing ?? this.easing,
      glassBlurSigma: glassBlurSigma ?? this.glassBlurSigma,
      allowRealBlur: allowRealBlur ?? this.allowRealBlur,
      glassTint: glassTint ?? this.glassTint,
      glassBorder: glassBorder ?? this.glassBorder,
      glassHighlight: glassHighlight ?? this.glassHighlight,
      glassShadow: glassShadow ?? this.glassShadow,
      pressScale: pressScale ?? this.pressScale,
      curveStandard: curveStandard ?? this.curveStandard,
      curveEmphasized: curveEmphasized ?? this.curveEmphasized,
      curveDecelerate: curveDecelerate ?? this.curveDecelerate,
      durationFast: durationFast ?? this.durationFast,
    );
  }

  /// Linear cross-fade between two manifests — used during theme
  /// switches so colours animate instead of snapping. Numeric and
  /// duration values lerp; font names + curve hand off at `t >= 0.5`
  /// (no meaningful midpoint between e.g. Cormorant Garamond and
  /// JetBrains Mono).
  @override
  OrbitsTokens lerp(ThemeExtension<OrbitsTokens>? other, double t) {
    if (other is! OrbitsTokens) return this;
    return OrbitsTokens(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      border: Color.lerp(border, other.border, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accent2: Color.lerp(accent2, other.accent2, t)!,
      success: Color.lerp(success, other.success, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      deliveryRead: Color.lerp(deliveryRead, other.deliveryRead, t)!,
      bubbleOut: Color.lerp(bubbleOut, other.bubbleOut, t)!,
      radiusButton: _lerpDouble(radiusButton, other.radiusButton, t),
      radiusCard: _lerpDouble(radiusCard, other.radiusCard, t),
      radiusModal: _lerpDouble(radiusModal, other.radiusModal, t),
      shadowCard: t < 0.5 ? shadowCard : other.shadowCard,
      blurSurface: _lerpDouble(blurSurface, other.blurSurface, t),
      fontHeading: t < 0.5 ? fontHeading : other.fontHeading,
      fontBody: t < 0.5 ? fontBody : other.fontBody,
      fontMono: t < 0.5 ? fontMono : other.fontMono,
      letterSpacingHeading:
          _lerpDouble(letterSpacingHeading, other.letterSpacingHeading, t),
      lineHeightBody: _lerpDouble(lineHeightBody, other.lineHeightBody, t),
      durationShort: _lerpDuration(durationShort, other.durationShort, t),
      durationMedium: _lerpDuration(durationMedium, other.durationMedium, t),
      durationLong: _lerpDuration(durationLong, other.durationLong, t),
      easing: t < 0.5 ? easing : other.easing,
      glassBlurSigma: _lerpDouble(glassBlurSigma, other.glassBlurSigma, t),
      allowRealBlur: t < 0.5 ? allowRealBlur : other.allowRealBlur,
      glassTint: Color.lerp(glassTint, other.glassTint, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      glassHighlight: Color.lerp(glassHighlight, other.glassHighlight, t)!,
      glassShadow: Color.lerp(glassShadow, other.glassShadow, t)!,
      pressScale: _lerpDouble(pressScale, other.pressScale, t),
      curveStandard: t < 0.5 ? curveStandard : other.curveStandard,
      curveEmphasized: t < 0.5 ? curveEmphasized : other.curveEmphasized,
      curveDecelerate: t < 0.5 ? curveDecelerate : other.curveDecelerate,
      durationFast: _lerpDuration(durationFast, other.durationFast, t),
    );
  }

  static double _lerpDouble(double a, double b, double t) => a + (b - a) * t;

  static Duration _lerpDuration(Duration a, Duration b, double t) =>
      Duration(microseconds: (a.inMicroseconds +
              (b.inMicroseconds - a.inMicroseconds) * t)
          .round());
}

// Lightweight ThemeData carrying an OrbitsTokens extension for widget tests of
// glass primitives — built by hand (no GoogleFonts, which throws async in
// `flutter test`). Glass colours come from the real brightness helper so the
// tokens match production shape.

import 'package:flutter/material.dart';
import 'package:orbits_flutter/themes/orbits_tokens.dart';
import 'package:orbits_flutter/themes/theme_data_factory.dart';

ThemeData testOrbitsTheme({Brightness brightness = Brightness.dark}) {
  final isDark = brightness == Brightness.dark;
  final glass = glassPaletteForBrightness(brightness);
  final tokens = OrbitsTokens(
    bg: isDark ? const Color(0xFF0C0D10) : const Color(0xFFF4F6F9),
    surface: isDark ? const Color(0xFF16181D) : const Color(0xFFFFFFFF),
    border: isDark ? const Color(0x1FFFFFFF) : const Color(0xFFE3E7ED),
    text: isDark ? const Color(0xFFF2F3F5) : const Color(0xFF14181F),
    muted: isDark ? const Color(0xFF9BA1AC) : const Color(0xFF697586),
    accent: isDark ? const Color(0xFF5B9DFF) : const Color(0xFF0A84FF),
    accent2: isDark ? const Color(0xFF54C7C0) : const Color(0xFF12B5A6),
    success: const Color(0xFF34C759),
    danger: const Color(0xFFFF453A),
    scrim: const Color(0xCC000000),
    deliveryRead: const Color(0xFF7FB0FF),
    bubbleOut: isDark ? const Color(0xFF20293B) : const Color(0xFF1C2129),
    radiusButton: 14,
    radiusCard: 18,
    radiusModal: 26,
    shadowCard: const <BoxShadow>[],
    blurSurface: 0,
    fontHeading: 'Manrope',
    fontBody: 'Inter',
    fontMono: 'JetBrainsMono',
    letterSpacingHeading: -0.015,
    lineHeightBody: 1.5,
    durationShort: const Duration(milliseconds: 140),
    durationMedium: const Duration(milliseconds: 240),
    durationLong: const Duration(milliseconds: 400),
    easing: Curves.easeOutCubic,
    glassBlurSigma: glass.blurSigma,
    allowRealBlur: false, // tests run headless — keep painted fake-glass
    glassTint: glass.tint,
    glassBorder: glass.border,
    glassHighlight: glass.highlight,
    glassShadow: glass.shadow,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    extensions: <ThemeExtension<dynamic>>[tokens],
  );
}

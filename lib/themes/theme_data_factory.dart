// Manifest → ThemeData. Mirrors the JS `applyTokens.js` step that wrote
// `--orb-*-rgb` custom properties to `<html>`, except here we mount the
// resolved values onto a `ThemeData` via a `ThemeExtension<OrbitsTokens>`.
//
// The factory does three jobs:
//   1. Build a `ColorScheme` so off-the-shelf Material widgets (FilledButton,
//      Switch, BottomNavigationBar default styling) pick up theme colours
//      without us having to wire them by hand.
//   2. Build a `TextTheme` from the manifest typography so anything reading
//      `Theme.of(context).textTheme.bodyLarge` gets the right font.
//   3. Mount an `OrbitsTokens` extension carrying the *full* token surface,
//      including pieces that don't fit `ColorScheme` (accent2, scrim,
//      deliveryRead, shape, motion, fonts).
//
// Call site:
//
//   final manifest = loadThemeManifest(themeId);
//   MaterialApp(theme: buildOrbitsTheme(manifest), ...);
//
// The JS side wrote tokens directly to the DOM; here every widget that
// wants tokens reads them from `OrbitsTokens.of(context)` and re-renders
// automatically when the active manifest changes.

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'manifest.dart';
import 'orbits_tokens.dart';

/// Build a `ThemeData` from a [manifest]. The returned theme is what gets
/// passed to `MaterialApp.theme` (and re-built whenever `ThemeNotifier`
/// emits a new id).
/// Brightness-derived Liquid-Glass palette. Pure (no fonts / ThemeData) so it
/// can be unit-tested directly. A frosted-white film on Light, a thin luminous
/// film on Dark, each with a hairline + ambient shadow that reads on its
/// canvas.
({Color tint, Color border, Color highlight, Color shadow, double blurSigma})
    glassPaletteForBrightness(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  return (
    tint: isDark ? const Color(0x14FFFFFF) : const Color(0x8AFFFFFF),
    border: isDark ? const Color(0x2EFFFFFF) : const Color(0x1F1B2533),
    highlight: isDark ? const Color(0x3DFFFFFF) : const Color(0xCCFFFFFF),
    shadow: isDark ? const Color(0x59000000) : const Color(0x1A1B2533),
    // Kept inside the deep-research budget (effective blur radius ≤ ~40px on
    // compact phones; ≤ 3 simultaneous blur layers). 26/22 over-frosts and
    // over-spends GPU; 22/20 reads as confident frosted glass — a touch
    // stronger than the old 18/16 so the real BackdropFilter (now also live on
    // Windows) clearly refracts the content behind chrome without smearing.
    blurSigma: isDark ? 22.0 : 20.0,
  );
}

ThemeData buildOrbitsTheme(ThemeManifest manifest) {
  final colors = manifest.tokens;
  final brightness = manifest.colorScheme;

  // Real BackdropFilter blur on every target: Android / iOS / macOS (Impeller),
  // Windows, AND Web. A live in-app BackdropFilter is the ONLY thing that
  // refracts the app's own content — the chat scrolling under the header, the
  // content behind a sheet/dialog, messages behind the composer — which is what
  // makes the glass read as REAL rather than a painted film. (Windows also
  // composites Mica behind the OS window for the *margin* translucency, but
  // Mica can't frost in-app content.) The cost worry on Web/CanvasKit was
  // per-frame blur churn; we avoid it because OrbitsGlassSurface restricts real
  // blur to large, LOW-CHURN chrome (nav/appbar/sheet/dialog/sidebar/input) and
  // NEVER blurs list-repeated surfaces (cards/buttons/bubbles) — so scrolling a
  // 1000-message list adds zero blur layers and stays smooth even on Web. Where
  // a glass surface sits over a transparent area (Windows Mica margin) the
  // filter samples transparent pixels and is a harmless no-op. The painted path
  // remains the fallback whenever glassBlurSigma is 0.
  final allowRealBlur = kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;

  // Glass palette is brightness-derived (pure helper so it's unit-testable
  // without booting fonts/ThemeData).
  final glass = glassPaletteForBrightness(brightness);

  // ColorScheme drives default Material widgets. We map our 9 token colours
  // to the closest `ColorScheme` slot — anything that doesn't fit (accent2,
  // scrim, deliveryRead) lives only on `OrbitsTokens`.
  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: colors.accent,
    onPrimary: _onColorFor(colors.accent),
    secondary: colors.accent2,
    onSecondary: _onColorFor(colors.accent2),
    error: colors.danger,
    onError: _onColorFor(colors.danger),
    surface: colors.surface,
    onSurface: colors.text,
    surfaceContainerHighest: colors.surface,
    outline: colors.border,
    outlineVariant: colors.border,
    // `background` is deprecated in M3 but we still set the canvas via
    // `scaffoldBackgroundColor` below.
  );

  final tokens = OrbitsTokens(
    bg: colors.bg,
    surface: colors.surface,
    border: colors.border,
    text: colors.text,
    muted: colors.muted,
    accent: colors.accent,
    accent2: colors.accent2,
    success: colors.success,
    danger: colors.danger,
    scrim: colors.scrim,
    deliveryRead: colors.deliveryRead,
    bubbleOut: colors.bubbleOut,
    radiusButton: manifest.shape.radiusButton,
    radiusCard: manifest.shape.radiusCard,
    radiusModal: manifest.shape.radiusModal,
    shadowCard: manifest.shape.shadowCard,
    blurSurface: manifest.shape.blurSurface,
    fontHeading: manifest.typography.fontHeading,
    fontBody: manifest.typography.fontBody,
    fontMono: manifest.typography.fontMono,
    letterSpacingHeading: manifest.typography.letterSpacingHeading,
    lineHeightBody: manifest.typography.lineHeightBody,
    durationShort: manifest.motion.durationShort,
    durationMedium: manifest.motion.durationMedium,
    durationLong: manifest.motion.durationLong,
    easing: manifest.motion.easing,
    // Liquid Glass + motion tokens (the rest fall back to OrbitsTokens
    // defaults — pressScale / curves / durationFast are theme-agnostic).
    glassBlurSigma: glass.blurSigma,
    allowRealBlur: allowRealBlur,
    glassTint: glass.tint,
    glassBorder: glass.border,
    glassHighlight: glass.highlight,
    glassShadow: glass.shadow,
  );

  // TextTheme — body uses fontBody, large/headline uses fontHeading, with
  // the manifest line-height as the default body multiplier. Letter spacing
  // is the manifest em value × the resolved font size at use-site, so we
  // express it as a plain `double` (Flutter takes spacing in logical pixels,
  // not em). Multiplying happens in the heading styles below.
  //
  // We resolve each manifest font name through `GoogleFonts.getFont` so the
  // brand families (Manrope, Cormorant Garamond, Instrument Serif, Geist,
  // Noto Serif, JetBrains Mono) load at runtime — no need to bundle 5 MB
  // of TTF in the install. `_resolveFont` swallows lookups that aren't on
  // Google Fonts and falls back to `fontFamily:` so future themes can ship
  // bundled fonts without a code change.
  final body = _resolveFont(
    manifest.typography.fontBody,
    color: colors.text,
    height: manifest.typography.lineHeightBody,
  );
  final heading = _resolveFont(
    manifest.typography.fontHeading,
    color: colors.text,
    weight: FontWeight.w600,
  );
  TextStyle headingAt(double size) => heading.copyWith(
        fontSize: size,
        // approximate CSS em → pixel: em * font size.
        letterSpacing: manifest.typography.letterSpacingHeading * size,
      );

  final textTheme = TextTheme(
    displayLarge: headingAt(36),
    displayMedium: headingAt(32),
    displaySmall: headingAt(28),
    headlineLarge: headingAt(24),
    headlineMedium: headingAt(22),
    headlineSmall: headingAt(20),
    titleLarge: headingAt(18),
    titleMedium: headingAt(16),
    titleSmall: headingAt(14),
    bodyLarge: body.copyWith(fontSize: 16),
    bodyMedium: body.copyWith(fontSize: 14),
    bodySmall: body.copyWith(fontSize: 12, color: colors.muted),
    labelLarge: body.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
    labelMedium: body.copyWith(fontSize: 12, fontWeight: FontWeight.w600),
    labelSmall:
        body.copyWith(fontSize: 11, color: colors.muted, letterSpacing: 0.4),
  );

  // When the manifest provides an animated background, every Scaffold needs
  // a transparent canvas so the background paints through. Pages that want
  // an opaque sheet (chat composer, modal bottom sheets) still use the
  // `surface` token. Classic themes without a background keep the bg fill.
  final scaffoldBg =
      manifest.background != null ? Colors.transparent : colors.bg;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: scaffoldBg,
    canvasColor: colors.surface,
    dividerColor: colors.border,
    fontFamily: manifest.typography.fontBody,
    textTheme: textTheme,
    cardTheme: CardThemeData(
      color: colors.surface,
      elevation: manifest.shape.shadowCard.isEmpty ? 0 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(manifest.shape.radiusCard),
        side: BorderSide(color: colors.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: colors.accent,
        foregroundColor: _onColorFor(colors.accent),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(manifest.shape.radiusButton),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.text,
        side: BorderSide(color: colors.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(manifest.shape.radiusButton),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: colors.accent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(manifest.shape.radiusButton),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surface,
      hintStyle: body.copyWith(color: colors.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(manifest.shape.radiusButton),
        borderSide: BorderSide(color: colors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(manifest.shape.radiusButton),
        borderSide: BorderSide(color: colors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(manifest.shape.radiusButton),
        borderSide: BorderSide(color: colors.accent, width: 1.5),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.bg,
      foregroundColor: colors.text,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: heading.copyWith(fontSize: 18),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: colors.surface,
      selectedItemColor: colors.accent,
      unselectedItemColor: colors.muted,
      showUnselectedLabels: true,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(manifest.shape.radiusModal),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(manifest.shape.radiusModal),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: colors.surface,
      contentTextStyle: body.copyWith(color: colors.text),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(manifest.shape.radiusButton),
      ),
    ),
    extensions: <ThemeExtension<dynamic>>[tokens],
  );
}

/// Pick black or white as the on-color for a fill, based on luminance.
/// Mirrors the heuristic the JS side did manually inside button styles.
Color _onColorFor(Color fill) {
  return fill.computeLuminance() > 0.55 ? Colors.black : Colors.white;
}

/// Map our PascalCase manifest font names to the canonical Google Fonts
/// family slug, then resolve through `GoogleFonts.getFont`. If the lookup
/// throws (typo, non-Google family, offline first-run), fall back to a
/// plain `TextStyle` with the family name so the platform's font matcher
/// can do its best. Either way the call site gets a usable `TextStyle`.
TextStyle _resolveFont(
  String family, {
  Color? color,
  double? height,
  FontWeight? weight,
}) {
  final canonical = _googleFontsName(family);
  try {
    return GoogleFonts.getFont(
      canonical,
      color: color,
      height: height,
      fontWeight: weight,
    );
  } catch (_) {
    return TextStyle(
      fontFamily: family,
      color: color,
      height: height,
      fontWeight: weight,
    );
  }
}

/// Strip CamelCase + insert spaces so manifest names line up with the
/// Google Fonts CDN's canonical labels. e.g. `'JetBrainsMono'` →
/// `'JetBrains Mono'`, `'CormorantGaramond'` → `'Cormorant Garamond'`.
/// Names that already contain spaces (or are single-word like `'Manrope'`)
/// pass through unchanged.
String _googleFontsName(String family) {
  if (family.contains(' ')) return family;
  final buf = StringBuffer();
  for (var i = 0; i < family.length; i++) {
    final c = family[i];
    if (i > 0 &&
        c == c.toUpperCase() &&
        c != c.toLowerCase() &&
        family[i - 1] != family[i - 1].toUpperCase()) {
      buf.write(' ');
    }
    buf.write(c);
  }
  return buf.toString();
}

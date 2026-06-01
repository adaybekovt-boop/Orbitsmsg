// Flutter port of the JS `ThemeManifest` from `git_push/src/themes/types.js`.
//
// A manifest is the *declarative* description of a theme. The JS side wrote
// space-separated `R G B` triplets into CSS custom properties; here we parse
// those at build time into real `Color` values and bake them into an
// `OrbitsTokens` extension via `theme_data_factory.dart`.
//
// We deliberately keep the field names in lockstep with the JS counterpart so
// porting individual manifests stays mechanical: copy the JS file, swap the
// hex/rgb syntax, point `background` at a Flutter `WidgetBuilder` instead of
// a dynamic `import()`. See `catalog/classic/graphite_manifest.dart` for the
// canonical example.
//
// The manifest itself is `const`-friendly (no mutable state, no closures
// captured at construction) so the registry can hold the catalog as a static
// `Map<String, ThemeManifest>` and there's no async load step. JS lazy-loads
// because each background is a separate framer-motion canvas chunk; on
// Flutter every theme is part of the same bundle so eager-loading is fine.
//
// Shape rationale:
//   - `tokens` is a typed sub-record (`ThemeTokenColors`) instead of the JS
//     `Record<string, string>` map. Type safety > parity.
//   - `shape` / `typography` / `motion` / `features` / `performance` mirror
//     JS exactly, with CSS-string fields converted to native types
//     (durations → `Duration`, ease → `Curve`, blur/radius → `double`).
//   - `background` is an optional `Widget Function(BuildContext)` rather
//     than the JS lazy-import. Returning `null` means the theme has no
//     animated layer (the bg color from tokens is all there is).

import 'package:flutter/material.dart';

/// Family grouping shown in the Settings → Themes picker. Matches the JS
/// `family: 'classic' | 'atmospheric'` discriminator.
enum ThemeFamily { classic, atmospheric }

/// Active-tab ornament hint for shared tab UI. Each theme picks one and the
/// `ChatTabs` widget renders the matching variant. Mirrors the JS string
/// union — see `types.js`.
enum ActiveTabOrnament { hankoStamp, ring, dot, glow, underline }

/// Message-bubble shape variant. Read by `MessageBubble`.
enum MessageBubbleStyle { rounded, lantern, bubble, octagon, paper, framedVoid }

/// Modal-enter animation. Read by `OrbitsModal` (will land in a later sweep).
enum ModalEnter {
  fadeScale,
  scrollUnroll,
  bookFlip,
  frostIn,
  prismUnfold,
  wireframeFill,
  crackExpand,
  smokeExhale,
  rippleUp,
  glitchDecompress,
}

/// What to do when `MediaQuery.disableAnimations` is true. `subtle` keeps a
/// hint of motion (short crossfade), `freeze` snaps without animation,
/// `disable` removes even the snap (useful for reduce-motion + epilepsy).
enum ReducedMotionFallback { subtle, freeze, disable }

/// Resolved colour palette. Each field corresponds to one of the nine
/// `--orb-*-rgb` CSS variables from the JS theme manifests, plus two locals
/// (`scrim`, `deliveryRead`) that the JS side hard-coded inside components.
@immutable
class ThemeTokenColors {
  const ThemeTokenColors({
    required this.bg,
    required this.surface,
    required this.border,
    required this.text,
    required this.muted,
    required this.accent,
    required this.accent2,
    required this.success,
    required this.danger,
    this.scrim = const Color(0xCC000000),
    this.deliveryRead = const Color(0xFFBFDBFE),
    this.bubbleOut = const Color(0xFF222B3C),
  });

  final Color bg;
  final Color surface;
  final Color border;
  final Color text;
  final Color muted;
  final Color accent;
  final Color accent2;
  final Color success;
  final Color danger;
  final Color scrim;
  final Color deliveryRead;

  /// Outgoing ("mine") message-bubble fill. Deliberately decoupled from
  /// `accent` so dark themes don't paint blinding near-white bubbles at night
  /// — a deep graphite-blue glass tone is used instead. Light themes put their
  /// confident dark ink here. The white accent stays reserved for buttons.
  final Color bubbleOut;
}

/// Shape tokens. Maps the JS shape strings (`'10px'`, `'0 4px 16px ...'`) to
/// native Flutter types. `shadowCard` is an arbitrary `BoxShadow` list so
/// themes can stack multiple shadows the way the JS `box-shadow: a, b, c`
/// syntax did.
@immutable
class ThemeShape {
  const ThemeShape({
    this.radiusButton = 10,
    this.radiusCard = 14,
    this.radiusModal = 18,
    this.shadowCard = const <BoxShadow>[],
    this.blurSurface = 0,
  });

  final double radiusButton;
  final double radiusCard;
  final double radiusModal;
  final List<BoxShadow> shadowCard;
  final double blurSurface;
}

/// Typography tokens. Font names are ordinary `fontFamily` strings — the
/// fonts themselves are declared in `pubspec.yaml`. Falling back to
/// `system-ui` is a no-op on Flutter (passing `null` to `TextStyle` does the
/// same thing); we keep the field non-null so the factory has something
/// concrete to write into the `TextTheme`.
@immutable
class ThemeTypography {
  const ThemeTypography({
    this.fontHeading = 'Manrope',
    this.fontBody = 'Manrope',
    this.fontMono = 'JetBrainsMono',
    this.letterSpacingHeading = -0.015,
    this.lineHeightBody = 1.55,
  });

  final String fontHeading;
  final String fontBody;
  final String fontMono;

  /// CSS `em`-equivalent letter spacing. Multiply by the heading font size
  /// at use site to get a Flutter pixel offset.
  final double letterSpacingHeading;
  final double lineHeightBody;
}

/// Motion tokens. JS used framer-motion seconds; we use `Duration` and a
/// `Curve` (`Cubic` if all four control points are present, falling back to
/// `Curves.easeInOut` if the manifest omits the easing).
@immutable
class ThemeMotion {
  const ThemeMotion({
    this.durationShort = const Duration(milliseconds: 200),
    this.durationMedium = const Duration(milliseconds: 350),
    this.durationLong = const Duration(milliseconds: 550),
    this.easing = Curves.easeInOutCubic,
    this.reducedMotionFallback = ReducedMotionFallback.subtle,
  });

  final Duration durationShort;
  final Duration durationMedium;
  final Duration durationLong;
  final Curve easing;
  final ReducedMotionFallback reducedMotionFallback;
}

/// Behavioural hints for shared widgets. Components read these without
/// knowing the active theme id, so we can swap themes without touching them.
@immutable
class ThemeFeatures {
  const ThemeFeatures({
    this.activeTabOrnament = ActiveTabOrnament.underline,
    this.messageBubbleStyle = MessageBubbleStyle.rounded,
    this.modalEnter = ModalEnter.fadeScale,
    this.particlesEnabled = false,
    this.reducedMotionMode = ReducedMotionFallback.subtle,
  });

  final ActiveTabOrnament activeTabOrnament;
  final MessageBubbleStyle messageBubbleStyle;
  final ModalEnter modalEnter;
  final bool particlesEnabled;
  final ReducedMotionFallback reducedMotionMode;
}

/// Performance budget. The atmospheric backgrounds read this through the
/// `PerfBudgetNotifier` and either degrade (drop particle count) or freeze
/// outright when the runtime fps drops below `minFPS`.
@immutable
class ThemePerformance {
  const ThemePerformance({
    this.minFPS = 30,
    this.degradeOnLowBattery = true,
    this.maxParticlesDesktop = 0,
    this.maxParticlesMobile = 0,
    this.maxParticlesLowEnd = 0,
  });

  final int minFPS;
  final bool degradeOnLowBattery;
  final int maxParticlesDesktop;
  final int maxParticlesMobile;
  final int maxParticlesLowEnd;
}

/// Full immutable theme description. Construct one of these per theme inside
/// `catalog/`, register it in `registry.dart`, and the factory does the
/// rest. Equivalent to a JS manifest object.
@immutable
class ThemeManifest {
  const ThemeManifest({
    required this.id,
    required this.name,
    this.subtitle,
    this.family = ThemeFamily.classic,
    required this.colorScheme,
    required this.tokens,
    this.shape = const ThemeShape(),
    this.typography = const ThemeTypography(),
    this.motion = const ThemeMotion(),
    this.features = const ThemeFeatures(),
    this.performance = const ThemePerformance(),
    this.background,
  });

  /// Stable id stored in `SharedPreferences` under key `orbits_theme`. Must
  /// match the catalog key in `registry.dart`.
  final String id;

  /// Human-readable title shown in the picker (e.g. "Graphite").
  final String name;

  /// Optional one-line tagline shown under `name` in the picker
  /// (e.g. "Слоистый графит").
  final String? subtitle;

  /// UI grouping in Settings. Classic = no animated background; atmospheric
  /// has a `background` builder (paper grain, sakura petals, etc).
  final ThemeFamily family;

  /// Drives `ThemeData.brightness` and the system status-bar overlay style.
  final Brightness colorScheme;

  final ThemeTokenColors tokens;
  final ThemeShape shape;
  final ThemeTypography typography;
  final ThemeMotion motion;
  final ThemeFeatures features;
  final ThemePerformance performance;

  /// Optional animated background painted *behind* the app shell. `null` →
  /// no animated layer (classic-graphite + classic-light go this route by
  /// default; sakura/matrix/paper provide one).
  final WidgetBuilder? background;
}

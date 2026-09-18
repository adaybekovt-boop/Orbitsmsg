// Liquid-glass optical stack.
//
// Two honest layers, never marketed as the same thing:
//   1. **Refraction** — Impeller `ImageFilter.shader` that samples the live
//      backdrop (whatever is actually behind the glass) and displaces UVs
//      with `assets/liquid-disp-map.webp`. This is real refraction of the
//      content behind the surface, not a painted film.
//   2. **Fallback** — clipped `ImageFilter.blur` + CustomPainter rims /
//      highlights when Impeller shaders are unavailable (Skia, tests,
//      load failure) or the user asked for reduced transparency / motion.
//
// Cost: one shader program and one displacement image for the process.
// Filters are attached only to chrome (nav, switcher, composer, buttons),
// never to scrolling list rows.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../backdrop/orbits_wallpaper.dart';

enum OrbitsGlassOpticsMode {
  /// Impeller fragment shader displacing the live backdrop.
  refraction,

  /// Clipped BackdropFilter blur + painted optical edge. Not refraction.
  blurFallback,

  /// Opaque plate (high contrast / reduce transparency).
  solid,
}

class OrbitsLiquidOptics {
  OrbitsLiquidOptics._();
  static final OrbitsLiquidOptics instance = OrbitsLiquidOptics._();

  final ValueNotifier<bool> ready = ValueNotifier<bool>(false);

  ui.FragmentProgram? _program;
  ui.Image? _disp;
  bool _loading = false;
  bool _failed = false;

  bool get refractionReady =>
      ready.value &&
      _program != null &&
      _disp != null &&
      ui.ImageFilter.isShaderFilterSupported;

  OrbitsGlassOpticsMode modeFor({
    required bool highContrast,
    required bool allowRealBlur,
  }) {
    if (highContrast) return OrbitsGlassOpticsMode.solid;
    if (allowRealBlur && refractionReady) {
      return OrbitsGlassOpticsMode.refraction;
    }
    if (allowRealBlur) return OrbitsGlassOpticsMode.blurFallback;
    return OrbitsGlassOpticsMode.blurFallback;
  }

  Future<void> ensureLoaded() async {
    if (ready.value || _loading || _failed) return;
    if (!ui.ImageFilter.isShaderFilterSupported) {
      _failed = true;
      return;
    }
    _loading = true;
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'shaders/liquid_refraction.frag',
      );
      final data = await rootBundle.load(OrbitsWallpaper.displacementMap);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      _program = program;
      _disp = frame.image;
      ready.value = true;
    } catch (err, stack) {
      _failed = true;
      debugPrint('OrbitsLiquidOptics: refraction unavailable ($err)');
      debugPrint('$stack');
    } finally {
      _loading = false;
    }
  }

  /// Live-backdrop filter. [strength] is UV displacement amplitude
  /// (React objectBoundingBox scale 0.32 ≈ 0.12–0.28 in texture space).
  ui.ImageFilter backdropFilter({
    required double blurSigma,
    required double strength,
    Rect? bounds,
  }) {
    final blur = ui.ImageFilter.blur(
      sigmaX: blurSigma,
      sigmaY: blurSigma,
      bounds: bounds,
    );
    if (!refractionReady || strength <= 0) return blur;
    try {
      final shader = _program!.fragmentShader();
      // floats 0–1 are u_size, written by the engine.
      shader.setFloat(2, strength);
      shader.setImageSampler(1, _disp!);
      return ui.ImageFilter.compose(
        inner: blur,
        outer: ui.ImageFilter.shader(shader),
      );
    } catch (err) {
      debugPrint('OrbitsLiquidOptics: shader filter failed ($err)');
      return blur;
    }
  }
}

/// Resolves the active optics mode for tests and the settings copy.
OrbitsGlassOpticsMode resolveOrbitsGlassOptics({
  required bool highContrast,
  required bool allowRealBlur,
  required bool refractionReady,
}) {
  if (highContrast) return OrbitsGlassOpticsMode.solid;
  if (allowRealBlur && refractionReady) {
    return OrbitsGlassOpticsMode.refraction;
  }
  return OrbitsGlassOpticsMode.blurFallback;
}

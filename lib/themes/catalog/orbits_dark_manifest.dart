// Orbits Dark — the default theme. Deep neutral graphite / near-black canvas
// with a thin luminous glass film. STRICTLY monochrome: black / white / gray.
// The "accent" is a near-white — primary actions read as a bright frosted
// material, selected nav as a white glyph, focus rings as a white hairline.
// No blue, no teal. Only success (green) / danger (red) stay as functional
// semantic colours. Glass tints/borders/shadows are brightness-derived in
// theme_data_factory.dart, so the palette here only carries the solid colours.

import 'package:flutter/material.dart';

import '../../ui/backdrop/orbits_backdrop.dart';
import '../manifest.dart';

const ThemeManifest orbitsDarkManifest = ThemeManifest(
  id: 'orbits-dark',
  name: 'Тёмная',
  subtitle: 'Графит и стекло',
  family: ThemeFamily.classic,
  colorScheme: Brightness.dark,
  tokens: ThemeTokenColors(
    bg: Color(0xFF0C0D10),
    surface: Color(0xFF16181D),
    border: Color(0x1FFFFFFF),
    text: Color(0xFFF2F3F5),
    muted: Color(0xFF9BA1AC),
    // Monochrome accent: a soft near-white. Primary buttons become a bright
    // frosted material with dark text; nav/focus pick this up automatically.
    accent: Color(0xFFEDEFF2),
    // Secondary = a calm light gray (used by "connecting"/secondary states).
    accent2: Color(0xFFAEB4BE),
    success: Color(0xFF34C759),
    danger: Color(0xFFFF453A),
    scrim: Color(0xCC000000),
    // Read-tick stays neutral gray (was brand-blue) to keep the palette mono.
    deliveryRead: Color(0xFF8E949E),
    // Outgoing bubbles: deep graphite-blue glass, NOT the blinding near-white
    // accent. Reads as a calm dark tile at night; a hairline accent rim (added
    // in message_bubble.dart) gives it the luminous glass edge.
    bubbleOut: Color(0xFF20293B),
  ),
  shape: ThemeShape(
    radiusButton: 14,
    radiusCard: 18,
    radiusModal: 26,
    blurSurface: 0,
    shadowCard: <BoxShadow>[
      BoxShadow(
        color: Color(0x40000000),
        blurRadius: 24,
        offset: Offset(0, 8),
      ),
    ],
  ),
  typography: ThemeTypography(
    fontHeading: 'Manrope',
    fontBody: 'Inter',
    fontMono: 'JetBrainsMono',
    letterSpacingHeading: -0.015,
    lineHeightBody: 1.5,
  ),
  motion: ThemeMotion(
    durationShort: Duration(milliseconds: 140),
    durationMedium: Duration(milliseconds: 240),
    durationLong: Duration(milliseconds: 400),
    easing: Curves.easeOutCubic,
  ),
  features: ThemeFeatures(
    activeTabOrnament: ActiveTabOrnament.glow,
    messageBubbleStyle: MessageBubbleStyle.rounded,
    modalEnter: ModalEnter.fadeScale,
  ),
  // A static monochrome backdrop (graphite base + soft neutral glows) sits
  // behind the whole app so the glass surfaces have luminance to refract —
  // without it, blur over a flat fill reads as "no glass".
  background: orbitsBackdropBuilder,
);

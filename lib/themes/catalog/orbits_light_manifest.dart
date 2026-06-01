// Orbits Light — clean, cool off-white surface (NOT cream/sand), frosted-white
// glass panels. STRICTLY monochrome: black / white / gray. The "accent" is a
// near-black ink, so primary actions read as a confident black material with
// white text; selected nav / focus rings pick it up automatically. No blue, no
// teal. Only success (green) / danger (red) stay as functional semantics.
// High text contrast, hairline borders, airy shadows.

import 'package:flutter/material.dart';

import '../../ui/backdrop/orbits_backdrop.dart';
import '../manifest.dart';

const ThemeManifest orbitsLightManifest = ThemeManifest(
  id: 'orbits-light',
  name: 'Светлая',
  subtitle: 'Чистое стекло',
  family: ThemeFamily.classic,
  colorScheme: Brightness.light,
  tokens: ThemeTokenColors(
    bg: Color(0xFFF4F6F9),
    surface: Color(0xFFFFFFFF),
    border: Color(0xFFE3E7ED),
    text: Color(0xFF14181F),
    muted: Color(0xFF697586),
    // Monochrome accent: near-black ink. Primary buttons become a confident
    // black material with white text; nav/focus pick this up automatically.
    accent: Color(0xFF1C2129),
    // Secondary = a mid gray (used by "connecting"/secondary states).
    accent2: Color(0xFF5B6472),
    success: Color(0xFF1F9D55),
    danger: Color(0xFFE5484D),
    scrim: Color(0xCC000000),
    // Read-tick stays neutral gray (was brand-blue) to keep the palette mono.
    deliveryRead: Color(0xFF697586),
    // Outgoing bubbles: confident dark ink (matches the light accent) with
    // white text — same as before, just no longer tied to `accent` directly.
    bubbleOut: Color(0xFF1C2129),
  ),
  shape: ThemeShape(
    radiusButton: 14,
    radiusCard: 18,
    radiusModal: 26,
    blurSurface: 0,
    shadowCard: <BoxShadow>[
      BoxShadow(
        color: Color(0x141B2533),
        blurRadius: 20,
        offset: Offset(0, 6),
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
  // Static monochrome backdrop (off-white base + soft neutral clouds) so the
  // frosted-white glass panels have luminance variation to refract.
  background: orbitsBackdropBuilder,
);

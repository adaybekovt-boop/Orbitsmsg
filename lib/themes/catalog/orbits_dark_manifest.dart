// Orbits Dark — React photographic theme. Near-black canvas over the space
// horizon wallpaper. Accent is white; outgoing bubbles are brand blue
// (#2563eb). Semantic green / danger stay functional.

import 'package:flutter/material.dart';

import '../../ui/backdrop/orbits_backdrop.dart';
import '../manifest.dart';

const ThemeManifest orbitsDarkManifest = ThemeManifest(
  id: 'orbits-dark',
  name: 'Тёмная',
  subtitle: 'Космос и стекло',
  family: ThemeFamily.classic,
  colorScheme: Brightness.dark,
  tokens: ThemeTokenColors(
    bg: Color(0xFF000000),
    surface: Color(0xFF0C0C0C),
    border: Color(0x17FFFFFF),
    text: Color(0xFFF5F5F7),
    muted: Color(0xFF8E8E93),
    accent: Color(0xFFFFFFFF),
    accent2: Color(0xFF8E8E93),
    success: Color(0xFF34D399),
    danger: Color(0xFFEF4444),
    scrim: Color(0xCC000000),
    deliveryRead: Color(0xFF93C5FD),
    bubbleOut: Color(0xFF2563EB),
  ),
  shape: ThemeShape(
    radiusButton: 16,
    radiusCard: 24,
    radiusModal: 24,
    blurSurface: 0,
    shadowCard: <BoxShadow>[
      BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 8)),
    ],
  ),
  typography: ThemeTypography(
    fontHeading: 'Inter',
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
  background: orbitsBackdropBuilder,
);

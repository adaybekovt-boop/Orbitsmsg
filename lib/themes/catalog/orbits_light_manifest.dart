// Orbits Light — React alpine daylight theme. Cool slate text over the
// mountain wallpaper. Accent and outgoing bubbles are brand blue (#2563eb).

import 'package:flutter/material.dart';

import '../../ui/backdrop/orbits_backdrop.dart';
import '../manifest.dart';

const ThemeManifest orbitsLightManifest = ThemeManifest(
  id: 'orbits-light',
  name: 'Светлая',
  subtitle: 'Альпы и стекло',
  family: ThemeFamily.classic,
  colorScheme: Brightness.light,
  tokens: ThemeTokenColors(
    bg: Color(0xFFF8FAFC),
    surface: Color(0xFFFFFFFF),
    border: Color(0x14000000),
    text: Color(0xFF0F172A),
    muted: Color(0xFF475569),
    accent: Color(0xFF2563EB),
    accent2: Color(0xFF1D4ED8),
    success: Color(0xFF16A34A),
    danger: Color(0xFFEF4444),
    scrim: Color(0xCC000000),
    deliveryRead: Color(0xFF2563EB),
    bubbleOut: Color(0xFF2563EB),
  ),
  shape: ThemeShape(
    radiusButton: 16,
    radiusCard: 24,
    radiusModal: 24,
    blurSurface: 0,
    shadowCard: <BoxShadow>[
      BoxShadow(color: Color(0x141B2533), blurRadius: 20, offset: Offset(0, 6)),
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

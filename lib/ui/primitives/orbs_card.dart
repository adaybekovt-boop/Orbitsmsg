// Reusable surface primitives that match the JS app's visual language.
//
// The React build leans heavily on a small set of shapes:
//   • `rounded-3xl bg-bg/35 p-4 ring-1 ring-border` — section card on
//     Settings / Drop / ChatSettings
//   • `rounded-2xl bg-surface/60 px-4 py-3 ring-1 ring-border` — list row
//     (chat list, peer card on Drop)
//   • `rounded-2xl bg-bg/40 ring-1 ring-white/[0.08]` — input field shell
//   • `[data-orb-section-title]` — uppercase tracking-wide muted label
//
// Every screen consumes the same handful of shapes, so we lift them into
// these primitives and call them by name. That way the spacing / radius
// / border-color story stays consistent when we swap themes — a Sakura
// surface card looks recognisably "the same component" as a Graphite
// one, just with different tokens behind it.

import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';
import 'orbits_glass_surface.dart';
import 'orbits_glass_switch.dart';

/// `rounded-3xl bg-bg/35 p-4 ring-1 ring-border` — the section-card
/// shape that appears on Settings rows, ChatSettings panels, Drop
/// state cards. Padding defaults match the JS `p-4` (16 px) but the
/// caller can override when a tighter inset is needed (e.g. inside a
/// dense toggle list).
class OrbsCard extends StatelessWidget {
  const OrbsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.tinted = true,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  /// `true` → use the slightly translucent `bg/35` look (the card sits
  /// on a darker page). `false` → use the solid `surface` token, for
  /// list rows that already sit on `bg`.
  final bool tinted;

  /// If non-null the whole card becomes tappable with a Material ripple.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final radius = BorderRadius.circular(tokens.radiusCard + 4);
    // Painted fake-glass section card (no per-card BackdropFilter — these stack
    // in scrolling Settings / Drop lists). `tinted` cards sit on the darker
    // page and carry a touch more film; flat cards lean lighter so nested rows
    // stay legible against the surface below. Built on [OrbitsGlassSurface] so
    // every card shares the one Liquid-Glass material (sheen + rim + shadow).
    Widget card = OrbitsGlassSurface(
      role: OrbitsGlassRole.card,
      borderRadius: radius,
      intensity: tinted ? 1.0 : 0.7,
      padding: onTap == null ? padding : null,
      child: onTap == null
          ? child
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: radius,
                child: Padding(padding: padding, child: child),
              ),
            ),
    );
    if (margin != null) {
      card = Padding(padding: margin!, child: card);
    }
    return card;
  }
}

/// `rounded-2xl bg-surface/60 px-4 py-3 ring-1 ring-border` — the
/// peer-row / list-tile shape used on chat list, contact list, drop
/// peer list. Carries a small accent stripe + ripple when [active]
/// mirrors `[data-orb-active="true"]` in the JS skin.
class OrbsTile extends StatelessWidget {
  const OrbsTile({
    super.key,
    required this.child,
    this.onTap,
    this.active = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool active;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final radius = BorderRadius.circular(tokens.radiusCard);
    // Painted fake-glass list row (chat / contact / Drop peer lists). `active`
    // leans on the surface's selected state (stronger tint + accent-leaning
    // rim) rather than a hand-painted accent border, so it reads identically to
    // every other glass row in the app.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: OrbitsGlassSurface(
        role: OrbitsGlassRole.card,
        selected: active,
        borderRadius: radius,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// `[data-orb-section-title]` — uppercase, monospace caps, muted, used
/// above every settings / chat-settings group.
class OrbsSectionTitle extends StatelessWidget {
  const OrbsSectionTitle(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          fontFamily: tokens.fontMono,
          color: tokens.muted,
          letterSpacing: 1.6,
        ),
      ),
    );
  }
}

/// Round h-11 w-11 icon button — the bare-metal action button used in
/// composers, headers, and mid-row actions. Wraps `Material + InkWell`
/// so taps feel native, with a subtle hover/press tint pulled from the
/// active theme.
class OrbsIconButton extends StatelessWidget {
  const OrbsIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.size = 40,
    this.iconSize = 20,
    this.tinted = false,
    this.danger = false,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final double iconSize;

  /// `true` → fill with the accent tint (e.g. send button); `false` →
  /// transparent background like the secondary header buttons.
  final bool tinted;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final fg = danger
        ? tokens.danger
        : (tinted ? tokens.accent : tokens.text);
    final bg = tinted
        ? tokens.accentAlpha(0.18)
        : (danger ? tokens.dangerAlpha(0.10) : Colors.transparent);
    final btn = Material(
      color: bg,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: iconSize, color: fg),
        ),
      ),
    );
    final tip = tooltip;
    if (tip == null) return btn;
    return Tooltip(message: tip, child: btn);
  }
}

/// Custom h-5 w-9 toggle that matches the JS pill-switch — animated dot
/// slides 0 → 16 px, background lerps from surface to accent.
class OrbsToggle extends StatelessWidget {
  const OrbsToggle({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    // Delegates to the shared Liquid-Glass toggle so every switch in the app
    // is the one glass capsule + prismatic-rim thumb instead of a flat
    // Material-style pill.
    return OrbitsGlassSwitch(
      value: value,
      onChanged: onChanged,
      size: OrbitsGlassSwitchSize.compact,
    );
  }
}

/// One row inside a settings card — label on the left, optional
/// subtitle below it, control widget on the right (toggle, chevron,
/// counter, value chip). Mirrors the JS `flex items-center justify-
/// between gap-3` row pattern used wall-to-wall in Settings/ChatSettings.
class OrbsSettingRow extends StatelessWidget {
  const OrbsSettingRow({
    super.key,
    required this.label,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final String label;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: tokens.text,
                    fontFamily: tokens.fontBody,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.muted,
                      fontFamily: tokens.fontBody,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(tokens.radiusButton),
      child: row,
    );
  }
}

/// Hairline divider between rows inside a card. JS uses `h-px bg-border/40`.
class OrbsDivider extends StatelessWidget {
  const OrbsDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: tokens.border.withValues(alpha: 0.5),
    );
  }
}

/// `OrbsAvatar` — round avatar with optional online-dot indicator.
/// Falls back to the first letter of the display name on a tinted
/// circle when `imageBytes` is null. Matches the JS `[data-orb-avatar]`
/// behaviour across all four themes (each theme styles the same data
/// attribute differently — Sakura uses serif italic, Matrix uses
/// monospace caps, etc.).
class OrbsAvatar extends StatelessWidget {
  const OrbsAvatar({
    super.key,
    required this.fallbackInitial,
    this.imageBytes,
    this.size = 44,
    this.online = false,
  });

  final String fallbackInitial;
  final dynamic imageBytes; // Uint8List? — kept dynamic to avoid the import
  final double size;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final dotSize = (size / 4).clamp(8.0, 14.0);
    Widget face;
    if (imageBytes != null) {
      face = ClipOval(
        child: Image.memory(
          imageBytes,
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth:
              (size * MediaQuery.devicePixelRatioOf(context)).round(),
        ),
      );
    } else {
      face = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: tokens.accentAlpha(0.18),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          fallbackInitial,
          style: TextStyle(
            fontSize: size * 0.42,
            fontWeight: FontWeight.w600,
            fontFamily: tokens.fontHeading,
            color: tokens.accent,
          ),
        ),
      );
    }
    if (!online) return face;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        face,
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              color: tokens.success,
              shape: BoxShape.circle,
              border: Border.all(color: tokens.bg, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

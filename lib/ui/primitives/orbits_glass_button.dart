// Liquid-Glass button family, all built on [OrbitsGlassSurface] + a shared
// interactive shell (`_GlassButtonCore`) that handles press-scale, desktop
// hover, keyboard focus ring, disabled state, Semantics and tooltips.
//
//   OrbitsGlassButton      — icon + label, 4 variants × 4 sizes
//   OrbitsGlassIconButton  — icon-only (tooltip required for a11y)
//   OrbitsGlassPillButton  — pill-shaped label button (chips / segmented use)
//
// Size never changes on hover/press (scale only), so text never reflows.

import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';
import 'orbits_glass_surface.dart';

enum OrbitsGlassVariant { primary, secondary, subtle, danger }

enum OrbitsGlassSize { small, medium, large, icon }

class _Metrics {
  const _Metrics(this.minHeight, this.padH, this.fontSize, this.iconSize, this.gap);
  final double minHeight;
  final double padH;
  final double fontSize;
  final double iconSize;
  final double gap;
}

_Metrics _metricsFor(OrbitsGlassSize size) {
  switch (size) {
    case OrbitsGlassSize.small:
      return const _Metrics(34, 14, 13, 16, 6);
    case OrbitsGlassSize.medium:
      return const _Metrics(44, 18, 14, 18, 8);
    case OrbitsGlassSize.large:
      return const _Metrics(54, 22, 16, 20, 10);
    case OrbitsGlassSize.icon:
      return const _Metrics(44, 0, 14, 22, 0);
  }
}

Color _onColorFor(Color fill) =>
    fill.computeLuminance() > 0.6 ? Colors.black : Colors.white;

/// Interactive shell — wraps a builder that paints per (hovered, pressed,
/// focused). Centralises press-scale, hover/focus tracking, keyboard
/// activation, Semantics, and tooltip.
class _GlassButtonCore extends StatefulWidget {
  const _GlassButtonCore({
    required this.onPressed,
    required this.enabled,
    required this.semanticLabel,
    required this.builder,
    this.tooltip,
  });

  final VoidCallback? onPressed;
  final bool enabled;
  final String semanticLabel;
  final String? tooltip;
  final Widget Function(bool hovered, bool pressed, bool focused) builder;

  @override
  State<_GlassButtonCore> createState() => _GlassButtonCoreState();
}

class _GlassButtonCoreState extends State<_GlassButtonCore> {
  bool _hover = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    final enabled = widget.enabled && widget.onPressed != null;

    Widget core = widget.builder(_hover && enabled, _pressed && enabled, _focused && enabled);

    core = AnimatedScale(
      scale: (_pressed && enabled) ? t.pressScale : 1.0,
      duration: t.durationFast,
      curve: Curves.easeOut,
      child: core,
    );

    core = FocusableActionDetector(
      enabled: enabled,
      mouseCursor:
          enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onShowHoverHighlight: (h) {
        if (h != _hover) setState(() => _hover = h);
      },
      onShowFocusHighlight: (f) {
        if (f != _focused) setState(() => _focused = f);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: enabled ? widget.onPressed : null,
        child: core,
      ),
    );

    core = Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      child: core,
    );

    final tip = widget.tooltip;
    if (tip != null && tip.isNotEmpty) {
      core = Tooltip(message: tip, child: core);
    }
    return Opacity(opacity: enabled ? 1.0 : 0.45, child: core);
  }
}

/// Shared painter for the button face given variant + focus state.
Widget _glassFace({
  required BuildContext context,
  required OrbitsGlassVariant variant,
  required bool focused,
  required bool hovered,
  required double minHeight,
  required EdgeInsets padding,
  required BorderRadius radius,
  required Widget child,
}) {
  final t = OrbitsTokens.of(context);
  Color? fill;
  Color? tint;
  double intensity = 1.0;
  switch (variant) {
    case OrbitsGlassVariant.primary:
      fill = t.accent;
    case OrbitsGlassVariant.danger:
      fill = t.danger;
    case OrbitsGlassVariant.secondary:
      tint = hovered ? t.accent : null;
      intensity = hovered ? 1.15 : 1.0;
    case OrbitsGlassVariant.subtle:
      intensity = hovered ? 0.85 : 0.6;
  }

  final surface = OrbitsGlassSurface(
    role: radius.topLeft.x >= 999 ? OrbitsGlassRole.pill : OrbitsGlassRole.button,
    borderRadius: radius,
    fill: fill,
    tint: tint,
    intensity: intensity,
    prismatic: true,
    padding: padding,
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Center(widthFactor: 1, heightFactor: 1, child: child),
    ),
  );

  if (!focused) return surface;
  // Focus ring as an overlay so layout never shifts.
  return Stack(
    children: [
      surface,
      Positioned.fill(
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: t.accent, width: 2),
            ),
          ),
        ),
      ),
    ],
  );
}

class OrbitsGlassButton extends StatelessWidget {
  const OrbitsGlassButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.variant = OrbitsGlassVariant.secondary,
    this.size = OrbitsGlassSize.medium,
    this.enabled = true,
    this.expand = false,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final OrbitsGlassVariant variant;
  final OrbitsGlassSize size;
  final bool enabled;

  /// Stretch to the parent's width (full-width CTA).
  final bool expand;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    final m = _metricsFor(size);
    final fg = switch (variant) {
      OrbitsGlassVariant.primary => _onColorFor(t.accent),
      OrbitsGlassVariant.danger => _onColorFor(t.danger),
      OrbitsGlassVariant.secondary => t.text,
      OrbitsGlassVariant.subtle => t.text,
    };
    final radius = BorderRadius.circular(t.radiusButton);

    return _GlassButtonCore(
      onPressed: onPressed,
      enabled: enabled,
      semanticLabel: label,
      tooltip: tooltip,
      builder: (hovered, pressed, focused) {
        final row = Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: m.iconSize, color: fg),
              SizedBox(width: m.gap),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: t.fontHeading,
                  fontSize: m.fontSize,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ),
          ],
        );
        return _glassFace(
          context: context,
          variant: variant,
          focused: focused,
          hovered: hovered,
          minHeight: m.minHeight,
          padding: EdgeInsets.symmetric(horizontal: m.padH),
          radius: radius,
          child: row,
        );
      },
    );
  }
}

class OrbitsGlassIconButton extends StatelessWidget {
  const OrbitsGlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.variant = OrbitsGlassVariant.secondary,
    this.size = OrbitsGlassSize.icon,
    this.enabled = true,
    this.selected = false,
  });

  final IconData icon;

  /// Required — icon-only controls must be labelled for a11y.
  final String tooltip;
  final VoidCallback? onPressed;
  final OrbitsGlassVariant variant;
  final OrbitsGlassSize size;
  final bool enabled;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    final m = _metricsFor(size);
    final dim = m.minHeight;
    final fg = switch (variant) {
      OrbitsGlassVariant.primary => _onColorFor(t.accent),
      OrbitsGlassVariant.danger => _onColorFor(t.danger),
      _ => selected ? t.accent : t.text,
    };
    final radius = BorderRadius.circular(t.radiusButton);

    return _GlassButtonCore(
      onPressed: onPressed,
      enabled: enabled,
      semanticLabel: tooltip,
      tooltip: tooltip,
      builder: (hovered, pressed, focused) {
        final face = OrbitsGlassSurface(
          role: OrbitsGlassRole.button,
          borderRadius: radius,
          selected: selected,
          prismatic: true,
          fill: variant == OrbitsGlassVariant.primary
              ? t.accent
              : variant == OrbitsGlassVariant.danger
                  ? t.danger
                  : null,
          tint: variant == OrbitsGlassVariant.secondary && hovered
              ? t.accent
              : null,
          child: SizedBox(
            width: dim,
            height: dim,
            child: Center(child: Icon(icon, size: m.iconSize, color: fg)),
          ),
        );
        if (!focused) return face;
        return Stack(children: [
          face,
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: t.accent, width: 2),
                ),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class OrbitsGlassPillButton extends StatelessWidget {
  const OrbitsGlassPillButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.variant = OrbitsGlassVariant.secondary,
    this.size = OrbitsGlassSize.medium,
    this.enabled = true,
    this.selected = false,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final OrbitsGlassVariant variant;
  final OrbitsGlassSize size;
  final bool enabled;
  final bool selected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    final m = _metricsFor(size);
    final fg = switch (variant) {
      OrbitsGlassVariant.primary => _onColorFor(t.accent),
      OrbitsGlassVariant.danger => _onColorFor(t.danger),
      _ => selected ? t.accent : t.text,
    };
    final radius = BorderRadius.circular(999);

    return _GlassButtonCore(
      onPressed: onPressed,
      enabled: enabled,
      semanticLabel: label,
      tooltip: tooltip,
      builder: (hovered, pressed, focused) {
        final content = Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: m.iconSize, color: fg),
              SizedBox(width: m.gap),
            ],
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: t.fontHeading,
                fontSize: m.fontSize,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        );
        final face = OrbitsGlassSurface(
          role: OrbitsGlassRole.pill,
          borderRadius: radius,
          selected: selected,
          prismatic: true,
          fill: variant == OrbitsGlassVariant.primary
              ? t.accent
              : variant == OrbitsGlassVariant.danger
                  ? t.danger
                  : null,
          tint: (variant == OrbitsGlassVariant.secondary && hovered)
              ? t.accent
              : null,
          padding: EdgeInsets.symmetric(horizontal: m.padH),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: m.minHeight),
            child: Center(widthFactor: 1, child: content),
          ),
        );
        if (!focused) return face;
        return Stack(children: [
          face,
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: t.accent, width: 2),
                ),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

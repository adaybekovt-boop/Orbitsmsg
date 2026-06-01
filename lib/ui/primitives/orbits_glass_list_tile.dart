// OrbitsGlassListTile — the single Liquid-Glass row used everywhere a list of
// tappable rows appears (chat list, settings home, sub-settings, pickers).
//
// One consistent surface so the app never mixes glass rows with Material
// `ListTile` / `Card`. It's a painted fake-glass `card` surface (rows live in
// scrolling lists → never a per-row BackdropFilter) with an ink-ripple tap
// region clipped to the rounded shape.
//
// Layout = [leading] · Expanded(title / subtitle) · [trailing]. Title/subtitle
// inherit sensible glass typography via DefaultTextStyle so call sites only
// pass `Text('…')` (or a richer widget when they need it).

import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';
import 'orbits_glass_surface.dart';

class OrbitsGlassListTile extends StatelessWidget {
  const OrbitsGlassListTile({
    super.key,
    this.leading,
    this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.padding = const EdgeInsets.all(14),
  });

  final Widget? leading;
  final Widget? title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    final radius = BorderRadius.circular(t.radiusCard);

    final row = Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (title != null)
                DefaultTextStyle.merge(
                  style: TextStyle(
                    fontFamily: t.fontHeading,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                  child: title!,
                ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                DefaultTextStyle.merge(
                  style: TextStyle(
                    fontFamily: t.fontBody,
                    fontSize: 12.5,
                    height: 1.3,
                    color: t.muted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  child: subtitle!,
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 10), trailing!],
      ],
    );

    return OrbitsGlassSurface(
      role: OrbitsGlassRole.card,
      selected: selected,
      borderRadius: radius,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: radius,
          child: Padding(padding: padding, child: row),
        ),
      ),
    );
  }
}

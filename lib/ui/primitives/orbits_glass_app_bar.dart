// OrbitsGlassAppBar — the single Liquid-Glass top app bar used across every
// page. It centralises the chrome that was previously copy-pasted into ~20
// Scaffolds: a fully transparent Material [AppBar] (no tint, no elevation, no
// scrolled-under shading) whose `flexibleSpace` is one real-blur-capable
// [OrbitsGlassSurface] (`appBar` role → real BackdropFilter on Impeller
// platforms, painted fake-glass on Web/Windows).
//
// It is a thin, behaviour-preserving wrapper: it builds a stock [AppBar]
// internally, so everything Material gives an app bar (leading back button,
// title centring rules, `bottom` TabBar, system overlay style, scrolling
// SliverAppBar interplay via Scaffold) keeps working unchanged. Pages only
// pass the parts that actually vary — title, actions, leading, etc.
//
// Implements [PreferredSizeWidget] so it drops straight into
// `Scaffold(appBar: …)`; its preferred height mirrors the inner AppBar's
// (toolbar + optional `bottom`).

import 'package:flutter/material.dart';

import 'orbits_glass_surface.dart';

class OrbitsGlassAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const OrbitsGlassAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.centerTitle,
    this.titleSpacing,
    this.iconTheme,
    this.bottom,
    this.toolbarHeight,
    this.borderRadius =
        const BorderRadius.vertical(bottom: Radius.circular(20)),
  });

  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;
  final bool? centerTitle;
  final double? titleSpacing;

  /// Optional override for the leading/automatic-back icon colour. Defaults to
  /// the active [AppBarTheme] (which tracks the theme's text colour).
  final IconThemeData? iconTheme;

  /// Optional bottom widget (e.g. a `TabBar`). Counted into [preferredSize].
  final PreferredSizeWidget? bottom;

  /// Override the toolbar height. `null` ⇒ Material's [kToolbarHeight].
  final double? toolbarHeight;

  /// Corner rounding of the glass strip. Defaults to a rounded bottom edge so
  /// the bar reads as a floating glass shelf over the scrolling content.
  final BorderRadius borderRadius;

  @override
  Size get preferredSize => Size.fromHeight(
        (toolbarHeight ?? kToolbarHeight) +
            (bottom?.preferredSize.height ?? 0.0),
      );

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      automaticallyImplyLeading: automaticallyImplyLeading,
      leading: leading,
      title: title,
      actions: actions,
      centerTitle: centerTitle,
      titleSpacing: titleSpacing,
      iconTheme: iconTheme,
      toolbarHeight: toolbarHeight,
      bottom: bottom,
      // Frosted glass header strip — real blur on Impeller platforms, painted
      // glass on Web/Windows. Fills the whole bar (toolbar + bottom) behind
      // the title and actions.
      flexibleSpace: OrbitsGlassSurface(
        role: OrbitsGlassRole.appBar,
        borderRadius: borderRadius,
        child: const SizedBox.expand(),
      ),
    );
  }
}

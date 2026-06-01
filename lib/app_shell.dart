// App shell — four sections (Чаты / Drop / Игры / Ещё) over an IndexedStack
// (so each tab's subtree stays mounted across switches).
//
// Liquid Glass redesign (Stage 2): the navigation chrome is glass —
//   • phone  → a floating glass bottom nav bar (OrbitsGlassSurface navBar)
//   • desktop→ a glass left sidebar + centered, max-width content panel
//     (fixes the Windows "stretched-mobile / drifts-left" layout).
// Icons are Phosphor (Light weight idle, Fill for the active tab). The accent
// appears only on the active item — everything else is black/white/gray glass.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'core/haptics.dart';
import 'pages/chats_page.dart';
import 'pages/drop_page.dart';
import 'pages/games_page.dart';
import 'pages/servers_page.dart';
import 'pages/settings_page.dart';
import 'state/calls_provider.dart';
import 'state/drop_provider.dart';
import 'state/messaging_notifier.dart';
import 'themes/orbits_tokens.dart';
import 'ui/calls/call_overlay_mount.dart';
import 'ui/peer/peer_status_pill.dart';
import 'ui/primitives/orbits_glass_surface.dart';

/// Which tab is currently selected. Exposed as a provider so pages can read
/// or drive it (e.g. a "go to Chats" call-to-action from settings).
final activeTabProvider = StateProvider<AppTab>((ref) => AppTab.chats);

enum AppTab { chats, drop, games, rooms, settings }

/// One navigation destination. `iconFor` returns the Phosphor glyph at the
/// requested weight so idle = Light, active = Fill.
class _NavDest {
  const _NavDest(this.tab, this.iconFor, this.label);
  final AppTab tab;
  final PhosphorIconData Function(PhosphorIconsStyle) iconFor;
  final String label;
}

const List<_NavDest> _destinations = [
  _NavDest(AppTab.chats, PhosphorIcons.chatCircle, 'Чаты'),
  _NavDest(AppTab.drop, PhosphorIcons.arrowsDownUp, 'Drop'),
  _NavDest(AppTab.games, PhosphorIcons.gameController, 'Игры'),
  _NavDest(AppTab.rooms, PhosphorIcons.usersThree, 'Серверы'),
  _NavDest(AppTab.settings, PhosphorIcons.slidersHorizontal, 'Ещё'),
];

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  static const double _desktopShellMaxWidth = 1280;
  static const double _desktopSidebarWidth = 116;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeTabProvider);
    final tokens = OrbitsTokens.of(context);

    // Eagerly materialise notifiers whose constructors bind to PeerJS events
    // (see prior comment). ref.listen subscribes without rebuilding the shell.
    ref.listen(messagingNotifierProvider, (_, __) {});
    ref.listen(callsNotifierProvider, (_, __) {});
    ref.listen(dropNotifierProvider, (_, __) {});

    final shellBody = Stack(
      children: [
        Positioned.fill(
          child: PeerStatusPillOverlay(
            child: IndexedStack(
              index: active.index,
              children: const [
                ChatsPage(),
                DropPage(),
                GamesPage(),
                ServersHomePage(),
                SettingsPage(),
              ],
            ),
          ),
        ),
        const Positioned.fill(child: CallOverlayMount()),
      ],
    );

    void go(AppTab tab) {
      hapticTap();
      ref.read(activeTabProvider.notifier).state = tab;
    }

    if (_isDesktopHost(context)) {
      // On Windows the OS paints Mica behind the window (see main.dart); keep
      // the margin transparent so it shows through. Elsewhere fill with bg.
      final onWindows =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
      return Scaffold(
        backgroundColor: onWindows ? Colors.transparent : null,
        body: ColoredBox(
          color: onWindows ? Colors.transparent : tokens.bg,
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: _desktopShellMaxWidth),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      SizedBox(
                        width: _desktopSidebarWidth,
                        child: _GlassSidebar(active: active, onTap: go),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: OrbitsGlassSurface(
                          role: OrbitsGlassRole.card,
                          borderRadius:
                              BorderRadius.circular(tokens.radiusModal),
                          child: shellBody,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: shellBody,
      bottomNavigationBar: _GlassBottomNav(active: active, onTap: go),
    );
  }

  bool _isDesktopHost(BuildContext context) {
    // Desktop shell (glass sidebar + centered content, no bottom nav) is keyed
    // to viewport WIDTH, not platform — a wide Web window must behave as a
    // desktop. Narrow (<900) always gets the mobile bottom-nav shell.
    final width = MediaQuery.sizeOf(context).width;
    if (width < 900) return false;
    if (kIsWeb) return true;
    return switch (defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux =>
        true,
      _ => false,
    };
  }
}

// ─────────────────────────────────────────────────────────────
// Mobile — floating glass bottom nav
// ─────────────────────────────────────────────────────────────

class _GlassBottomNav extends StatelessWidget {
  const _GlassBottomNav({required this.active, required this.onTap});

  final AppTab active;
  final ValueChanged<AppTab> onTap;

  @override
  Widget build(BuildContext context) {
    // Full-width monolithic glass "shelf" — no side gaps. Scroll content
    // disappears cleanly behind it instead of peeking through the old
    // horizontal:14 margins. Only the top edge is rounded; the bar runs
    // flush to the screen's left/right/bottom. SafeArea lives *inside* the
    // glass so the surface fills down into the home-indicator inset.
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: OrbitsGlassSurface(
        role: OrbitsGlassRole.navBar,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        padding: EdgeInsets.zero,
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: Row(
            children: [
              for (final d in _destinations)
                Expanded(
                  child: _NavItem(
                    dest: d,
                    active: active == d.tab,
                    onTap: () => onTap(d.tab),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.dest,
    required this.active,
    required this.onTap,
  });

  final _NavDest dest;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    final fg = active ? t.accent : t.muted;
    final icon = dest.iconFor(
        active ? PhosphorIconsStyle.fill : PhosphorIconsStyle.light);

    return Semantics(
      button: true,
      selected: active,
      label: dest.label,
      child: InkResponse(
        onTap: onTap,
        radius: 44,
        child: AnimatedContainer(
          duration: t.durationShort,
          curve: t.curveStandard,
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Active items get a faint accent halo behind the glyph.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  color: active ? t.accentAlpha(0.14) : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Icon(icon, size: 22, color: fg),
              ),
              const SizedBox(height: 3),
              Text(
                dest.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg,
                  fontFamily: t.fontBody,
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Desktop — glass sidebar
// ─────────────────────────────────────────────────────────────

class _GlassSidebar extends StatelessWidget {
  const _GlassSidebar({required this.active, required this.onTap});

  final AppTab active;
  final ValueChanged<AppTab> onTap;

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.sidebar,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
      child: Column(
        children: [
          // Brand mark — neutral glass tile with a single accent glyph.
          OrbitsGlassSurface(
            role: OrbitsGlassRole.card,
            borderRadius: BorderRadius.circular(16),
            padding: const EdgeInsets.all(11),
            child: Icon(PhosphorIcons.planet(PhosphorIconsStyle.fill),
                color: t.accent, size: 24),
          ),
          const SizedBox(height: 20),
          for (final d in _destinations.where((d) => d.tab != AppTab.settings))
            _SidebarItem(dest: d, active: active == d.tab, onTap: onTap),
          const Spacer(),
          _SidebarItem(
            dest: _destinations.firstWhere((d) => d.tab == AppTab.settings),
            active: active == AppTab.settings,
            onTap: onTap,
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.dest,
    required this.active,
    required this.onTap,
  });

  final _NavDest dest;
  final bool active;
  final ValueChanged<AppTab> onTap;

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    final fg = active ? t.accent : t.muted;
    final icon = dest.iconFor(
        active ? PhosphorIconsStyle.fill : PhosphorIconsStyle.light);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Semantics(
        button: true,
        selected: active,
        label: dest.label,
        child: Tooltip(
          message: dest.label,
          child: InkWell(
            onTap: () => onTap(dest.tab),
            borderRadius: BorderRadius.circular(t.radiusButton),
            child: AnimatedContainer(
              duration: t.durationShort,
              curve: t.curveStandard,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                color: active ? t.accentAlpha(0.14) : Colors.transparent,
                border: Border.all(
                  color: active ? t.accentAlpha(0.30) : Colors.transparent,
                ),
                borderRadius: BorderRadius.circular(t.radiusButton),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: fg, size: 23),
                  const SizedBox(height: 5),
                  Text(
                    dest.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontFamily: t.fontBody,
                      fontSize: 11,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// App shell — React workspace: scenery, wordmark, liquid theme switcher,
// nav rail / floating pill, and the real tab stack (chats / drop / games /
// rooms / settings / profile).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/haptics.dart';
import 'pages/chats_page.dart';
import 'pages/drop_page.dart';
import 'pages/games_page.dart';
import 'pages/profile_page.dart';
import 'pages/servers_page.dart';
import 'pages/settings_page.dart';
import 'state/calls_provider.dart';
import 'state/chat_list_provider.dart';
import 'state/drop_provider.dart';
import 'state/local_profile_provider.dart';
import 'state/messaging_notifier.dart';
import 'state/shell_providers.dart';
import 'themes/orbits_tokens.dart';
import 'transport/native_transport.dart';
import 'transport/transport_lifecycle_scope.dart';
import 'ui/backdrop/orbits_backdrop.dart';
import 'ui/calls/call_overlay_mount.dart';
import 'ui/layout/orbits_breakpoints.dart';
import 'ui/peer/peer_status_pill.dart';
import 'ui/primitives/liquid_theme_switcher.dart';
import 'ui/primitives/orbits_glass_button.dart';
import 'ui/primitives/orbits_glass_surface.dart';
import 'ui/primitives/orbits_logo.dart';
import 'ui/primitives/orbs_card.dart';
import 'ui/shell/orbits_side_drawer.dart';

export 'state/shell_providers.dart';

class _NavDest {
  const _NavDest(this.tab, this.icon, this.activeIcon, this.label);
  final AppTab tab;
  final IconData icon;
  final IconData activeIcon;
  final String label;
}

const List<_NavDest> _primaryDestinations = [
  _NavDest(AppTab.chats, Icons.chat_bubble_outline, Icons.chat_bubble, 'Чаты'),
  _NavDest(AppTab.drop, Icons.swap_vert, Icons.swap_vertical_circle, 'Drop'),
  _NavDest(
    AppTab.games,
    Icons.sports_esports_outlined,
    Icons.sports_esports,
    'Игры',
  ),
  _NavDest(AppTab.rooms, Icons.dns_outlined, Icons.dns, 'Серверы'),
];

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeTabProvider);
    final tokens = OrbitsTokens.of(context);
    final phone = isPhoneLayout(context);
    final chatOpen = ref.watch(mobileChatOpenProvider);
    final unread = ref
        .watch(chatListProvider)
        .fold<int>(0, (n, c) => n + c.unreadCount);

    ref.listen(messagingNotifierProvider, (_, __) {});
    ref.listen(callsNotifierProvider, (_, __) {});
    ref.listen(dropNotifierProvider, (_, __) {});
    ref.listen(nativeTransportHostProvider, (_, __) {});

    final dropScenery = active == AppTab.drop;
    ref.listen<AppTab>(activeTabProvider, (_, next) {
      ref.read(orbitsDropSceneryProvider.notifier).state = next == AppTab.drop;
    });
    if (ref.read(orbitsDropSceneryProvider) != dropScenery) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ref.read(orbitsDropSceneryProvider) != dropScenery) {
          ref.read(orbitsDropSceneryProvider.notifier).state = dropScenery;
        }
      });
    }

    const pages = [
      ChatsPage(),
      DropPage(),
      GamesPage(),
      ServersHomePage(),
      SettingsPage(),
      ProfilePage(),
    ];

    final shellBody = Stack(
      children: [
        Positioned.fill(
          child: PeerStatusPillOverlay(
            child: IndexedStack(index: active.index, children: pages),
          ),
        ),
        const Positioned.fill(child: CallOverlayMount()),
      ],
    );

    void go(AppTab tab) {
      hapticTap();
      ref.read(activeTabProvider.notifier).state = tab;
    }

    final hideChrome = phone && chatOpen;

    return TransportLifecycleScope(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        drawer: const OrbitsSideDrawer(),
        body: SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: OrbitsBreakpoints.workspaceMax,
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  phone ? 12 : 24,
                  phone ? 6 : 8,
                  phone ? 12 : 24,
                  0,
                ),
                child: Column(
                  children: [
                    if (!hideChrome)
                      Builder(
                        builder: (headerContext) => _WorkspaceHeader(
                          onLogoTap: () => go(AppTab.chats),
                          onMenuTap: () =>
                              Scaffold.of(headerContext).openDrawer(),
                        ),
                      ),
                    if (!hideChrome) SizedBox(height: phone ? 8 : 10),
                    Expanded(
                      child: phone
                          ? Stack(
                              children: [
                                Positioned.fill(
                                  child: OrbitsGlassSurface(
                                    role: OrbitsGlassRole.card,
                                    realBlur: true,
                                    borderRadius: BorderRadius.circular(
                                      tokens.radiusModal,
                                    ),
                                    child: shellBody,
                                  ),
                                ),
                                if (!hideChrome)
                                  Align(
                                    alignment: Alignment.bottomCenter,
                                    child: _GlassBottomNav(
                                      active: active,
                                      unread: unread,
                                      onTap: go,
                                    ),
                                  ),
                              ],
                            )
                          : Row(
                              children: [
                                SizedBox(
                                  width: 80,
                                  child: _GlassSidebar(
                                    active: active,
                                    unread: unread,
                                    onTap: go,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: OrbitsGlassSurface(
                                    role: OrbitsGlassRole.card,
                                    realBlur: true,
                                    borderRadius: BorderRadius.circular(
                                      tokens.radiusModal,
                                    ),
                                    child: shellBody,
                                  ),
                                ),
                              ],
                            ),
                    ),
                    if (!phone)
                      SizedBox(
                        height: 36,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Локальный сеанс · данные остаются на устройстве',
                            style: TextStyle(
                              color: tokens.muted.withValues(alpha: 0.8),
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                    if (phone && !hideChrome) const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({required this.onLogoTap, required this.onMenuTap});
  final VoidCallback onLogoTap;
  final VoidCallback onMenuTap;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          OrbitsGlassIconButton(
            icon: Icons.menu,
            tooltip: 'Меню',
            variant: OrbitsGlassVariant.subtle,
            size: OrbitsGlassSize.small,
            onPressed: onMenuTap,
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: onLogoTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                children: [
                  OrbitsLogo(size: 26, color: tokens.text),
                  const SizedBox(width: 8),
                  Text(
                    'Orbits',
                    style: TextStyle(
                      fontFamily: tokens.fontHeading,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.6,
                      color: tokens.text,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          const LiquidThemeSwitcher(),
        ],
      ),
    );
  }
}

class _GlassBottomNav extends StatelessWidget {
  const _GlassBottomNav({
    required this.active,
    required this.unread,
    required this.onTap,
  });

  final AppTab active;
  final int unread;
  final ValueChanged<AppTab> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: OrbitsGlassSurface(
        role: OrbitsGlassRole.navBar,
        realBlur: true,
        refract: true,
        refractionStrength: 0.16,
        borderRadius: BorderRadius.circular(999),
        padding: const EdgeInsets.all(4),
        child: SafeArea(
          top: false,
          minimum: EdgeInsets.zero,
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                for (final d in _primaryDestinations)
                  Expanded(
                    child: _NavItem(
                      dest: d,
                      active: active == d.tab,
                      unread: d.tab == AppTab.chats ? unread : 0,
                      horizontal: true,
                      onTap: () => onTap(d.tab),
                    ),
                  ),
                _RailAvatar(active: active, onTap: onTap),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassSidebar extends StatelessWidget {
  const _GlassSidebar({
    required this.active,
    required this.unread,
    required this.onTap,
  });

  final AppTab active;
  final int unread;
  final ValueChanged<AppTab> onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.sidebar,
      realBlur: true,
      refract: true,
      padding: const EdgeInsets.fromLTRB(9, 18, 9, 14),
      child: Column(
        children: [
          InkWell(
            onTap: () => onTap(AppTab.chats),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: OrbitsLogo(size: 28, color: tokens.text),
            ),
          ),
          const SizedBox(height: 22),
          for (final d in _primaryDestinations)
            _NavItem(
              dest: d,
              active: active == d.tab,
              unread: d.tab == AppTab.chats ? unread : 0,
              horizontal: false,
              onTap: () => onTap(d.tab),
            ),
          const Spacer(),
          _NavItem(
            dest: const _NavDest(
              AppTab.settings,
              Icons.settings_outlined,
              Icons.settings,
              'Ещё',
            ),
            active: active == AppTab.settings,
            unread: 0,
            horizontal: false,
            onTap: () => onTap(AppTab.settings),
          ),
          const SizedBox(height: 12),
          _RailAvatar(active: active, onTap: onTap),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.dest,
    required this.active,
    required this.unread,
    required this.horizontal,
    required this.onTap,
  });

  final _NavDest dest;
  final bool active;
  final int unread;
  final bool horizontal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    final fg = active ? t.text : t.muted;
    final icon = active ? dest.activeIcon : dest.icon;
    return Semantics(
      key: Key('nav-${dest.tab.name}'),
      button: true,
      selected: active,
      label: dest.label,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: horizontal ? 0 : 5),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(horizontal ? 999 : 17),
          child: AnimatedContainer(
            duration: t.durationShort,
            curve: t.curveStandard,
            padding: EdgeInsets.symmetric(
              vertical: horizontal ? 8 : 9,
              horizontal: horizontal ? 6 : 2,
            ),
            decoration: BoxDecoration(
              color: active
                  ? t.glassTint.withValues(alpha: 0.55)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(horizontal ? 999 : 17),
              border: Border.all(
                color: active ? t.glassBorder : Colors.transparent,
              ),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Flex(
                  direction: horizontal ? Axis.horizontal : Axis.vertical,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: horizontal ? 19 : 20, color: fg),
                    SizedBox(
                      width: horizontal ? 6 : 0,
                      height: horizontal ? 0 : 5,
                    ),
                    Text(
                      dest.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontFamily: t.fontBody,
                        fontSize: horizontal ? 12 : 8,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                        height: 1,
                      ),
                    ),
                  ],
                ),
                if (unread > 0)
                  Positioned(
                    top: horizontal ? 4 : -2,
                    right: horizontal ? 8 : 10,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: t.deliveryRead,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RailAvatar extends ConsumerWidget {
  const _RailAvatar({required this.active, required this.onTap});
  final AppTab active;
  final ValueChanged<AppTab> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(localProfileProvider);
    final selected = active == AppTab.profile;
    final name = user?.displayName ?? '';
    final initial = name.trim().isNotEmpty
        ? name.trim().characters.first.toUpperCase()
        : '•';
    return Semantics(
      key: const Key('nav-profile'),
      button: true,
      selected: selected,
      label: 'Мой профиль',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: InkWell(
          onTap: () => onTap(AppTab.profile),
          customBorder: const CircleBorder(),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? OrbitsTokens.of(context).accent
                    : Colors.white.withValues(alpha: 0.45),
                width: selected ? 2 : 1.5,
              ),
            ),
            child: OrbsAvatar(fallbackInitial: initial, size: 34),
          ),
        ),
      ),
    );
  }
}

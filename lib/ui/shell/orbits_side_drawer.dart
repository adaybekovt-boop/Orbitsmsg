import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pages/saved_unavailable_page.dart';
import '../../state/local_profile_provider.dart';
import '../../state/shell_providers.dart';
import '../../themes/orbits_tokens.dart';
import '../primitives/liquid_theme_switcher.dart';
import '../primitives/orbits_glass_button.dart';
import '../primitives/orbits_glass_surface.dart';
import '../primitives/orbs_card.dart';

/// React side drawer: real tabs plus an honest "saved" unavailable route.
class OrbitsSideDrawer extends ConsumerWidget {
  const OrbitsSideDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = OrbitsTokens.of(context);
    final user = ref.watch(localProfileProvider);
    final tab = ref.watch(activeTabProvider);
    final name = (user?.displayName.trim().isNotEmpty ?? false)
        ? user!.displayName.trim()
        : 'Локальный профиль';
    final initial = name.characters.first.toUpperCase();

    void go(AppTab next) {
      ref.read(activeTabProvider.notifier).state = next;
      Navigator.of(context).maybePop();
    }

    return Drawer(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
          child: OrbitsGlassSurface(
            role: OrbitsGlassRole.sheet,
            realBlur: true,
            refract: true,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    OrbsAvatar(fallbackInitial: initial, size: 40),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: tokens.fontHeading,
                              fontWeight: FontWeight.w600,
                              color: tokens.text,
                            ),
                          ),
                          Text(
                            user?.peerId ?? 'Нет сессии',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: tokens.fontMono,
                              fontSize: 10,
                              color: tokens.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    OrbitsGlassIconButton(
                      icon: Icons.close,
                      tooltip: 'Закрыть меню',
                      size: OrbitsGlassSize.small,
                      variant: OrbitsGlassVariant.subtle,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _Item(
                  icon: Icons.chat_bubble_outline,
                  label: 'Все чаты',
                  selected: tab == AppTab.chats,
                  onTap: () => go(AppTab.chats),
                ),
                _Item(
                  icon: Icons.star_outline,
                  label: 'Избранное',
                  selected: false,
                  onTap: () {
                    final root = Navigator.of(context, rootNavigator: true);
                    Navigator.of(context).pop();
                    root.push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SavedUnavailablePage(),
                      ),
                    );
                  },
                ),
                _Item(
                  icon: Icons.swap_vert,
                  label: 'Orbits Drop',
                  selected: tab == AppTab.drop,
                  onTap: () => go(AppTab.drop),
                ),
                _Item(
                  icon: Icons.sports_esports_outlined,
                  label: 'Мини-игры',
                  selected: tab == AppTab.games,
                  onTap: () => go(AppTab.games),
                ),
                _Item(
                  icon: Icons.dns_outlined,
                  label: 'Серверы',
                  selected: tab == AppTab.rooms,
                  onTap: () => go(AppTab.rooms),
                ),
                _Item(
                  icon: Icons.settings_outlined,
                  label: 'Настройки',
                  selected: tab == AppTab.settings,
                  onTap: () => go(AppTab.settings),
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        Theme.of(context).brightness == Brightness.dark
                            ? 'Тёмная тема'
                            : 'Светлая тема',
                        style: TextStyle(color: tokens.muted, fontSize: 12),
                      ),
                    ),
                    const LiquidThemeSwitcher(compact: true),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.shield_outlined, size: 14, color: tokens.muted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Локальный сеанс. История остаётся на устройстве.',
                        style: TextStyle(
                          color: tokens.muted,
                          fontSize: 10,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? tokens.glassTint.withValues(alpha: 0.85)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected ? tokens.text : tokens.muted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: tokens.fontBody,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? tokens.text : tokens.muted,
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

// Settings home — list of "action card" rows. Each row pushes its own
// dedicated subpage. Mirrors the JS `screen === 'home'` branch in
// `src/pages/Settings.jsx`:
//   • Профиль (stretchy header at the top, tap → editor)
//   • Безопасность
//   • Чаты
//   • Уведомления
//   • Внешний вид
//   • Микрофон
//   • Энергосбережение
//   • Сеть
//   • Диагностика
//
// Plus a logout button at the bottom (red).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/auth_notifier.dart';
import '../state/local_profile_provider.dart';
import '../themes/orbits_tokens.dart';
import '../ui/peer/peer_status_pill.dart';
import '../ui/primitives/adaptive_page_frame.dart';
import '../ui/primitives/orbits_glass_button.dart';
import '../ui/primitives/orbits_glass_dialog.dart';
import '../ui/primitives/orbits_glass_list_tile.dart';
import '../ui/primitives/orbits_glass_app_bar.dart';
import '../ui/primitives/orbits_glass_surface.dart';
import '../ui/primitives/orbs_card.dart';
import '../ui/profile/my_qr_page.dart';
import '../ui/profile/profile_edit_page.dart';
import 'settings/advanced_page.dart';
import 'settings/chat_prefs_page.dart';
import 'settings/notifications_page.dart';
import 'settings/security_page.dart';
import 'themes_page.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = OrbitsTokens.of(context);
    final user = ref.watch(localProfileProvider);

    return Scaffold(
      appBar: OrbitsGlassAppBar(
        title: Text(
          'Настройки',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
      ),
      body: AdaptivePageFrame(
        maxWidth: 760,
        child: ListView(
          padding: const EdgeInsets.only(
            top: kPillReserveHeight + 4,
            bottom: 32,
          ),
          children: [
          // ── Аккаунт ──
          if (user != null) ...[
            _SectionLabel(text: 'Аккаунт', tokens: tokens),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: _ProfileCard(user: user, tokens: tokens),
            ),
          ],

          // ── Основное ── (technical screens live deeper under "Дополнительно")
          _SectionLabel(text: 'Основное', tokens: tokens),
          _ActionRow(
            icon: Icons.palette,
            title: 'Внешний вид',
            subtitle: 'Тема оформления',
            onTap: () => _push(context, const ThemesPage()),
          ),
          _ActionRow(
            icon: Icons.chat_bubble,
            title: 'Чаты',
            subtitle: 'Поведение, форма сообщений, шрифт',
            onTap: () => _push(context, const ChatPrefsPage()),
          ),
          _ActionRow(
            icon: Icons.notifications,
            title: 'Уведомления',
            subtitle: 'Звуки и вибрация',
            onTap: () => _push(context, const NotificationsPage()),
          ),
          _ActionRow(
            icon: Icons.lock,
            title: 'Безопасность',
            subtitle: 'Блокировка, пароль, проверка контактов',
            onTap: () => _push(context, const SecurityPage()),
          ),
          const SizedBox(height: 8),
          _ActionRow(
            icon: Icons.tune,
            title: 'Дополнительно',
            subtitle: 'Соединение, микрофон, диагностика',
            onTap: () => _push(context, const AdvancedPage()),
          ),

          // Logout
          if (user != null) ...[
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Center(
                child: OrbitsGlassButton(
                  label: 'Выйти из профиля',
                  icon: Icons.logout,
                  onPressed: () => _confirmLogout(context, ref),
                  // Neutral in the settings list — the alarming red lives only
                  // inside the confirm dialog (showOrbitsConfirm danger: true).
                  variant: OrbitsGlassVariant.subtle,
                  size: OrbitsGlassSize.medium,
                ),
              ),
            ),
          ],
          ],
        ),
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final ok = await showOrbitsConfirm(
      context: context,
      title: 'Выйти из профиля?',
      message: 'Локальные ключи останутся на устройстве. Войти можно будет '
          'паролем — пароль не сбрасывается.',
      confirmLabel: 'Выйти',
      confirmIcon: Icons.logout,
      danger: true,
    );
    if (!ok) return;
    await ref.read(authNotifierProvider.notifier).logout();
  }
}

// ─── Section label ─────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text, required this.tokens});
  final String text;
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 6),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: tokens.muted,
          ),
        ),
      );
}

// ─── Profile card ──────────────────────────────────────────

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.user, required this.tokens});

  final AuthedUser user;
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    final avatarBytes = _decodeAvatar(user.avatarDataUrl);
    final radius = BorderRadius.circular(tokens.radiusCard);
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.card,
      borderRadius: radius,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ProfileEditPage()),
            );
          },
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
        children: [
          OrbsAvatar(
            fallbackInitial: user.displayName.isNotEmpty
                ? user.displayName.characters.first.toUpperCase()
                : '?',
            imageBytes: avatarBytes,
            size: 56,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  user.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    fontFamily: tokens.fontHeading,
                    color: tokens.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Код профиля: ${user.peerId}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: tokens.fontMono,
                    color: tokens.muted,
                  ),
                ),
                if (user.bio.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    user.bio,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: tokens.fontBody,
                      color: tokens.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          OrbitsGlassIconButton(
            icon: Icons.qr_code_2,
            tooltip: 'QR-код',
            variant: OrbitsGlassVariant.subtle,
            size: OrbitsGlassSize.small,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => MyQrPage(peerId: user.peerId),
                ),
              );
            },
          ),
          Icon(Icons.chevron_right, color: tokens.muted),
                ],
              ),
            ),
          ),
        ),
      );
  }

  Uint8List? _decodeAvatar(String? url) {
    if (url == null || url.isEmpty) return null;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(url.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }
}

// ─── Action row ────────────────────────────────────────────

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: OrbitsGlassListTile(
        onTap: onTap,
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: tokens.accentAlpha(0.16),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: tokens.accentAlpha(0.22)),
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: tokens.text, size: 18),
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: Icon(Icons.chevron_right, color: tokens.muted),
      ),
    );
  }
}

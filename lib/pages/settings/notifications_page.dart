// Settings → Уведомления.
//
// HONEST STATE (settings audit): background/native notifications are NOT
// implemented yet — there is no `flutter_local_notifications` plugin, and the
// in-app sound module (`core/sounds.dart`) is a no-op stub (no `audioplayers`).
// The previous version showed four toggles that wrote `orbits_notif_prefs_v1`,
// a key NOTHING reads (the core reads `orbits_notif_settings_v1`), so flipping
// them did nothing. Rather than ship fake switches, this screen now clearly
// states the feature is in development. The real toggles return when the
// notification + sound backends are wired (tracked for a later update).

import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_list_tile.dart';
import '../../ui/primitives/orbits_glass_surface.dart';

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const OrbitsGlassSurface(
          role: OrbitsGlassRole.appBar,
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
          child: SizedBox.expand(),
        ),
        title: Text(
          'Уведомления',
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
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            const _SectionLabel('В разработке'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: OrbitsGlassSurface(
                role: OrbitsGlassRole.card,
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: tokens.accentAlpha(0.16),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Icon(Icons.notifications_off_outlined,
                              color: tokens.text, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Уведомления пока не работают',
                            style: TextStyle(
                              fontFamily: tokens.fontHeading,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                              color: tokens.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Системные уведомления и звуки сообщений появятся в '
                      'обновлении. Сейчас приложение не показывает push-'
                      'уведомления и не проигрывает звуки — поэтому мы не '
                      'показываем переключатели, которые ни на что не влияют.',
                      style: TextStyle(
                        fontFamily: tokens.fontBody,
                        fontSize: 13,
                        height: 1.45,
                        color: tokens.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Disabled previews of what is coming — clearly non-interactive.
            const _ComingSoonRow(
              icon: Icons.notifications_active_outlined,
              label: 'Системные уведомления',
              subtitle: 'Сообщения и звонки, когда приложение свёрнуто',
            ),
            const _ComingSoonRow(
              icon: Icons.volume_up_outlined,
              label: 'Звук сообщений',
              subtitle: 'Тихий сигнал при получении',
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _ComingSoonRow extends StatelessWidget {
  const _ComingSoonRow({
    required this.icon,
    required this.label,
    required this.subtitle,
  });

  final IconData icon;
  final String label;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Opacity(
      opacity: 0.6,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: OrbitsGlassListTile(
          leading: Icon(icon, color: tokens.muted, size: 20),
          title: Text(label),
          subtitle: Text(subtitle),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: tokens.muted.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'СКОРО',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                fontFamily: tokens.fontMono,
                color: tokens.muted,
                letterSpacing: 1.0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

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

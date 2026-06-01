// "Дополнительно" — the advanced/technical settings bucket. Keeps the main
// Settings list short and human; everything a normal user doesn't need to see
// lives one level deeper here (connection state, microphone, power saver,
// diagnostics, the agreement). Nothing is removed — only moved deeper.

import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_list_tile.dart';
import '../../ui/primitives/orbits_glass_surface.dart';
import 'diagnostics_page.dart';
import 'mic_page.dart';
import 'network_page.dart';
import 'power_saver_page.dart';
import 'terms_page.dart';

class AdvancedPage extends StatelessWidget {
  const AdvancedPage({super.key});

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
          'Дополнительно',
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
          padding: const EdgeInsets.only(top: 12, bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: Text(
                'Технические настройки и информация о работе приложения. '
                'Обычно сюда заходить не нужно.',
                style: TextStyle(
                  fontFamily: tokens.fontBody,
                  fontSize: 13,
                  height: 1.4,
                  color: tokens.muted,
                ),
              ),
            ),
            const _AdvancedRow(
              icon: Icons.wifi_tethering,
              title: 'Соединение',
              subtitle: 'Состояние сети и мой код',
              page: NetworkPage(),
            ),
            const _AdvancedRow(
              icon: Icons.mic,
              title: 'Микрофон',
              subtitle: 'Устройство и эффекты',
              page: MicPage(),
            ),
            const _AdvancedRow(
              icon: Icons.bolt,
              title: 'Экономия батареи',
              subtitle: 'Меньше анимаций и нагрузки',
              page: PowerSaverPage(),
            ),
            const _AdvancedRow(
              icon: Icons.insights,
              title: 'Диагностика',
              subtitle: 'Версия, кэш, состояние приложения',
              page: DiagnosticsPage(),
            ),
            const _AdvancedRow(
              icon: Icons.gavel,
              title: 'Соглашение',
              subtitle: 'Политика конфиденциальности и условия',
              page: TermsPage(),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdvancedRow extends StatelessWidget {
  const _AdvancedRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.page,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: OrbitsGlassListTile(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => page),
        ),
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

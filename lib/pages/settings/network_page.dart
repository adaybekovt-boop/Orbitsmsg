// Settings → Сеть.
//
// Port of the `screen === 'network'` branch in JS Settings: shows the
// user's peer ID with a copy button, the current connection status,
// and the signaling host. The peer-status pill at the top of the app
// shell already surfaces the same status — this is the place to inspect
// it in detail.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/haptics.dart';
import '../../state/connections_notifier.dart';
import '../../state/local_profile_provider.dart';
import '../../state/peer_connection_provider.dart';
import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/orbits_glass_button.dart';
import '../../ui/primitives/orbits_glass_list_tile.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_surface.dart';
import '../../ui/primitives/orbs_card.dart';
import '../../ui/profile/my_qr_page.dart';

class NetworkPage extends ConsumerWidget {
  const NetworkPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = OrbitsTokens.of(context);
    final user = ref.watch(localProfileProvider);
    final conn = ref.watch(peerConnectionProvider);
    final turnConfigured = ref.watch(turnConfiguredProvider);
    final turnUrlCount = ref.watch(turnUrlCountProvider);
    final relayOnly = ref.watch(relayOnlyProvider);
    final relayOnlyBroken = ref.watch(relayOnlyMisconfiguredProvider);
    final lastConnErr =
        ref.watch(connectionsNotifierProvider.select((s) => s.lastConnectError));
    final candidateTypes = ref.watch(
        connectionsNotifierProvider.select((s) => s.candidateTypeByPeer));

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
          'Соединение',
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
          // ── Peer ID ──────────────────────────────────────────
          const OrbsSectionTitle('Мой код'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: OrbitsGlassSurface(
              role: OrbitsGlassRole.card,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OrbitsGlassSurface(
                    role: OrbitsGlassRole.input,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            user?.peerId ?? '—',
                            style: TextStyle(
                              fontFamily: tokens.fontMono,
                              fontSize: 14,
                              color: tokens.text,
                            ),
                          ),
                        ),
                        if (user != null) ...[
                          OrbitsGlassIconButton(
                            icon: Icons.qr_code_2,
                            tooltip: 'QR-код',
                            variant: OrbitsGlassVariant.subtle,
                            size: OrbitsGlassSize.small,
                            onPressed: () {
                              hapticTap();
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      MyQrPage(peerId: user.peerId),
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 4),
                          OrbitsGlassIconButton(
                            icon: Icons.copy_outlined,
                            tooltip: 'Скопировать',
                            variant: OrbitsGlassVariant.subtle,
                            size: OrbitsGlassSize.small,
                            onPressed: () async {
                              hapticTap();
                              await Clipboard.setData(
                                ClipboardData(text: user.peerId),
                              );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context)
                                ..clearSnackBars()
                                ..showSnackBar(
                                  const SnackBar(
                                    content: Text('Код скопирован'),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Код присвоен навсегда и не может быть сброшен. Поделись им '
                    'с друзьями — они смогут добавить тебя в контакты.',
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.muted,
                      fontFamily: tokens.fontBody,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Status ───────────────────────────────────────────
          const OrbsSectionTitle('Статус'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: OrbitsGlassListTile(
              title: const Text('Соединение'),
              subtitle: Text(_statusLabel(conn.status)),
              trailing: _StatusDot(status: conn.status, tokens: tokens),
            ),
          ),
          if (conn.error != null && conn.error!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: OrbitsGlassListTile(
                title: const Text('Последняя ошибка'),
                subtitle: Text(conn.error ?? ''),
              ),
            ),

          // ── Cross-network reachability (TURN) ────────────────
          const OrbsSectionTitle('Связь между сетями'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: OrbitsGlassListTile(
              title: const Text('TURN-ретранслятор'),
              subtitle: Text(turnConfigured
                  ? (relayOnly
                      ? 'Настроен ($turnUrlCount адр.) — только через ретранслятор'
                      : 'Настроен ($turnUrlCount адр.) — работает и между сетями')
                  : 'Не настроен. Между разными сетями (моб. интернет ↔ домашний '
                      'роутер) связь может не установиться — для надёжности '
                      'нужен TURN-сервер.'),
              trailing: Icon(
                turnConfigured ? Icons.check_circle : Icons.info_outline,
                color: turnConfigured ? tokens.success : tokens.muted,
              ),
            ),
          ),
          // Misconfiguration: RELAY_ONLY without usable TURN. We fell back to a
          // normal ICE policy (still connects directly) and warn rather than
          // silently producing a config that can't connect at all.
          if (relayOnlyBroken)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: OrbitsGlassListTile(
                title: const Text('Только ретранслятор без TURN'),
                subtitle: const Text(
                    'RELAY_ONLY включён, но TURN не задан — режим проигнорирован, '
                    'иначе соединение было бы невозможно. Задайте TURN-сервер.'),
                trailing: Icon(Icons.warning_amber_rounded, color: tokens.danger),
              ),
            ),
          // Per-peer ICE path: direct (host/srflx) vs via TURN (relay).
          if (candidateTypes.isNotEmpty)
            for (final entry in candidateTypes.entries)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: OrbitsGlassListTile(
                  title: Text('Путь: ${entry.key}'),
                  subtitle: Text(entry.value == 'relay'
                      ? 'через ретранслятор (relay)'
                      : 'напрямую (${entry.value})'),
                  trailing: Icon(
                    entry.value == 'relay'
                        ? Icons.alt_route_rounded
                        : Icons.swap_horiz_rounded,
                    color: entry.value == 'relay' ? tokens.accent2 : tokens.success,
                  ),
                ),
              ),
          if (lastConnErr != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: OrbitsGlassListTile(
                title: const Text('Последняя ошибка соединения'),
                subtitle: Text('${lastConnErr.peerId}: ${lastConnErr.message}'),
              ),
            ),

          // ── How it works ─────────────────────────────────────
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 16, color: tokens.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Сообщения передаются напрямую к собеседнику без сервера. '
                    'Если он офлайн, сообщения дойдут когда он появится в '
                    'сети.',
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.muted,
                      fontFamily: tokens.fontBody,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
      ),
    );
  }

  String _statusLabel(String? status) {
    return switch (status) {
      'connected' => 'В сети',
      'connecting' => 'Подключение…',
      'multitab' => 'Открыто в другой вкладке',
      'disconnected' => 'Нет соединения',
      _ => 'Нет соединения',
    };
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status, required this.tokens});
  final String? status;
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'connected' => tokens.success,
      'connecting' => tokens.accent2,
      'multitab' => tokens.danger,
      _ => tokens.muted,
    };
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6),
        ],
      ),
    );
  }
}

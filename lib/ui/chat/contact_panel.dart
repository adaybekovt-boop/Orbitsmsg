import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/calls_provider.dart';
import '../../state/connections_notifier.dart';
import '../../state/peers_provider.dart';
import '../../themes/orbits_tokens.dart';
import '../primitives/orbits_glass_button.dart';
import '../primitives/orbits_glass_surface.dart';
import '../primitives/orbs_card.dart';
import 'chat_settings_sheet.dart';

/// Wide-layout contact column. Actions call the real call / settings paths.
class ChatContactPanel extends ConsumerWidget {
  const ChatContactPanel({super.key, required this.peerId, this.onClose});

  final String peerId;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = OrbitsTokens.of(context);
    final online = ref.watch(connectedPeerIdsProvider).contains(peerId);
    final peers = ref.watch(peersProvider).asData?.value ?? const [];
    String name = peerId;
    String bio = '';
    bool blocked = false;
    for (final r in peers) {
      if ((r['id'] as String?) != peerId) continue;
      final custom = (r['customName'] as String?) ?? '';
      final remote = (r['displayName'] as String?) ?? '';
      if (custom.trim().isNotEmpty) {
        name = custom.trim();
      } else if (remote.trim().isNotEmpty) {
        name = remote;
      }
      bio = (r['bio'] as String?) ?? '';
      final blockedRaw = r['blocked'];
      blocked =
          blockedRaw == true || (blockedRaw is num && blockedRaw.toInt() == 1);
      break;
    }
    final initial = name.trim().isNotEmpty
        ? name.trim().characters.first.toUpperCase()
        : '?';
    final callActive = ref.watch(callIsActiveProvider);

    return OrbitsGlassSurface(
      role: OrbitsGlassRole.sidebar,
      realBlur: true,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'КОНТАКТ',
                style: TextStyle(
                  fontSize: 8,
                  letterSpacing: 1.4,
                  color: tokens.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (onClose != null)
                OrbitsGlassIconButton(
                  icon: Icons.close,
                  tooltip: 'Скрыть панель',
                  size: OrbitsGlassSize.small,
                  variant: OrbitsGlassVariant.subtle,
                  onPressed: onClose,
                ),
            ],
          ),
          const SizedBox(height: 18),
          OrbsAvatar(fallbackInitial: initial, online: online, size: 72),
          const SizedBox(height: 14),
          Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: tokens.fontHeading,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: tokens.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            online ? 'в сети' : 'не в сети',
            style: TextStyle(
              color: online ? tokens.success : tokens.muted,
              fontSize: 11,
            ),
          ),
          if (bio.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              bio,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tokens.muted, fontSize: 11, height: 1.5),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OrbitsGlassIconButton(
                icon: Icons.call,
                tooltip: 'Аудио-звонок',
                onPressed: (blocked || callActive)
                    ? null
                    : () => ref
                          .read(callsNotifierProvider.notifier)
                          .startCall(peerId, video: false),
              ),
              const SizedBox(width: 8),
              OrbitsGlassIconButton(
                icon: Icons.videocam,
                tooltip: 'Видео-звонок',
                onPressed: (blocked || callActive)
                    ? null
                    : () => ref
                          .read(callsNotifierProvider.notifier)
                          .startCall(peerId, video: true),
              ),
              const SizedBox(width: 8),
              OrbitsGlassIconButton(
                icon: Icons.info_outline,
                tooltip: 'Настройки чата',
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    showDragHandle: true,
                    builder: (_) => ChatSettingsSheet(peerId: peerId),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 20),
          Divider(color: tokens.border),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Код профиля',
              style: TextStyle(color: tokens.muted, fontSize: 10),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            peerId,
            style: TextStyle(
              fontFamily: tokens.fontMono,
              fontSize: 11,
              color: tokens.text,
            ),
          ),
          const Spacer(),
          Icon(Icons.lock_outline, size: 14, color: tokens.muted),
          const SizedBox(height: 6),
          Text(
            'Защищённый локальный чат. История не уходит на сервер Orbits.',
            textAlign: TextAlign.center,
            style: TextStyle(color: tokens.muted, fontSize: 10, height: 1.5),
          ),
        ],
      ),
    );
  }
}

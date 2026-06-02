// Compact, Discord-like voice-channel panel — the DEFAULT view when you enter
// a voice channel. Shows the channel name, who's connected, a simple status,
// and the basic controls (mute / leave / open the advanced "3D звук" radar).
//
// The 3D / spatial radar is NOT shown here — it's an optional advanced mode
// opened via the "3D звук" button (the page owns its open/closed state). The
// voice connection lifecycle is independent of whether the radar is open.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../peer/room_manager.dart';
import '../../state/local_profile_provider.dart';
import '../../storage/db.dart' as db;
import '../../themes/orbits_tokens.dart';
import '../primitives/orbits_glass_button.dart';
import '../primitives/orbits_glass_surface.dart';

class VoiceChannelPanel extends ConsumerWidget {
  const VoiceChannelPanel({
    super.key,
    required this.roomId,
    required this.channelId,
    required this.channelName,
    required this.onOpenSpatial,
    required this.onLeaveVoice,
  });

  final String roomId;
  final String channelId;
  final String channelName;
  final VoidCallback onOpenSpatial;
  final VoidCallback onLeaveVoice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = OrbitsTokens.of(context);
    final roomState = ref.watch(roomManagerProvider);
    final selfId = ref.watch(localProfileProvider)?.peerId ?? '';
    final selfName = ref.watch(localProfileProvider)?.displayName ?? 'Вы';

    final connected = roomState.voiceChannelId == channelId;
    // Honest status, host-state first (Phase 3): a guest whose host died sees
    // the truth instead of a frozen "В голосе".
    final ended = roomState.roomConnection == RoomConnection.ended;
    final reconnecting =
        roomState.roomConnection == RoomConnection.reconnecting;
    final (statusText, statusColor) = ended
        ? ('Комната завершена', tokens.danger)
        : reconnecting
            ? ('Переподключение…', tokens.accent2)
            : !connected
                ? ('Подключение…', tokens.accent2)
                : (!roomState.micAvailable
                    ? ('Нет микрофона', tokens.danger)
                    : ('В голосе', tokens.success));

    return StreamBuilder<List<Map<String, Object?>>>(
      stream: db.watchRoomMembers(roomId),
      builder: (context, snap) {
        final members = snap.data ?? const <Map<String, Object?>>[];
        String nameOf(String peerId) {
          for (final m in members) {
            if (m['peerId'] == peerId) {
              final n = ((m['displayName'] as String?) ?? '').trim();
              if (n.isNotEmpty) return n;
            }
          }
          final tail =
              peerId.length >= 4 ? peerId.substring(peerId.length - 4) : peerId;
          return 'Контакт •$tail';
        }

        // Who's connected: me + the peers we hold a voice link with.
        final others = roomState.voicePeerIds.toList()..sort();

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: OrbitsGlassSurface(
                role: OrbitsGlassRole.card,
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Header: channel name + status ──
                      Row(
                        children: [
                          const Text('🔊', style: TextStyle(fontSize: 18)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              channelName.isNotEmpty ? channelName : 'Голос',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: tokens.text,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                fontFamily: tokens.fontHeading,
                              ),
                            ),
                          ),
                          _StatusChip(text: statusText, color: statusColor),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // ── Honest capacity + transport caption (Phase 3) ──
                      // Group voice is a direct peer-to-peer MESH (no media
                      // relay/SFU yet), so it's capped — say so plainly.
                      Text(
                        'Групповой голос • ${others.length + 1} из '
                        '$kMaxVoiceParticipants (прямое соединение, P2P-меш)',
                        style: TextStyle(
                          color: tokens.muted,
                          fontSize: 11.5,
                          fontFamily: tokens.fontBody,
                        ),
                      ),
                      if (!kIsWeb)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'Пространственный «3D-звук» обрабатывается только '
                            'в веб-версии; здесь радар показывает позиции, но '
                            'звук обычный.',
                            style: TextStyle(
                              color: tokens.muted,
                              fontSize: 11,
                              height: 1.3,
                              fontFamily: tokens.fontBody,
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      // ── Participants ──
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            _MemberRow(
                              name: '$selfName (вы)',
                              isHost: roomState.hostPeerId == selfId,
                              muted: !roomState.micEnabled ||
                                  !roomState.micAvailable,
                              tokens: tokens,
                            ),
                            for (final p in others)
                              _MemberRow(
                                name: nameOf(p),
                                isHost: roomState.hostPeerId == p,
                                muted: false,
                                tokens: tokens,
                              ),
                          ],
                        ),
                      ),
                      if (others.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 6),
                          child: Text(
                            'Пока вы один в канале.',
                            style: TextStyle(
                              color: tokens.muted,
                              fontSize: 12.5,
                              fontFamily: tokens.fontBody,
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      // ── Controls ──
                      Row(
                        children: [
                          Expanded(
                            child: OrbitsGlassButton(
                              label: roomState.micEnabled
                                  ? 'Микрофон'
                                  : 'Включить',
                              icon: roomState.micEnabled
                                  ? Icons.mic_rounded
                                  : Icons.mic_off_rounded,
                              variant: roomState.micEnabled
                                  ? OrbitsGlassVariant.secondary
                                  : OrbitsGlassVariant.subtle,
                              size: OrbitsGlassSize.medium,
                              onPressed: roomState.micAvailable
                                  ? () => ref
                                      .read(roomManagerProvider.notifier)
                                      .toggleMic()
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 8),
                          OrbitsGlassIconButton(
                            icon: Icons.blur_on_rounded,
                            tooltip: kIsWeb
                                ? '3D-звук (Spatial)'
                                : '3D-звук: панорама звука только в веб-версии',
                            variant: OrbitsGlassVariant.subtle,
                            size: OrbitsGlassSize.medium,
                            onPressed: onOpenSpatial,
                          ),
                          const SizedBox(width: 8),
                          OrbitsGlassIconButton(
                            icon: Icons.call_end_rounded,
                            tooltip: 'Выйти из голоса',
                            variant: OrbitsGlassVariant.danger,
                            size: OrbitsGlassSize.medium,
                            onPressed: onLeaveVoice,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              fontFamily: tokens.fontBody,
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.name,
    required this.isHost,
    required this.muted,
    required this.tokens,
  });

  final String name;
  final bool isHost;
  final bool muted;
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    final initial =
        name.trim().isNotEmpty ? name.trim().characters.first.toUpperCase() : '?';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [tokens.accent, tokens.accent2],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Text(
              initial,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tokens.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFamily: tokens.fontBody,
              ),
            ),
          ),
          if (isHost) ...[
            Icon(Icons.workspace_premium_rounded,
                size: 15, color: tokens.accent),
            const SizedBox(width: 6),
          ],
          Icon(
            muted ? Icons.mic_off_rounded : Icons.mic_rounded,
            size: 16,
            color: muted ? tokens.muted : tokens.success,
          ),
        ],
      ),
    );
  }
}

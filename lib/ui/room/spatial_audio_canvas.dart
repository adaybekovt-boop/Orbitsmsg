// Spatial-audio canvas (Phase 4 — voice rooms).
//
// A radar-style 2D plane. The local user ("Я") is pinned at the centre (0,0);
// every other voice participant is a draggable "balloon". Dragging a balloon
// moves that peer in [-1,1]² and, via RoomManager.setSpatialPosition:
//   • sets their stereo pan   = x   (−1 left ear … +1 right ear)
//   • sets their volume gain  = clamp(1 − √(x²+y²), 0, 1)   (distance fade)
//   • broadcasts the new coordinate to the room (host relays to all guests).
//
// Positions are read back from RoomState.spatialPositions, so a move made by
// any peer animates on everyone's canvas. Audio is applied by the Web Audio
// engine on web; on mobile the drag + sync are visual (safe fallback).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../peer/room_manager.dart';
import '../../state/local_profile_provider.dart';
import '../../storage/db.dart' as db;
import '../../themes/orbits_tokens.dart';
import '../primitives/orbits_glass_button.dart';
import '../primitives/orbits_glass_surface.dart';

class SpatialAudioCanvas extends ConsumerWidget {
  const SpatialAudioCanvas({
    super.key,
    required this.roomId,
    this.channelName = '',
  });

  final String roomId;
  final String channelName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roomState = ref.watch(roomManagerProvider);
    final selfId = ref.watch(localProfileProvider)?.peerId ?? '';
    final selfName = ref.watch(localProfileProvider)?.displayName ?? 'Я';

    return StreamBuilder<List<Map<String, Object?>>>(
      stream: db.watchRoomMembers(roomId),
      builder: (context, snap) {
        final members = snap.data ?? const <Map<String, Object?>>[];
        final others = [
          for (final m in members)
            if ((m['peerId'] as String?) != null &&
                (m['peerId'] as String).isNotEmpty &&
                m['peerId'] != selfId)
              m,
        ];

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: OrbitsGlassSurface(
            role: OrbitsGlassRole.card,
            borderRadius: BorderRadius.circular(24),
            child: Column(
              children: [
                _Header(
                  channelName: channelName,
                  inVoice: roomState.voicePeerIds.length,
                  total: others.length,
                  // Reset + auto-arrange share one operation (ring layout) —
                  // only meaningful once there's someone to arrange.
                  showActions: others.isNotEmpty,
                  onArrange: () => ref
                      .read(roomManagerProvider.notifier)
                      .resetSpatialPositions(),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        if (others.isEmpty) {
                          return _RadarStage(
                            size: constraints.biggest,
                            others: const [],
                            positions: const {},
                            voicePeerIds: const {},
                            selfName: selfName,
                            onMove: (_, __) {},
                            onMoveEnd: (_, __) {},
                            emptyHint:
                                'Пока вы один в голосовом канале.\nКогда подключатся другие — '
                                'перетаскивайте их шарики, чтобы расставить звук в пространстве.',
                          );
                        }
                        return _RadarStage(
                          size: constraints.biggest,
                          others: others,
                          positions: roomState.spatialPositions,
                          voicePeerIds: roomState.voicePeerIds,
                          selfName: selfName,
                          onMove: (peerId, pos) => ref
                              .read(roomManagerProvider.notifier)
                              .setSpatialPosition(peerId, pos),
                          onMoveEnd: (peerId, pos) => ref
                              .read(roomManagerProvider.notifier)
                              .setSpatialPosition(peerId, pos, isFinal: true),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.channelName,
    required this.inVoice,
    required this.total,
    this.showActions = false,
    this.onArrange,
  });

  final String channelName;
  final int inVoice;
  final int total;

  /// Show the reset / auto-arrange controls (only when there's someone to
  /// arrange).
  final bool showActions;
  final VoidCallback? onArrange;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
      child: Row(
        children: [
          Icon(Icons.graphic_eq_rounded, size: 18, color: tokens.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              channelName.isNotEmpty ? channelName : 'Пространственный звук',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tokens.text,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontFamily: tokens.fontHeading,
              ),
            ),
          ),
          Text(
            inVoice > 0 ? '$inVoice в эфире' : '$total участн.',
            style: TextStyle(
              color: tokens.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFamily: tokens.fontBody,
            ),
          ),
          if (showActions) ...[
            const SizedBox(width: 6),
            // Auto-arrange: spread everyone evenly on a ring.
            OrbitsGlassIconButton(
              icon: Icons.scatter_plot_rounded,
              tooltip: 'Расставить по кругу',
              variant: OrbitsGlassVariant.subtle,
              size: OrbitsGlassSize.small,
              onPressed: onArrange,
            ),
            const SizedBox(width: 4),
            // Reset: same ring layout, framed as "put positions back".
            OrbitsGlassIconButton(
              icon: Icons.refresh_rounded,
              tooltip: 'Сбросить позиции',
              variant: OrbitsGlassVariant.subtle,
              size: OrbitsGlassSize.small,
              onPressed: onArrange,
            ),
          ],
        ],
      ),
    );
  }
}

/// The radar plane: grid + centred "me" + draggable balloons.
class _RadarStage extends StatelessWidget {
  const _RadarStage({
    required this.size,
    required this.others,
    required this.positions,
    required this.voicePeerIds,
    required this.selfName,
    required this.onMove,
    required this.onMoveEnd,
    this.emptyHint,
  });

  final Size size;
  final List<Map<String, Object?>> others;
  final Map<String, Offset> positions;
  final Set<String> voicePeerIds;
  final String selfName;
  final void Function(String peerId, Offset pos) onMove;

  /// Called once when a drag ends, with the resting position — drives the
  /// guaranteed (un-throttled) final network send.
  final void Function(String peerId, Offset pos) onMoveEnd;
  final String? emptyHint;

  static const double _balloon = 70; // balloon box (avatar + label)
  static const double _margin = 44; // keep balloons fully on-canvas

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final w = size.width.isFinite ? size.width : 0.0;
    final h = size.height.isFinite ? size.height : 0.0;
    if (w <= 0 || h <= 0) return const SizedBox.shrink();

    final cx = w / 2;
    final cy = h / 2;
    final rx = math.max(1.0, (w / 2) - _margin);
    final ry = math.max(1.0, (h / 2) - _margin);

    Offset toPixel(Offset norm) => Offset(cx + norm.dx * rx, cy + norm.dy * ry);
    Offset toNorm(Offset px) => Offset(
          ((px.dx - cx) / rx).clamp(-1.0, 1.0),
          ((px.dy - cy) / ry).clamp(-1.0, 1.0),
        );

    final children = <Widget>[
      Positioned.fill(child: CustomPaint(painter: _RadarPainter(tokens))),
      // Centre "me".
      Positioned(
        left: cx - 30,
        top: cy - 38,
        width: 60,
        height: 76,
        child: _Marker(
          name: selfName.isNotEmpty ? selfName : 'Я',
          label: 'Я',
          color: tokens.accent2,
          highlighted: true,
          tokens: tokens,
        ),
      ),
    ];

    for (var i = 0; i < others.length; i++) {
      final m = others[i];
      final id = m['peerId'] as String;
      final name = ((m['displayName'] as String?) ?? '').trim();
      final norm = positions[id] ?? _defaultPos(i, others.length);
      final center = toPixel(norm);
      final inVoice = voicePeerIds.contains(id);

      children.add(Positioned(
        left: center.dx - _balloon / 2,
        top: center.dy - _balloon / 2,
        width: _balloon,
        height: _balloon,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) {
            final next = toPixel(positions[id] ?? norm) + d.delta;
            onMove(id, toNorm(next));
          },
          // Pan-end always flushes the resting position past the throttle.
          onPanEnd: (_) => onMoveEnd(id, positions[id] ?? norm),
          child: _Marker(
            name: name.isNotEmpty ? name : _shortId(id),
            label: name.isNotEmpty
                ? name.characters.first.toUpperCase()
                : '?',
            color: tokens.accent,
            highlighted: inVoice,
            tokens: tokens,
            draggable: true,
          ),
        ),
      ));
    }

    if (others.isEmpty && emptyHint != null) {
      children.add(Positioned(
        left: 24,
        right: 24,
        bottom: 20,
        child: Text(
          emptyHint!,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: tokens.muted,
            fontSize: 12.5,
            height: 1.4,
            fontFamily: tokens.fontBody,
          ),
        ),
      ));
    }

    return Stack(clipBehavior: Clip.none, children: children);
  }

  /// Default ring layout for peers without an explicit position.
  static Offset _defaultPos(int i, int n) {
    if (n <= 0) return Offset.zero;
    final angle = (2 * math.pi * i / n) - (math.pi / 2);
    const r = 0.62;
    return Offset(r * math.cos(angle), r * math.sin(angle));
  }

  static String _shortId(String id) {
    final tail = id.length >= 4 ? id.substring(id.length - 4) : id;
    return '•$tail';
  }
}

/// A circular avatar "balloon" with a name label underneath.
class _Marker extends StatelessWidget {
  const _Marker({
    required this.name,
    required this.label,
    required this.color,
    required this.highlighted,
    required this.tokens,
    this.draggable = false,
  });

  final String name;
  final String label;
  final Color color;
  final bool highlighted;
  final OrbitsTokens tokens;
  final bool draggable;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [color, tokens.accent2],
            ),
            border: Border.all(
              color: highlighted
                  ? tokens.success
                  : tokens.text.withValues(alpha: 0.18),
              width: highlighted ? 2.5 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: highlighted ? 0.45 : 0.22),
                blurRadius: highlighted ? 16 : 8,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 70,
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: tokens.text,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFamily: tokens.fontBody,
            ),
          ),
        ),
      ],
    );
  }
}

/// Concentric radar rings + crosshair.
class _RadarPainter extends CustomPainter {
  _RadarPainter(this.tokens);
  final OrbitsTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = math.max(0.0, math.min(size.width, size.height) / 2 - 12);

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = tokens.muted.withValues(alpha: 0.22);
    for (var i = 1; i <= 3; i++) {
      canvas.drawCircle(center, maxR * i / 3, ring);
    }

    final cross = Paint()
      ..strokeWidth = 1
      ..color = tokens.muted.withValues(alpha: 0.14);
    canvas.drawLine(
      Offset(center.dx - maxR, center.dy),
      Offset(center.dx + maxR, center.dy),
      cross,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxR),
      Offset(center.dx, center.dy + maxR),
      cross,
    );

    // Soft accent glow at the centre (the listener).
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [
          tokens.accent.withValues(alpha: 0.16),
          tokens.accent.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: maxR * 0.6));
    canvas.drawCircle(center, maxR * 0.6, glow);
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) => false;
}

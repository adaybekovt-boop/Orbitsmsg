// Port of `src/components/PeerStatusPill.jsx` — the tiny floating chip in
// the top-right that tells the user whether WebRTC signaling is up. Shows
// peerId (truncated), current status color, error string on tap.
//
// In the React app this sat in a fixed-position div above the tab content.
// Flutter's equivalent is an `Align(alignment: topRight) + Padding` inside
// a Stack — callers wrap their Scaffold body with `PeerStatusPillOverlay`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/outbox_provider.dart';
import '../../state/peer_connection_provider.dart';
import '../../themes/orbits_tokens.dart';

/// How much vertical space the floating pill reserves at the top of the
/// screen — pages that render their own scroll views should use this as
/// top padding so the first row isn't covered by the pill. Computed from
/// pill height (≈28) + top offset (8) + a small breathing margin.
const double kPillReserveHeight = 48;

/// Raw pill — just the chip, no positioning. Use this when embedding inside
/// a custom layout (e.g. a settings row that shows connection state).
class PeerStatusPill extends ConsumerWidget {
  const PeerStatusPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(peerConnectionProvider);
    final pending = ref.watch(outboxCountProvider);
    final tokens = OrbitsTokens.of(context);

    // Hide the pill entirely in the calm "connected" state — the persistent
    // "В сети" chip is just visual clutter. It only surfaces when something
    // actually needs attention: a connection problem (tap to reconnect) or
    // queued/unsent messages.
    if (conn.status == 'connected' && pending == 0) {
      return const SizedBox.shrink();
    }

    // Status colour comes from theme tokens — `success` for the happy path,
    // `accent2` for transient/connecting (the JS picked amber via accent2),
    // `danger` for hard errors, `muted` for the quiet idle state.
    final (Color color, String label) = switch (conn.status) {
      'connected' => (tokens.success, 'В сети'),
      'connecting' => (tokens.accent2, 'Подключение…'),
      'multitab' => (tokens.danger, 'Другая вкладка'),
      'disconnected' => (tokens.muted, 'Не в сети'),
      _ => (tokens.muted, 'Готов'),
    };

    final peerId = conn.peerId;
    // The raw profile code is NOT shown inline in the global pill (too
    // technical) — it lives in the long-press tooltip, with any error.
    final tipParts = <String>[
      if (peerId != null && peerId.isNotEmpty) 'Код: $peerId',
      if (conn.error != null && conn.error!.isNotEmpty) conn.error!,
    ];
    final tip = tipParts.join('\n');

    // Pill background reads as a semi-opaque surface — works on both light
    // (Paper, Sakura) and dark (Graphite, Matrix) themes because we pull
    // the canvas colour and dim it.
    final pillBg = tokens.bg.withValues(alpha: 0.78);
    final labelColor = tokens.text;

    return Tooltip(
      // Long-press reveals the profile code + any error. Nothing technical is
      // shown inline in the pill.
      message: tip,
      triggerMode: tip.isEmpty
          ? TooltipTriggerMode.manual
          : TooltipTriggerMode.longPress,
      child: Material(
        color: pillBg,
        shape: StadiumBorder(
          side: BorderSide(color: color.withValues(alpha: 0.6)),
        ),
        child: InkWell(
          onTap: conn.status == 'disconnected'
              ? () => ref.read(peerConnectionProvider.notifier).reconnectNow()
              : null,
          customBorder: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StatusDot(color: color),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: labelColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    fontFamily: tokens.fontBody,
                  ),
                ),
                if (pending > 0) ...[
                  const SizedBox(width: 8),
                  _OutboxBadge(count: pending),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Convenience wrapper that pins the pill to the top-right over arbitrary
/// content. Use inside a Scaffold body:
///   `body: PeerStatusPillOverlay(child: ...)`
class PeerStatusPillOverlay extends StatelessWidget {
  const PeerStatusPillOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        // `SafeArea` keeps the pill clear of notches/status bar; the extra
        // 8px top offset matches the React build's visual weight.
        const Positioned(
          top: 0,
          right: 0,
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.only(top: 8, right: 12),
              child: PeerStatusPill(),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 4),
        ],
      ),
    );
  }
}

class _OutboxBadge extends StatelessWidget {
  const _OutboxBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    // Outbox badge tinted in the warning-ish accent2. The label color picks
    // up the same hue but boosted to full opacity so it stays legible.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tokens.accent2Alpha(0.20),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.accent2Alpha(0.65)),
      ),
      child: Text(
        '$count в очереди',
        style: TextStyle(
          color: tokens.accent2,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          fontFamily: tokens.fontBody,
        ),
      ),
    );
  }
}

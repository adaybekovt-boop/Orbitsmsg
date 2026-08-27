// Full-screen overlay that hosts the active call.
//
// Three render branches based on `CallState.status`:
//   • `calling`  — outgoing dial. Big avatar + peer name + cancel button.
//   • `ringing`  — incoming. Avatar + accept (green) + decline (red).
//   • `inCall`   — full remote video (or "Видео выкл." placeholder),
//                  draggable PIP for local video, 4 control buttons
//                  (mic / video / screen / hangup) at the bottom.
//
// Idle state collapses to an `IgnorePointer + SizedBox.shrink` so the
// overlay takes zero space until a call kicks in. AppShell stacks this
// above its IndexedStack via `Positioned.fill`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/haptics.dart';
import '../../state/calls_provider.dart';
import '../../state/peers_provider.dart';
import '../../themes/orbits_tokens.dart';
import '../primitives/orbits_glass_surface.dart';

class CallOverlayMount extends ConsumerWidget {
  const CallOverlayMount({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(callsNotifierProvider);
    if (!s.isActive) {
      final err = s.lastError;
      if (err != null && err.isNotEmpty) {
        return _IdleCallError(message: err);
      }
      return const IgnorePointer(
        ignoring: true,
        child: SizedBox.shrink(),
      );
    }
    return const _CallOverlay();
  }
}

class _CallOverlay extends ConsumerStatefulWidget {
  const _CallOverlay();

  @override
  ConsumerState<_CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends ConsumerState<_CallOverlay> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  /// PIP draggable position, kept in pixels relative to the overlay.
  /// Reset on call end. Defaults to bottom-right.
  Offset? _pipOffset;

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _remoteRenderer.initialize();
    // Sync renderers with the current state immediately — there's no
    // didChangeDependencies path for the very first frame because the
    // notifier emits `inCall` *before* this widget mounts.
    _syncRenderers(ref.read(callsNotifierProvider));
  }

  @override
  void dispose() {
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  void _syncRenderers(CallState s) {
    if (_localRenderer.srcObject != s.localStream) {
      _localRenderer.srcObject = s.localStream;
    }
    if (_remoteRenderer.srcObject != s.remoteStream) {
      _remoteRenderer.srcObject = s.remoteStream;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final s = ref.watch(callsNotifierProvider);
    _syncRenderers(s);

    return Material(
      type: MaterialType.transparency,
      child: Container(
        // Dark scrim covering everything beneath. The inner panel is
        // bordered + slightly tinted so the call UI reads as a
        // distinct surface, not "the chat darkened".
        color: Colors.black.withValues(alpha: 0.85),
        child: SafeArea(
          child: switch (s.status) {
            CallStatus.calling => _buildCalling(tokens, s),
            CallStatus.ringing => _buildRinging(tokens, s),
            CallStatus.inCall => _buildInCall(tokens, s),
            CallStatus.idle => const SizedBox.shrink(),
          },
        ),
      ),
    );
  }

  // ─── Sub-screens ────────────────────────────────────────────

  Widget _buildCalling(OrbitsTokens tokens, CallState s) {
    return _PreCallScaffold(
      title: 'Звоним…',
      subtitle: _peerLabel(s.remotePeerId),
      tokens: tokens,
      actions: [
        _CallAction(
          icon: Icons.call_end,
          label: 'Отменить',
          color: tokens.danger,
          onTap: () {
            hapticTap();
            ref.read(callsNotifierProvider.notifier).hangUp();
          },
        ),
      ],
      error: s.lastError,
    );
  }

  Widget _buildRinging(OrbitsTokens tokens, CallState s) {
    return _PreCallScaffold(
      title: 'Входящий звонок',
      subtitle: _peerLabel(s.remotePeerId),
      tokens: tokens,
      actions: [
        _CallAction(
          icon: Icons.call_end,
          label: 'Отклонить',
          color: tokens.danger,
          onTap: () {
            hapticTap();
            ref.read(callsNotifierProvider.notifier).declineCurrent();
          },
        ),
        _CallAction(
          icon: Icons.call,
          label: 'Принять',
          color: tokens.success,
          onTap: () {
            hapticTap();
            ref.read(callsNotifierProvider.notifier).acceptCurrent();
          },
        ),
      ],
      error: s.lastError,
    );
  }

  Widget _buildInCall(OrbitsTokens tokens, CallState s) {
    return Stack(
      children: [
        // Remote video fills the screen. Black background under it so
        // letterboxed aspect ratios don't show the scrim through.
        Positioned.fill(
          child: ColoredBox(
            color: Colors.black,
            child: s.remoteStream != null
                ? RTCVideoView(
                    _remoteRenderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.videocam_off,
                            color: Colors.white54, size: 48),
                        const SizedBox(height: 12),
                        Text(
                          'Ожидание видео…',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                            fontFamily: tokens.fontBody,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),

        // Top header — peer name + label
        Positioned(
          top: 16,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(tokens.radiusButton),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.redAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _peerLabel(s.remotePeerId),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      fontFamily: tokens.fontHeading,
                    ),
                  ),
                ),
                Text(
                  s.screenSharing
                      ? 'Демонстрация экрана'
                      : (s.video ? 'Видео-звонок' : 'Аудио-звонок'),
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Local PIP — draggable. 96×128 logical px, pinned to the
        // bottom-right by default. The overlay is the bounds.
        if (s.localStream != null && s.videoEnabled)
          _LocalPip(
            renderer: _localRenderer,
            offset: _pipOffset,
            onMove: (next) => setState(() => _pipOffset = next),
            screenSharing: s.screenSharing,
          ),

        // Control bar — bottom-anchored, four round buttons
        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Center(
            child: OrbitsGlassSurface(
              role: OrbitsGlassRole.navBar,
              borderRadius: BorderRadius.circular(32),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _RoundButton(
                    icon: s.micEnabled ? Icons.mic : Icons.mic_off,
                    active: !s.micEnabled,
                    onTap: () {
                      hapticTap();
                      ref
                          .read(callsNotifierProvider.notifier)
                          .setMicEnabled(!s.micEnabled);
                    },
                  ),
                  const SizedBox(width: 10),
                  _RoundButton(
                    icon: s.videoEnabled ? Icons.videocam : Icons.videocam_off,
                    active: !s.videoEnabled,
                    onTap: () {
                      hapticTap();
                      ref
                          .read(callsNotifierProvider.notifier)
                          .setVideoEnabled(!s.videoEnabled);
                    },
                  ),
                  const SizedBox(width: 10),
                  _RoundButton(
                    icon: s.screenSharing
                        ? Icons.stop_screen_share
                        : Icons.screen_share,
                    active: s.screenSharing,
                    activeColor: tokens.accent,
                    onTap: () {
                      hapticTap();
                      ref
                          .read(callsNotifierProvider.notifier)
                          .toggleScreenShare();
                    },
                  ),
                  const SizedBox(width: 10),
                  _RoundButton(
                    icon: Icons.call_end,
                    active: true,
                    activeColor: tokens.danger,
                    onTap: () {
                      hapticTap();
                      ref.read(callsNotifierProvider.notifier).hangUp();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),

        // Error toast (top-of-stack, drawn last so it covers everything)
        if (s.lastError != null && s.lastError!.isNotEmpty)
          Positioned(
            top: 80,
            left: 16,
            right: 16,
            child: _ErrorToast(message: s.lastError ?? '', tokens: tokens),
          ),
      ],
    );
  }

  /// Resolve a friendly label for the remote peer — falls back to the
  /// peer id itself if no profile row exists.
  String _peerLabel(String? peerId) {
    if (peerId == null || peerId.isEmpty) return '—';
    final peers = ref.read(peersProvider).asData?.value ?? const [];
    for (final r in peers) {
      if ((r['id'] as String?) != peerId) continue;
      final custom = (r['customName'] as String?) ?? '';
      if (custom.trim().isNotEmpty) return custom.trim();
      final remote = (r['displayName'] as String?) ?? '';
      if (remote.trim().isNotEmpty) return remote;
      break;
    }
    return peerId;
  }
}

// ─── Sub-widgets ──────────────────────────────────────────────────

/// Shared chrome for `calling` and `ringing` states — both want a big
/// avatar / peer name in the centre and 1-2 round buttons beneath.
class _PreCallScaffold extends StatelessWidget {
  const _PreCallScaffold({
    required this.title,
    required this.subtitle,
    required this.tokens,
    required this.actions,
    this.error,
  });

  final String title;
  final String subtitle;
  final OrbitsTokens tokens;
  final List<_CallAction> actions;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(),
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: tokens.accentAlpha(0.18),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.person, size: 48, color: tokens.accent),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              fontFamily: tokens.fontHeading,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontFamily: tokens.fontMono,
            ),
          ),
          if (error != null && error!.isNotEmpty) ...[
            const SizedBox(height: 18),
            _ErrorToast(message: error ?? '', tokens: tokens),
          ],
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: actions,
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _CallAction extends StatelessWidget {
  const _CallAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 64,
              height: 64,
              child: Icon(icon, color: Colors.white, size: 28),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// Compact circular toggle button used in the in-call control bar.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.active,
    required this.onTap,
    this.activeColor,
  });

  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final bg = active
        ? (activeColor ?? Colors.white).withValues(alpha: 0.95)
        : Colors.white.withValues(alpha: 0.18);
    final fg = active ? Colors.black : Colors.white;
    return Material(
      color: bg,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 52,
          height: 52,
          child: Icon(icon, color: fg, size: 22),
        ),
      ),
    );
  }
}

/// Local-camera picture-in-picture. Draggable inside the overlay, with
/// a soft frame and an "Видео выкл." overlay if the user muted video.
class _LocalPip extends StatelessWidget {
  const _LocalPip({
    required this.renderer,
    required this.offset,
    required this.onMove,
    required this.screenSharing,
  });

  final RTCVideoRenderer renderer;
  final Offset? offset;
  final ValueChanged<Offset> onMove;
  final bool screenSharing;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).size;
    const pipW = 120.0;
    const pipH = 160.0;
    final defaultOffset = Offset(
      media.width - pipW - 16,
      media.height - pipH - 110,
    );
    final pos = offset ?? defaultOffset;
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: Listener(
        // Track raw pointer movements — same reasoning as Block Blast:
        // GestureDetector pan doesn't always fire on web mouse drag.
        onPointerMove: (e) {
          final next = Offset(
            (pos.dx + e.delta.dx).clamp(0, media.width - pipW),
            (pos.dy + e.delta.dy).clamp(0, media.height - pipH),
          );
          onMove(next);
        },
        child: Container(
          width: pipW,
          height: pipH,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.25),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RTCVideoView(
                renderer,
                // Mirror the local front-camera feed so left/right
                // matches the user's reflection. Screen-share isn't
                // mirrored.
                mirror: !screenSharing,
                objectFit:
                    RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
              if (screenSharing)
                Positioned(
                  top: 4,
                  left: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'ЭКРАН',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Visible when a call failed but we are idle again (R6-14). Mounted at
/// the [MaterialApp.builder] layer so a pushed chat cannot hide it.
class _IdleCallError extends StatelessWidget {
  const _IdleCallError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return IgnorePointer(
      ignoring: true,
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _ErrorToast(message: message, tokens: tokens),
          ),
        ),
      ),
    );
  }
}

class _ErrorToast extends StatelessWidget {
  const _ErrorToast({required this.message, required this.tokens});
  final String message;
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: tokens.dangerAlpha(0.18),
        borderRadius: BorderRadius.circular(tokens.radiusButton),
        border: Border.all(color: tokens.dangerAlpha(0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: tokens.danger, size: 18),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              message,
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontFamily: tokens.fontBody,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

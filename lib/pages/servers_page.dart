// Servers / Rooms — a first-class main section (Discord-like temporary P2P
// servers). This is the section LANDING: a prominent active-server card (if
// you're in one), two big CTAs (Создать сервер / Подключиться), and the list of
// your servers. Entering a server opens [RoomChatPage] (channels + chat +
// voice). Create/join are NOT hidden behind a tiny icon anymore.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../peer/room_invite.dart';
import '../peer/room_manager.dart';
import '../peer/room_signaling_host.dart'
    show canHostSignalingServer, hostingLimitationSummary;
import '../state/local_profile_provider.dart';
import '../storage/db.dart' as db;
import '../themes/orbits_tokens.dart';
import '../ui/peer/peer_status_pill.dart' show kPillReserveHeight;
import '../ui/primitives/adaptive_page_frame.dart';
import '../ui/primitives/orbits_glass_button.dart';
import '../ui/primitives/orbits_glass_list_tile.dart';
import '../ui/primitives/orbits_glass_surface.dart';
import 'room_chat_page.dart';

class ServersHomePage extends ConsumerStatefulWidget {
  const ServersHomePage({super.key});

  @override
  ConsumerState<ServersHomePage> createState() => _ServersHomePageState();
}

class _ServersHomePageState extends ConsumerState<ServersHomePage> {
  RoomManager get _rooms => ref.read(roomManagerProvider.notifier);

  /// True while a create/join is in flight. Drives the loading overlay and
  /// disables the CTAs so the buttons never look dead (and can't be double-
  /// tapped into two concurrent sessions).
  bool _busy = false;
  String _busyLabel = '';

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  void _openRoom(String? roomId) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RoomChatPage(initialRoomId: roomId)),
    );
  }

  Future<void> _createServer() async {
    if (_busy) return; // reentrancy / double-tap guard
    final myName = ref.read(localProfileProvider)?.displayName ?? '';
    // On a desktop platform we host our OWN signaling server (no peerjs.com);
    // elsewhere we fall back to a cloud-signaled room.
    final selfHost = canHostSignalingServer;
    final name = await _promptText(
      title: selfHost ? 'Создать свой сервер' : 'Создать сервер',
      hint: 'Название сервера',
      initial: myName.isNotEmpty ? '$myName: сервер' : '',
      confirm: 'Создать',
      // Honest, up-front: what hosting actually means on this platform + the
      // group-voice capacity limit (mesh, not an SFU).
      note: '${hostingLimitationSummary()}\n\n'
          'До $kMaxRoomMembers участников. Групповой голос — до '
          '$kMaxVoiceParticipants (прямое соединение каждый-с-каждым).',
    );
    if (name == null || name.trim().isEmpty) return;

    setState(() {
      _busy = true;
      _busyLabel = 'Создаём сервер…';
    });
    try {
      await _rooms.createRoom(name.trim(), selfHosted: selfHost);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    final st = ref.read(roomManagerProvider);
    // Hard failure — no room was created (bad platform / no profile). Say why
    // and stay put; never navigate into an empty room.
    if (st.role == RoomRole.none) {
      _toast(st.joinError ?? 'Не удалось создать сервер.');
      _rooms.clearJoinError();
      return;
    }
    // Soft notice — the room exists (e.g. created offline because the network
    // couldn't start). Surface it but still open the room.
    if (st.joinError != null) {
      _toast(st.joinError!);
      _rooms.clearJoinError();
    }
    // Self-hosted + online: show the shareable invite (with reachability) now.
    final invite = st.selfHostInvite;
    if (invite != null) {
      await showDialog<void>(
        context: context,
        builder: (_) => _InviteDialog(invite: invite),
      );
      if (!mounted) return;
    }
    if (st.roomId != null) _openRoom(st.roomId);
  }

  Future<void> _joinServer() async {
    if (_busy) return; // reentrancy / double-tap guard
    final myName = ref.read(localProfileProvider)?.displayName ?? '';
    final code = await _promptText(
      title: 'Подключиться к серверу',
      hint: 'ORBIT-XXXXXX или orbits-room:…',
      confirm: 'Подключиться',
      mono: true,
    );
    if (code == null || code.trim().isEmpty) return;

    setState(() {
      _busy = true;
      _busyLabel = 'Подключаемся…';
    });
    try {
      await _rooms.joinRoom(code.trim(), myName);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    final st = ref.read(roomManagerProvider);
    if (st.role == RoomRole.none) {
      _toast(st.joinError ?? 'Не удалось подключиться.');
      _rooms.clearJoinError();
      return;
    }
    if (st.joinError != null) {
      _toast(st.joinError!);
      _rooms.clearJoinError();
    }
    if (st.roomId != null) _openRoom(st.roomId);
  }

  Future<String?> _promptText({
    required String title,
    required String hint,
    String initial = '',
    String confirm = 'OK',
    bool mono = false,
    String? note,
  }) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => _PromptDialog(
        title: title,
        hint: hint,
        initial: initial,
        confirm: confirm,
        mono: mono,
        note: note,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final roomState = ref.watch(roomManagerProvider);

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
          'Серверы',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
      ),
      body: Stack(
        children: [
          AdaptivePageFrame(
            maxWidth: 620,
            child: StreamBuilder<List<Map<String, Object?>>>(
              stream: db.watchRooms(),
              builder: (context, snap) {
            final rooms = snap.data ?? const <Map<String, Object?>>[];
            final activeId =
                roomState.role != RoomRole.none ? roomState.roomId : null;
            final activeRoom = _byId(rooms, activeId);

            return ListView(
              padding: const EdgeInsets.fromLTRB(
                  16, kPillReserveHeight + 8, 16, 24),
              children: [
                if (activeRoom != null) ...[
                  _ActiveServerCard(
                    room: activeRoom,
                    isHost: roomState.role == RoomRole.host,
                    onOpen: () => _openRoom(activeId),
                  ),
                  const SizedBox(height: 18),
                ],
                // Two primary CTAs.
                OrbitsGlassButton(
                  label: 'Создать сервер',
                  icon: Icons.add_circle_outline_rounded,
                  variant: OrbitsGlassVariant.primary,
                  size: OrbitsGlassSize.large,
                  expand: true,
                  enabled: !_busy,
                  onPressed: _createServer,
                ),
                const SizedBox(height: 10),
                OrbitsGlassButton(
                  label: 'Подключиться',
                  icon: Icons.login_rounded,
                  variant: OrbitsGlassVariant.secondary,
                  size: OrbitsGlassSize.large,
                  expand: true,
                  enabled: !_busy,
                  onPressed: _joinServer,
                ),
                // Honest capability note: only desktop runs a persistent
                // embedded server. On web/mobile a "server" rides the public
                // relay and is live only while the app is open.
                if (!canHostSignalingServer) ...[
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 15, color: tokens.muted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Здесь сервер работает через облачную связь и активен, '
                          'пока открыто приложение. Постоянный собственный сервер '
                          'можно поднять в приложении для ПК (Windows/macOS/Linux).',
                          style: TextStyle(
                            color: tokens.muted,
                            fontSize: 12,
                            height: 1.4,
                            fontFamily: tokens.fontBody,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                // Security honesty (audit P1 item 7): room/server messages are
                // NOT end-to-end encrypted like 1:1 chats. They're protected in
                // transit (DTLS) but the room host can read them. Stated so the
                // UI never implies room E2EE.
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_open_rounded, size: 15, color: tokens.muted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Сообщения в комнатах защищены при передаче, но, в отличие '
                        'от личных чатов, без сквозного шифрования — их может видеть '
                        'хост комнаты.',
                        style: TextStyle(
                          color: tokens.muted,
                          fontSize: 12,
                          height: 1.4,
                          fontFamily: tokens.fontBody,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Text(
                  'ВАШИ СЕРВЕРЫ',
                  style: TextStyle(
                    fontFamily: tokens.fontHeading,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: tokens.muted,
                  ),
                ),
                const SizedBox(height: 8),
                if (rooms.isEmpty)
                  _EmptyHint(tokens: tokens)
                else
                  for (final r in rooms)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: _ServerRow(
                        room: r,
                        isActive: (r['id'] as String?) == activeId,
                        onTap: () => _openRoom(r['id'] as String?),
                      ),
                    ),
              ],
            );
              },
            ),
          ),
          if (_busy) _CreatingOverlay(label: _busyLabel),
        ],
      ),
    );
  }

  Map<String, Object?>? _byId(List<Map<String, Object?>> rooms, String? id) {
    if (id == null) return null;
    for (final r in rooms) {
      if (r['id'] == id) return r;
    }
    return null;
  }
}

/// Prominent block for the server you're currently connected to.
class _ActiveServerCard extends ConsumerWidget {
  const _ActiveServerCard({
    required this.room,
    required this.isHost,
    required this.onOpen,
  });

  final Map<String, Object?> room;
  final bool isHost;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = OrbitsTokens.of(context);
    final id = (room['id'] as String?) ?? '';
    final name = ((room['name'] as String?) ?? '').trim();
    final online = (room['status'] as String?) != 'offline';
    // Self-hosted host only: the shareable `orbits-room:` invite.
    final invite = isHost ? ref.watch(roomManagerProvider).selfHostInvite : null;

    return OrbitsGlassSurface(
      role: OrbitsGlassRole.card,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.hub_rounded, color: tokens.accent, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name.isNotEmpty ? name : (id.isNotEmpty ? id : 'Сервер'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tokens.text,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      fontFamily: tokens.fontHeading,
                    ),
                  ),
                ),
                _Dot(online: online, tokens: tokens),
              ],
            ),
            const SizedBox(height: 10),
            StreamBuilder<List<Map<String, Object?>>>(
              stream: id.isEmpty ? null : db.watchRoomMembers(id),
              builder: (context, snap) {
                final count = snap.data?.length ?? 0;
                return Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _Chip(
                      label: isHost ? 'Вы — хост' : 'Участник',
                      color: tokens.accent,
                      tokens: tokens,
                    ),
                    _Chip(
                      label: online ? 'В сети' : 'Не в сети',
                      color: online ? tokens.success : tokens.muted,
                      tokens: tokens,
                    ),
                    if (count > 0)
                      _Chip(
                        label: '$count участн.',
                        color: tokens.muted,
                        tokens: tokens,
                      ),
                  ],
                );
              },
            ),
            if (invite != null) ...[
              const SizedBox(height: 12),
              _ReachLine(invite: invite, tokens: tokens),
              const SizedBox(height: 10),
              OrbitsGlassButton(
                label: 'Поделиться приглашением',
                icon: Icons.ios_share_rounded,
                variant: OrbitsGlassVariant.secondary,
                expand: true,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => _InviteDialog(invite: invite),
                ),
              ),
            ],
            const SizedBox(height: 14),
            OrbitsGlassButton(
              label: 'Открыть',
              icon: Icons.arrow_forward_rounded,
              variant: OrbitsGlassVariant.primary,
              expand: true,
              onPressed: onOpen,
            ),
          ],
        ),
      ),
    );
  }
}

/// One-line reachability summary parsed from an `orbits-room:` invite.
class _ReachLine extends StatelessWidget {
  const _ReachLine({required this.invite, required this.tokens});
  final String invite;
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    final parsed = RoomInvite.tryParse(invite);
    final public = parsed?.hasPublic ?? false;
    final label = public
        ? 'Доступен из интернета + по локальной сети'
        : 'Только локальная сеть (LAN)';
    final color = public ? tokens.success : tokens.accent2;
    return Row(
      children: [
        Icon(public ? Icons.public_rounded : Icons.wifi_rounded,
            size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: tokens.muted,
              fontSize: 12,
              fontFamily: tokens.fontBody,
            ),
          ),
        ),
      ],
    );
  }
}

/// Dialog that shows the shareable self-hosted room invite + copy + a short
/// reachability hint. Pure presentation — the invite string is already built.
class _InviteDialog extends StatelessWidget {
  const _InviteDialog({required this.invite});
  final String invite;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final parsed = RoomInvite.tryParse(invite);
    final public = parsed?.hasPublic ?? false;
    return AlertDialog(
      backgroundColor: tokens.surface,
      title: Text(
        'Приглашение на сервер',
        style: TextStyle(fontFamily: tokens.fontHeading, color: tokens.text),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Отправьте этот код друзьям — они вставят его в «Подключиться».',
            style: TextStyle(
              color: tokens.muted,
              fontSize: 13,
              height: 1.4,
              fontFamily: tokens.fontBody,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: tokens.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: tokens.accentAlpha(0.25)),
            ),
            child: SelectableText(
              invite,
              style: TextStyle(
                fontFamily: tokens.fontMono,
                fontSize: 12.5,
                color: tokens.text,
              ),
            ),
          ),
          const SizedBox(height: 10),
          _ReachLine(invite: invite, tokens: tokens),
          if (!public) ...[
            const SizedBox(height: 8),
            Text(
              'Для друзей из других сетей включите UPnP на роутере или '
              'пробросьте порт ${parsed?.port ?? ''} (TCP) на этот ПК.',
              style: TextStyle(
                color: tokens.muted,
                fontSize: 11.5,
                height: 1.4,
                fontFamily: tokens.fontBody,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: invite));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(const SnackBar(
                  content: Text('Код приглашения скопирован'),
                  duration: Duration(seconds: 2),
                ));
            }
          },
          child: const Text('Копировать'),
        ),
      ],
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.room,
    required this.isActive,
    required this.onTap,
  });

  final Map<String, Object?> room;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final id = (room['id'] as String?) ?? '';
    final name = ((room['name'] as String?) ?? '').trim();
    final isHost = room['isHost'] == true ||
        (room['isHost'] is num && (room['isHost'] as num).toInt() != 0);
    final online = (room['status'] as String?) != 'offline';
    final initial =
        name.isNotEmpty ? name.characters.first.toUpperCase() : '#';

    return OrbitsGlassListTile(
      onTap: onTap,
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 42,
            height: 42,
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
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Positioned(
            right: -1,
            bottom: -1,
            child: _Dot(online: online, tokens: tokens),
          ),
        ],
      ),
      title: Text(
        name.isNotEmpty ? name : (id.isNotEmpty ? id : 'Сервер'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: tokens.text,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          fontFamily: tokens.fontHeading,
        ),
      ),
      subtitle: Text(
        '${isHost ? 'Вы — хост' : 'Участник'} · ${online ? 'в сети' : 'не в сети'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12.5,
          fontFamily: tokens.fontBody,
          color: tokens.muted,
        ),
      ),
      trailing: Icon(Icons.chevron_right_rounded, color: tokens.muted),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.tokens});
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
        children: [
          Icon(Icons.hub_outlined, size: 40, color: tokens.muted),
          const SizedBox(height: 10),
          Text(
            'Серверов пока нет. Создайте свой или подключитесь по коду.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: tokens.muted,
              fontSize: 13.5,
              height: 1.4,
              fontFamily: tokens.fontBody,
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color, required this.tokens});
  final String label;
  final Color color;
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          fontFamily: tokens.fontBody,
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.online, required this.tokens});
  final bool online;
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    final c = online ? tokens.success : tokens.muted;
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: Border.all(color: tokens.surface, width: 2),
      ),
    );
  }
}

/// Full-bleed translucent barrier with a spinner shown while a create/join is
/// in flight, so the CTA never looks dead during the (up to ~15s) self-host
/// startup and the screen can't be interacted with mid-operation.
class _CreatingOverlay extends StatelessWidget {
  const _CreatingOverlay({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: tokens.bg.withValues(alpha: 0.55),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: tokens.accent),
                const SizedBox(height: 14),
                Text(
                  label,
                  style: TextStyle(
                    color: tokens.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    fontFamily: tokens.fontBody,
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

/// Single-field prompt dialog. Owns its [TextEditingController] so it is
/// disposed only when the dialog widget is removed (after the exit animation) —
/// disposing it eagerly after showDialog returns would crash mid-animation.
class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.hint,
    required this.initial,
    required this.confirm,
    required this.mono,
    this.note,
  });

  final String title;
  final String hint;
  final String initial;
  final String confirm;
  final bool mono;

  /// Optional honest limitation note shown under the input (e.g. that a hosted
  /// room isn't persistent on this platform). Plain text, no promises.
  final String? note;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return AlertDialog(
      backgroundColor: tokens.surface,
      title: Text(widget.title,
          style: TextStyle(fontFamily: tokens.fontHeading, color: tokens.text)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: widget.mono
                ? TextCapitalization.characters
                : TextCapitalization.none,
            style: widget.mono
                ? TextStyle(fontFamily: tokens.fontMono, color: tokens.text)
                : TextStyle(color: tokens.text),
            decoration: InputDecoration(
                hintText: widget.hint, border: const OutlineInputBorder()),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          if (widget.note != null && widget.note!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: tokens.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.note!,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: tokens.muted,
                      fontFamily: tokens.fontBody,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена')),
        TextButton(
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: Text(widget.confirm)),
      ],
    );
  }
}

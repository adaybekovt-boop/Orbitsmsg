// Temporary private "Discord-style" rooms — UI (Phase 3).
//
// Three frosted-glass panels:
//   • server rail (64px)   — DM-home button, one circular icon per room,
//                            a "+" to create/join.
//   • channel panel (220px)— room name, host on/off switch, text-channel list,
//                            "create channel" (host) + "copy invite code".
//   • chat panel (rest)    — the selected text channel's conversation.
//
// On narrow screens the rail + channel panel collapse into a left glass
// Drawer reached from the AppBar hamburger. Voice channels are listed but not
// interactive here (voice mesh UI is a later phase).

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';

import '../peer/room_manager.dart';
import '../peer/room_signaling_host.dart' show canHostSignalingServer;
import '../peer/security_monitor.dart';
import '../state/local_profile_provider.dart';
import '../storage/db.dart' as db;
import '../themes/orbits_tokens.dart';
import '../ui/chat/chat_composer.dart';
import '../ui/chat/image_thumb.dart';
import '../ui/chat/message_bubble.dart';
import '../ui/chat/sticker_picker_sheet.dart';
import '../ui/primitives/adaptive_page_frame.dart';
import '../ui/primitives/orbits_glass_button.dart';
import '../ui/primitives/orbits_glass_app_bar.dart';
import '../ui/primitives/orbits_glass_surface.dart';
import '../ui/primitives/orbits_glass_switch.dart';
import '../ui/room/spatial_audio_canvas.dart';
import '../ui/room/voice_channel_panel.dart';

class RoomChatPage extends ConsumerStatefulWidget {
  const RoomChatPage({super.key, this.initialRoomId});

  /// Open straight into this server (from the Servers section). Null = show the
  /// live session's room (or the empty state).
  final String? initialRoomId;

  @override
  ConsumerState<RoomChatPage> createState() => _RoomChatPageState();
}

class _RoomChatPageState extends ConsumerState<RoomChatPage> {
  /// Room currently shown (defaults to the live session's room).
  String? _viewRoomId;

  /// Channel currently shown (defaults to the first text channel).
  String? _selectedChannelId;

  /// Whether the advanced spatial/radar overlay is open. Pure UI state — the
  /// voice connection lives in RoomManager and is unaffected by this flag.
  bool _radarOpen = false;
  String _radarChannelName = '';

  RoomManager get _rooms => ref.read(roomManagerProvider.notifier);

  /// Captured at initState so [dispose] can stop voice without reading `ref`
  /// after the element is deactivated.
  late final RoomManager _roomsNotifier;

  @override
  void initState() {
    super.initState();
    _roomsNotifier = ref.read(roomManagerProvider.notifier);
    _viewRoomId = widget.initialRoomId;
  }

  @override
  void dispose() {
    // Never leave the mic / voice mesh running when navigating away (item 7).
    _roomsNotifier.leaveVoiceChannel();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  /// Open the shared sticker picker and dispatch the pick as a room sticker.
  Future<void> _openRoomStickerPicker(String roomId, String channelId) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => StickerPickerSheet(
        onPick: (sticker) => _rooms.sendRoomSticker(roomId, channelId, sticker),
      ),
    );
  }

  /// Reentrance guard for the room file picker (a double-tap spawns two native
  /// pickers on Android, which throws on the second).
  bool _roomAttachBusy = false;

  /// Pick a file and send it into [channelId]. Uses `withData: true` so the
  /// bytes arrive in memory (no dart:io path read — keeps this web-safe). For
  /// images we synthesize a small JPEG thumbnail so the bubble shows a preview.
  Future<void> _pickRoomAttachment(String roomId, String channelId) async {
    if (_roomAttachBusy) return;
    _roomAttachBusy = true;
    try {
      FilePickerResult? picked;
      try {
        picked = await FilePicker.platform.pickFiles(
          type: FileType.any,
          allowMultiple: false,
          withData: true,
        );
      } catch (_) {
        _toast('Не удалось открыть файловый выбор');
        return;
      }
      if (picked == null || picked.files.isEmpty) return;
      final pf = picked.files.single;
      final bytes = pf.bytes;
      if (bytes == null || bytes.isEmpty) {
        _toast('Не удалось прочитать файл');
        return;
      }
      if (bytes.length > kMaxRoomFileRawBytes) {
        final mb = (bytes.length / (1024 * 1024)).ceil();
        _toast('Файл больше 12 МБ — отправка невозможна ($mb МБ).');
        return;
      }

      final name = pf.name;
      final mime = lookupMimeType(name) ?? 'application/octet-stream';
      final kind = _classifyFileKind(mime);

      Uint8List? thumbBytes;
      var width = 0;
      var height = 0;
      if (kind == 'image') {
        final t = await buildImageThumb(bytes);
        thumbBytes = t.bytes;
        width = t.width;
        height = t.height;
      }
      if (!mounted) return;

      await _rooms.sendRoomFile(
        roomId,
        channelId,
        bytes,
        name: name,
        mime: mime,
        kind: kind,
        width: width,
        height: height,
        thumbBytes: thumbBytes,
      );
    } finally {
      _roomAttachBusy = false;
    }
  }

  /// MIME → the 4-way attachment kind contract (image|video|audio|file).
  String _classifyFileKind(String mime) {
    final l = mime.toLowerCase();
    if (l.startsWith('image/')) return 'image';
    if (l.startsWith('video/')) return 'video';
    if (l.startsWith('audio/')) return 'audio';
    return 'file';
  }

  /// Confirm + tear down: host destroys the server, guest leaves it. Resets the
  /// view so the page falls back to the rail/empty state (audit item 7).
  Future<void> _leaveOrDestroy(bool isHost) async {
    final tokens = OrbitsTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: tokens.surface,
        title: Text(
          isHost ? 'Завершить сервер?' : 'Выйти из сервера?',
          style: TextStyle(fontFamily: tokens.fontHeading, color: tokens.text),
        ),
        content: Text(
          isHost
              ? 'Сервер станет недоступен для участников. Историю можно будет '
                  'просматривать офлайн.'
              : 'Вы покинете сервер. Вернуться можно по коду приглашения.',
          style: TextStyle(fontFamily: tokens.fontBody, color: tokens.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              isHost ? 'Завершить' : 'Выйти',
              style: TextStyle(color: tokens.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _rooms.leaveOrDestroyRoom();
    if (!mounted) return;
    setState(() {
      _viewRoomId = null;
      _selectedChannelId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final roomState = ref.watch(roomManagerProvider);
    // Surface a join failure/rejection (full / offline / invalid / timeout) once.
    ref.listen<RoomState>(roomManagerProvider, (prev, next) {
      final err = next.joinError;
      if (err != null && err != prev?.joinError) {
        _toast(err);
        _rooms.clearJoinError();
      }
    });
    final viewRoomId = _viewRoomId ?? roomState.roomId;
    final desktop = isDesktopLayout(context);

    return StreamBuilder<List<Map<String, Object?>>>(
      stream: db.watchRooms(),
      builder: (context, roomsSnap) {
        final rooms = roomsSnap.data ?? const <Map<String, Object?>>[];
        final viewRoom = _roomById(rooms, viewRoomId);
        final isHostOfView = roomState.role == RoomRole.host &&
            roomState.roomId == viewRoomId &&
            viewRoomId != null;

        final rail = _ServerRail(
          rooms: rooms,
          activeRoomId: viewRoomId,
          onSelectRoom: (id) => setState(() {
            _viewRoomId = id;
            _selectedChannelId = null;
          }),
          onHome: () => Navigator.of(context).maybePop(),
          onAdd: _openCreateJoin,
        );

        final channelPanel = _ChannelPanel(
          room: viewRoom,
          roomId: viewRoomId,
          isHost: isHostOfView,
          selectedChannelId: _selectedChannelId,
          onSelectChannel: (id) {
            setState(() {
              _selectedChannelId = id;
              _radarOpen = false; // switching channels closes the radar
            });
            // Entering a voice channel builds the audio mesh; entering a text
            // channel tears it down. switchChannel resolves the type from the
            // DB and is a no-op unless this is the live session's room.
            if (viewRoomId == roomState.roomId) {
              _rooms.switchChannel(id);
            }
          },
          onToggleActive: (v) => _rooms.setServerActive(v),
          onCreateChannel: _openCreateChannel,
          onCopyInvite: () {
            // For the live self-hosted server, share the full `orbits-room:`
            // invite (carries the embedded server's address); otherwise fall
            // back to the room code.
            final invite = (roomState.roomId == viewRoomId
                    ? roomState.selfHostInvite
                    : null) ??
                viewRoomId;
            if (invite == null) return;
            Clipboard.setData(ClipboardData(text: invite));
            _toast('Код приглашения скопирован');
          },
          // Only the live session's room can be left/destroyed; a view-only
          // (offline/foreign) room has no live membership to tear down.
          isLive: roomState.roomId == viewRoomId &&
              roomState.role != RoomRole.none,
          onLeaveOrDestroy: () => _leaveOrDestroy(isHostOfView),
        );

        if (desktop) {
          return _wrapRadar(viewRoomId, roomState, desktop, Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Row(
                children: [
                  SizedBox(width: 64, child: rail),
                  SizedBox(width: 220, child: channelPanel),
                  Expanded(
                    child: _chatArea(
                      viewRoomId: viewRoomId,
                      roomState: roomState,
                      showHeader: true,
                    ),
                  ),
                ],
              ),
            ),
          ));
        }

        // Mobile: rail + channels live in a glass drawer.
        return _wrapRadar(viewRoomId, roomState, desktop, Scaffold(
          backgroundColor: Colors.transparent,
          appBar: OrbitsGlassAppBar(
            iconTheme: IconThemeData(color: OrbitsTokens.of(context).text),
            title: Text(
              _headerTitle(viewRoom),
              style: TextStyle(
                fontFamily: OrbitsTokens.of(context).fontHeading,
                fontWeight: FontWeight.w600,
                color: OrbitsTokens.of(context).text,
              ),
            ),
          ),
          drawer: Drawer(
            backgroundColor: Colors.transparent,
            width: 300,
            child: OrbitsGlassSurface(
              role: OrbitsGlassRole.sidebar,
              child: SafeArea(
                child: Row(
                  children: [
                    SizedBox(width: 64, child: rail),
                    Expanded(child: channelPanel),
                  ],
                ),
              ),
            ),
          ),
          body: _chatArea(
            viewRoomId: viewRoomId,
            roomState: roomState,
            showHeader: false,
          ),
        ));
      },
    );
  }

  /// Overlay the spatial/radar modal on top of [scaffold] when it's open AND we
  /// actually hold a voice session. Tied to voice state so leaving voice (which
  /// clears `voiceChannelId`) hides the radar automatically.
  Widget _wrapRadar(
      String? viewRoomId, RoomState roomState, bool desktop, Widget scaffold) {
    final showRadar = _radarOpen &&
        roomState.voiceChannelId != null &&
        viewRoomId != null &&
        roomState.roomId == viewRoomId;
    if (!showRadar) return scaffold;
    return Stack(
      children: [scaffold, _radarOverlay(viewRoomId, desktop)],
    );
  }

  /// The advanced 3D/spatial radar, shown as a scrimmed modal overlay. Closing
  /// it only flips UI state — it never touches the voice connection.
  Widget _radarOverlay(String roomId, bool desktop) {
    final tokens = OrbitsTokens.of(context);
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.6),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(desktop ? 40 : 10),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(Icons.blur_on_rounded,
                            size: 18, color: tokens.accent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '3D-звук',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              fontFamily: tokens.fontHeading,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded,
                              color: Colors.white),
                          tooltip: 'Закрыть',
                          onPressed: () => setState(() => _radarOpen = false),
                        ),
                      ],
                    ),
                    Expanded(
                      child: SpatialAudioCanvas(
                        roomId: roomId,
                        channelName: _radarChannelName,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Disconnect from voice (Discord-style: drop back into the text channel) and
  /// close the radar. [textChannelId] is the channel to land on, or null.
  void _leaveVoice(String? textChannelId) {
    setState(() {
      _radarOpen = false;
      _selectedChannelId = textChannelId;
    });
    if (textChannelId != null) {
      _rooms.switchChannel(textChannelId); // switches off voice → text
    } else {
      _rooms.leaveVoiceChannel();
    }
  }

  String _headerTitle(Map<String, Object?>? room) {
    if (room == null) return 'Серверы';
    final name = (room['name'] as String?)?.trim() ?? '';
    return name.isNotEmpty ? name : 'Сервер';
  }

  // ─── Chat area (messages + composer) ───────────────────────────────

  Widget _chatArea({
    required String? viewRoomId,
    required RoomState roomState,
    required bool showHeader,
  }) {
    final alert =
        roomState.roomId == viewRoomId ? roomState.securityAlert : null;
    if (alert == null) {
      return _chatBody(
        viewRoomId: viewRoomId,
        roomState: roomState,
        showHeader: showHeader,
      );
    }
    // Fraud detector raised a warning → red glass banner above the chat.
    return Column(
      children: [
        _SecurityBanner(
          message: alert,
          onDismiss: () => _rooms.clearSecurityAlert(),
        ),
        Expanded(
          child: _chatBody(
            viewRoomId: viewRoomId,
            roomState: roomState,
            showHeader: showHeader,
          ),
        ),
      ],
    );
  }

  Widget _chatBody({
    required String? viewRoomId,
    required RoomState roomState,
    required bool showHeader,
  }) {
    final tokens = OrbitsTokens.of(context);
    if (viewRoomId == null) {
      return _emptyState();
    }

    // Sending only works for the live session's room (a non-active room is
    // view-only history).
    final liveForView =
        roomState.roomId == viewRoomId && roomState.role != RoomRole.none;
    final hostPeerId = roomState.hostPeerId;

    return StreamBuilder<List<Map<String, Object?>>>(
      stream: db.watchChannels(viewRoomId),
      builder: (context, chSnap) {
        final channels = chSnap.data ?? const <Map<String, Object?>>[];

        // A voice channel is selected → show the compact voice panel (NOT the
        // radar). The radar is an opt-in overlay opened from the panel.
        final selectedChannel = _channelById(channels, _selectedChannelId);
        if (selectedChannel != null && selectedChannel['type'] == 'voice') {
          final voiceName = (selectedChannel['name'] as String?) ?? '';
          final firstText = channels.firstWhere(
            (c) => c['type'] == 'text',
            orElse: () => const <String, Object?>{},
          )['id'] as String?;
          return VoiceChannelPanel(
            roomId: viewRoomId,
            channelId: (selectedChannel['id'] as String?) ?? '',
            channelName: voiceName,
            onOpenSpatial: () => setState(() {
              _radarOpen = true;
              _radarChannelName = voiceName;
            }),
            onLeaveVoice: () => _leaveVoice(firstText),
          );
        }

        final textChannels =
            channels.where((c) => c['type'] == 'text').toList();
        final effectiveChannelId = _selectedChannelId ??
            (textChannels.isNotEmpty ? textChannels.first['id'] as String? : null);
        final channelName = _channelName(channels, effectiveChannelId);

        return Column(
          children: [
            if (showHeader && effectiveChannelId != null)
              _channelHeader(channelName),
            Expanded(
              child: effectiveChannelId == null
                  ? Center(
                      child: Text(
                        'Выберите канал',
                        style: TextStyle(
                          color: tokens.muted,
                          fontFamily: tokens.fontBody,
                        ),
                      ),
                    )
                  : _MessageList(
                      channelId: effectiveChannelId,
                      hostPeerId: hostPeerId,
                    ),
            ),
            if (effectiveChannelId != null)
              liveForView
                  ? ChatComposer(
                      actions: ComposerActions(
                        onSend: (text) async {
                          await _rooms.sendRoomMessage(
                              viewRoomId, effectiveChannelId, text);
                          return true;
                        },
                        onTypingChanged: (_) {},
                        onOpenStickerPicker: () => _openRoomStickerPicker(
                            viewRoomId, effectiveChannelId),
                        onPickAttachment: () =>
                            _pickRoomAttachment(viewRoomId, effectiveChannelId),
                      ),
                    )
                  : _inactiveComposerBanner(),
          ],
        );
      },
    );
  }

  Widget _channelHeader(String name) {
    final tokens = OrbitsTokens.of(context);
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.appBar,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text('#', style: TextStyle(color: tokens.muted, fontSize: 18)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    fontFamily: tokens.fontHeading,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inactiveComposerBanner() {
    final tokens = OrbitsTokens.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Text(
          'Сервер не активен — переписку можно только просматривать.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: tokens.muted,
            fontSize: 12.5,
            fontFamily: tokens.fontBody,
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    final tokens = OrbitsTokens.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.dns_outlined, size: 44, color: tokens.muted),
              const SizedBox(height: 14),
              Text(
                'Пока нет серверов',
                style: TextStyle(
                  fontFamily: tokens.fontHeading,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: tokens.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Создайте свой сервер или подключитесь к чужому по коду '
                'приглашения.',
                textAlign: TextAlign.center,
                style: TextStyle(color: tokens.muted, fontFamily: tokens.fontBody),
              ),
              const SizedBox(height: 20),
              OrbitsGlassButton(
                label: 'Создать или войти',
                icon: Icons.add,
                variant: OrbitsGlassVariant.primary,
                onPressed: _openCreateJoin,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Sheets / prompts ──────────────────────────────────────────────

  Future<void> _openCreateJoin() async {
    final myName = ref.read(localProfileProvider)?.displayName ?? '';
    final result = await showModalBottomSheet<_JoinOrCreate>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CreateJoinSheet(defaultName: myName),
    );
    if (result == null) return;
    if (result.isCreate) {
      // Match ServersHomePage: on desktop host our own signaling server; on
      // web/mobile fall back to a cloud (peerjs.com) room.
      await _rooms.createRoom(result.value,
          selfHosted: canHostSignalingServer);
    } else {
      await _rooms.joinRoom(result.value, myName);
    }
    if (!mounted) return;
    final st = ref.read(roomManagerProvider);
    if (st.joinError != null) {
      _toast(st.joinError!);
      _rooms.clearJoinError();
      return;
    }
    setState(() {
      _viewRoomId = st.roomId;
      _selectedChannelId = null;
    });
  }

  Future<void> _openCreateChannel() async {
    final name = await _promptText('Новый канал', 'например, feedback');
    if (name == null || name.trim().isEmpty) return;
    await _rooms.createChannelAndAnnounce(name.trim());
  }

  Future<String?> _promptText(String title, String hint) async {
    final controller = TextEditingController();
    final tokens = OrbitsTokens.of(context);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: tokens.surface,
        title: Text(title, style: TextStyle(fontFamily: tokens.fontHeading)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  // ─── Helpers ───────────────────────────────────────────────────────

  Map<String, Object?>? _roomById(
      List<Map<String, Object?>> rooms, String? id) {
    if (id == null) return null;
    for (final r in rooms) {
      if (r['id'] == id) return r;
    }
    return null;
  }

  String _channelName(List<Map<String, Object?>> channels, String? id) {
    if (id == null) return '';
    for (final c in channels) {
      if (c['id'] == id) return (c['name'] as String?) ?? '';
    }
    return '';
  }

  Map<String, Object?>? _channelById(
      List<Map<String, Object?>> channels, String? id) {
    if (id == null) return null;
    for (final c in channels) {
      if (c['id'] == id) return c;
    }
    return null;
  }
}

// ─── Server rail (64px) ───────────────────────────────────────────────

class _ServerRail extends StatelessWidget {
  const _ServerRail({
    required this.rooms,
    required this.activeRoomId,
    required this.onSelectRoom,
    required this.onHome,
    required this.onAdd,
  });

  final List<Map<String, Object?>> rooms;
  final String? activeRoomId;
  final ValueChanged<String> onSelectRoom;
  final VoidCallback onHome;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.sidebar,
      child: Column(
        children: [
          const SizedBox(height: 10),
          _RailButton(
            tooltip: 'Личные чаты',
            onTap: onHome,
            child: Icon(Icons.forum_rounded, color: tokens.text, size: 22),
          ),
          Divider(
            indent: 14,
            endIndent: 14,
            color: tokens.muted.withValues(alpha: 0.3),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: rooms.length,
              itemBuilder: (context, i) {
                final r = rooms[i];
                final id = (r['id'] as String?) ?? '';
                final name = (r['name'] as String?) ?? '';
                final active = id == activeRoomId;
                final offline = (r['status'] as String?) == 'offline';
                return _RailButton(
                  tooltip: name.isNotEmpty ? name : id,
                  onTap: () => onSelectRoom(id),
                  selected: active,
                  child: _RoomGlyph(
                    name: name,
                    offline: offline,
                    selected: active,
                  ),
                );
              },
            ),
          ),
          _RailButton(
            tooltip: 'Создать или войти',
            onTap: onAdd,
            child: Icon(Icons.add, color: tokens.accent, size: 24),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.child,
    required this.onTap,
    required this.tooltip,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback onTap;
  final String tooltip;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: selected
                    ? Border.all(color: tokens.accent, width: 2)
                    : null,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _RoomGlyph extends StatelessWidget {
  const _RoomGlyph({
    required this.name,
    required this.offline,
    required this.selected,
  });

  final String name;
  final bool offline;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final initial =
        name.trim().isNotEmpty ? name.trim().characters.first.toUpperCase() : '#';
    return Opacity(
      opacity: offline ? 0.45 : 1.0,
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: tokens.accentAlpha(selected ? 0.22 : 0.14),
          border: Border.all(color: tokens.accentAlpha(0.22)),
        ),
        child: Text(
          initial,
          style: TextStyle(
            color: tokens.text,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontFamily: tokens.fontHeading,
          ),
        ),
      ),
    );
  }
}

// ─── Channel panel (220px) ────────────────────────────────────────────

class _ChannelPanel extends StatelessWidget {
  const _ChannelPanel({
    required this.room,
    required this.roomId,
    required this.isHost,
    required this.selectedChannelId,
    required this.onSelectChannel,
    required this.onToggleActive,
    required this.onCreateChannel,
    required this.onCopyInvite,
    required this.isLive,
    required this.onLeaveOrDestroy,
  });

  final Map<String, Object?>? room;
  final String? roomId;
  final bool isHost;
  final String? selectedChannelId;
  final ValueChanged<String> onSelectChannel;
  final ValueChanged<bool> onToggleActive;
  final VoidCallback onCreateChannel;
  final VoidCallback onCopyInvite;

  /// True when this is the live session's room (so leaving/destroying applies).
  final bool isLive;
  final VoidCallback onLeaveOrDestroy;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final name = (room?['name'] as String?)?.trim() ?? '';
    final isActive = (room?['status'] as String?) != 'offline';

    return OrbitsGlassSurface(
      role: OrbitsGlassRole.sidebar,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Room title + host on/off switch.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      name.isNotEmpty ? name : (roomId ?? 'Сервер'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tokens.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        fontFamily: tokens.fontHeading,
                      ),
                    ),
                  ),
                  if (isHost)
                    OrbitsGlassSwitch(
                      value: isActive,
                      size: OrbitsGlassSwitchSize.compact,
                      semanticLabel: 'Сервер включён',
                      onChanged: onToggleActive,
                    ),
                ],
              ),
            ),
            if (isHost)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  isActive ? 'В сети' : 'Не в сети',
                  style: TextStyle(
                    color: isActive ? tokens.success : tokens.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFamily: tokens.fontBody,
                  ),
                ),
              ),
            Divider(
              color: tokens.muted.withValues(alpha: 0.25),
              height: 1,
            ),
            // Channel list.
            Expanded(
              child: roomId == null
                  ? const SizedBox.shrink()
                  : StreamBuilder<List<Map<String, Object?>>>(
                      stream: db.watchChannels(roomId!),
                      builder: (context, snap) {
                        final channels =
                            snap.data ?? const <Map<String, Object?>>[];
                        if (channels.isEmpty) {
                          return Center(
                            child: Text(
                              'Нет каналов',
                              style: TextStyle(
                                color: tokens.muted,
                                fontSize: 12,
                                fontFamily: tokens.fontBody,
                              ),
                            ),
                          );
                        }
                        return ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          itemCount: channels.length,
                          itemBuilder: (context, i) {
                            final c = channels[i];
                            final id = (c['id'] as String?) ?? '';
                            final cname = (c['name'] as String?) ?? '';
                            final isVoice = c['type'] == 'voice';
                            return _ChannelRow(
                              name: cname,
                              isVoice: isVoice,
                              selected: id == selectedChannelId,
                              onTap: () => onSelectChannel(id),
                            );
                          },
                        );
                      },
                    ),
            ),
            // Host actions + invite.
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: Column(
                children: [
                  if (isHost)
                    OrbitsGlassButton(
                      label: 'Создать канал',
                      icon: Icons.add,
                      variant: OrbitsGlassVariant.subtle,
                      size: OrbitsGlassSize.small,
                      expand: true,
                      onPressed: onCreateChannel,
                    ),
                  if (isHost) const SizedBox(height: 6),
                  OrbitsGlassButton(
                    label: 'Скопировать код',
                    icon: Icons.copy,
                    variant: OrbitsGlassVariant.subtle,
                    size: OrbitsGlassSize.small,
                    expand: true,
                    onPressed: roomId == null ? null : onCopyInvite,
                  ),
                  if (isLive) ...[
                    const SizedBox(height: 6),
                    OrbitsGlassButton(
                      label: isHost ? 'Завершить сервер' : 'Выйти из сервера',
                      icon: isHost
                          ? Icons.power_settings_new_rounded
                          : Icons.logout_rounded,
                      variant: OrbitsGlassVariant.danger,
                      size: OrbitsGlassSize.small,
                      expand: true,
                      onPressed: onLeaveOrDestroy,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelRow extends StatelessWidget {
  const _ChannelRow({
    required this.name,
    required this.isVoice,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool isVoice;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final fg = selected ? tokens.text : tokens.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? tokens.accentAlpha(0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Opacity(
            opacity: isVoice && !selected ? 0.82 : 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Text(
                    isVoice ? '🔊' : '#',
                    style: TextStyle(color: fg, fontSize: 14),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontSize: 14,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        fontFamily: tokens.fontBody,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Message list (per-channel, sender-clustered) ─────────────────────

class _MessageList extends StatelessWidget {
  const _MessageList({required this.channelId, required this.hostPeerId});

  final String channelId;
  final String? hostPeerId;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    // Outer stream: contacts' trustLevels → per-sender verification badge.
    return StreamBuilder<List<Map<String, Object?>>>(
      stream: db.watchAllPeers(),
      builder: (context, peersSnap) {
        final trustByPeer = <String, int>{
          for (final p in (peersSnap.data ?? const <Map<String, Object?>>[]))
            if (p['id'] is String)
              (p['id'] as String): ((p['trustLevel'] as num?)?.toInt() ?? 0),
        };
        return StreamBuilder<List<Map<String, Object?>>>(
          stream: db.watchChannelMessages(channelId),
          builder: (context, snap) {
            final rows = snap.data ?? const <Map<String, Object?>>[];
            if (rows.isEmpty) {
              return Center(
                child: Text(
                  'Нет сообщений',
                  style: TextStyle(
                      color: tokens.muted, fontFamily: tokens.fontBody),
                ),
              );
            }
            return ListView.builder(
              reverse: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: rows.length,
              itemBuilder: (context, i) {
                // rows are oldest-first; render newest at the bottom (reverse).
                final k = rows.length - 1 - i;
                final row = rows[k];
                final prev = k > 0 ? rows[k - 1] : null;
                final next = k < rows.length - 1 ? rows[k + 1] : null;
                // Room clustering is by SENDER (peerId), not direction — many
                // guests all arrive as 'in', so direction-based grouping would
                // wrongly merge different people.
                final groupedWithPrevious =
                    prev != null && _sameRoomCluster(prev, row);
                final isTail = next == null || !_sameRoomCluster(row, next);
                return MessageBubble(
                  row: row,
                  hostPeerId: hostPeerId,
                  senderVerification: verificationFromTrustLevel(
                      trustByPeer[row['peerId'] as String?]),
                  groupedWithPrevious: groupedWithPrevious,
                  isTail: isTail,
                );
              },
            );
          },
        );
      },
    );
  }
}

bool _sameRoomCluster(Map<String, Object?> a, Map<String, Object?> b) {
  if ((a['peerId'] as String?) != (b['peerId'] as String?)) return false;
  final ta = (a['timestamp'] as num?)?.toInt() ?? 0;
  final tb = (b['timestamp'] as num?)?.toInt() ?? 0;
  return (tb - ta).abs() < 180000;
}

/// Bright red glass warning banner at the top of the chat — raised by the fraud
/// detector on a suspicious connection (IP collision / IP hop).
class _SecurityBanner extends StatelessWidget {
  const _SecurityBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      child: OrbitsGlassSurface(
        role: OrbitsGlassRole.card,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: tokens.danger.withValues(alpha: 0.16),
            border: Border.all(color: tokens.danger.withValues(alpha: 0.5)),
          ),
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          child: Row(
            children: [
              Icon(Icons.gpp_maybe_rounded, color: tokens.danger, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    color: tokens.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                    fontFamily: tokens.fontBody,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.close_rounded, size: 18, color: tokens.muted),
                onPressed: onDismiss,
                tooltip: 'Скрыть',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Create / join sheet ──────────────────────────────────────────────

/// Result of the create/join sheet. [isCreate] ? room name : invite code.
class _JoinOrCreate {
  const _JoinOrCreate(this.isCreate, this.value);
  final bool isCreate;
  final String value;
}

class _CreateJoinSheet extends StatefulWidget {
  const _CreateJoinSheet({required this.defaultName});
  final String defaultName;

  @override
  State<_CreateJoinSheet> createState() => _CreateJoinSheetState();
}

class _CreateJoinSheetState extends State<_CreateJoinSheet> {
  late final TextEditingController _nameCtl;
  final TextEditingController _codeCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(
      text: widget.defaultName.isNotEmpty
          ? '${widget.defaultName}: сервер'
          : '',
    );
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _codeCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.sheet,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              24, 16, 24, 16 + MediaQuery.of(context).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: tokens.muted.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              _label('Создать сервер', tokens),
              const SizedBox(height: 8),
              TextField(
                controller: _nameCtl,
                decoration: const InputDecoration(
                  hintText: 'Название сервера',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              OrbitsGlassButton(
                label: 'Создать',
                icon: Icons.add,
                variant: OrbitsGlassVariant.primary,
                expand: true,
                onPressed: () {
                  final v = _nameCtl.text.trim();
                  if (v.isEmpty) return;
                  Navigator.of(context).pop(_JoinOrCreate(true, v));
                },
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(child: Divider(color: tokens.muted.withValues(alpha: 0.3))),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text('или',
                        style: TextStyle(
                            color: tokens.muted, fontFamily: tokens.fontBody)),
                  ),
                  Expanded(child: Divider(color: tokens.muted.withValues(alpha: 0.3))),
                ],
              ),
              const SizedBox(height: 16),
              _label('Подключиться по коду', tokens),
              const SizedBox(height: 8),
              TextField(
                controller: _codeCtl,
                textCapitalization: TextCapitalization.characters,
                style: TextStyle(fontFamily: tokens.fontMono, color: tokens.text),
                decoration: const InputDecoration(
                  hintText: 'ORBIT-XXXXXX',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              OrbitsGlassButton(
                label: 'Подключиться',
                icon: Icons.login,
                variant: OrbitsGlassVariant.secondary,
                expand: true,
                onPressed: () {
                  final v = _codeCtl.text.trim();
                  if (v.isEmpty) return;
                  Navigator.of(context).pop(_JoinOrCreate(false, v));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text, OrbitsTokens tokens) => Text(
        text.toUpperCase(),
        style: TextStyle(
          fontFamily: tokens.fontHeading,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: tokens.muted,
        ),
      );
}

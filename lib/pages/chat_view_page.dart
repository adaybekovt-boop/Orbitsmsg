// Chat detail screen — the right-side "ChatView" of `src/pages/Chats.jsx`.
//
// Renders the reactive message timeline for a single peer, plus the
// composer. Sticker/voice/attachment entry points are disabled stubs
// today (Day 4 wires them up). Chat settings sheet, reply preview, edit
// mode, and per-chat pin management come on Day 2.
//
// State flow:
//  • `messagesForPeerProvider(peerId)` streams the Drift rows.
//  • `typingForPeerProvider(peerId)` flags the floating "typing…" bubble.
//  • `connectedPeerIdsProvider` drives the online dot in the header.
//  • Sending goes through `messagingNotifierProvider.notifier.sendText`.
//
// The page watches the messages list and auto-scrolls to bottom when a
// new row arrives — but only if the user is already near the bottom.
// If they've scrolled up to read history we respect that and append
// silently, matching the web UX.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:mime/mime.dart';

import '../state/calls_provider.dart';
import '../state/connections_notifier.dart';
import '../state/messages_provider.dart';
import '../state/messaging_notifier.dart';
import '../state/peers_provider.dart';
import '../state/strict_verify_provider.dart';
import '../storage/db.dart' as db;
import '../themes/orbits_tokens.dart';
import '../ui/chat/chat_composer.dart';
import '../ui/chat/chat_settings_sheet.dart';
import '../ui/chat/message_bubble.dart';
import '../ui/chat/sticker_picker_sheet.dart';
import '../ui/chat/typing_indicator.dart';
import '../ui/chat/voice_recorder_sheet.dart';
import '../ui/primitives/orbits_glass_button.dart';
import '../ui/primitives/orbits_glass_app_bar.dart';
import '../ui/primitives/orbits_glass_surface.dart';

class ChatViewPage extends ConsumerStatefulWidget {
  const ChatViewPage({super.key, required this.peerId});

  /// Remote peer id in canonical form (already upper-cased). The caller
  /// is expected to pass a normalised id; the page re-normalises defensively.
  final String peerId;

  @override
  ConsumerState<ChatViewPage> createState() => _ChatViewPageState();
}

class _ChatViewPageState extends ConsumerState<ChatViewPage> {
  final ScrollController _scrollCtl = ScrollController();

  /// True iff we believe the user is pinned to the bottom of the list. We
  /// flip this to false the moment they scroll up past the threshold so
  /// auto-scroll won't yank them back.
  bool _stickToBottom = true;

  /// Tracks the previous message count across rebuilds so we can tell
  /// "new message arrived" apart from "list reordered in place" (Drift
  /// can re-emit the same list length if a row's status updates).
  int _lastCount = 0;

  /// Newest inbound timestamp we've already pushed through `markChatRead`.
  /// The page is "in focus" for its whole lifetime, so any inbound row
  /// newer than this must clear the unread badge immediately. We track it
  /// locally (rather than re-reading `peer.lastReadAt` each build) so we
  /// don't fight Drift's own async emission cadence.
  int _lastMarkedReadTs = 0;

  /// Currently-pinned reply target. A raw Drift row — we stamp it whole
  /// (plus a resolved `fromName`) into the outbound payload on send. Null
  /// when the user isn't replying to anything. The composer reads a
  /// projection of this via [ComposerReplyPreview].
  Map<String, Object?>? _replyTo;

  static const double _stickThresholdPx = 140;

  @override
  void initState() {
    super.initState();
    _scrollCtl.addListener(_onScroll);
    // Kick a reliable-channel dial on mount so the "в сети" dot turns
    // green and the first message goes out immediately rather than
    // sitting in the outbox until the next manual action. `openReliable`
    // is idempotent — if a channel is already open it's a no-op.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(connectionsNotifierProvider.notifier)
          .openReliable(widget.peerId);
    });
    // The user opened the chat → everything up to *now* counts as read.
    // Stamping on mount ensures the badge clears even if no new inbound
    // ever arrives (classic "check messages, nothing new" case). Writes
    // are fire-and-forget — UI blocking on a SQLite insert would add
    // latency for no gain.
    _lastMarkedReadTs = DateTime.now().millisecondsSinceEpoch;
    unawaited(db.markChatRead(widget.peerId, at: _lastMarkedReadTs));
  }

  @override
  void dispose() {
    _scrollCtl.removeListener(_onScroll);
    _scrollCtl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtl.hasClients) return;
    // With `reverse: true` the "bottom" (latest message) sits at offset 0,
    // and scrolling up into history increases the offset. Below the
    // threshold counts as "still reading the latest".
    final atBottom = _scrollCtl.offset <= _stickThresholdPx;
    if (atBottom != _stickToBottom) {
      _stickToBottom = atBottom;
    }
  }

  void _maybeStickToBottom() {
    if (!_stickToBottom) return;
    // Defer to after the build so the ListView has a chance to mount the
    // new row before we animate. `jumpTo(0)` is cheap on a reversed list:
    // it just pins to the newest row without a scroll animation stutter.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtl.hasClients) return;
      _scrollCtl.jumpTo(0);
    });
  }

  Future<bool> _handleSend(String text) async {
    final notifier = ref.read(messagingNotifierProvider.notifier);
    final reply = _consumeReplyTarget();
    final id = await notifier.sendText(
      widget.peerId,
      text,
      replyTo: reply,
    );
    // Null id = validation failure (empty, too long, invalid peer).
    // On failure we restore the reply target so the user can fix and
    // resend without re-picking the quoted bubble — but *only* if the
    // user hasn't set a new reply target in the meantime. Without this
    // guard a slow failing send would stomp the user's fresh pick (they
    // long-pressed a different bubble while the network spun), which
    // looked like the pill ghost-flipping.
    if (id == null && reply != null && mounted && _replyTo == null) {
      setState(() => _replyTo = _restoreReplyRowFromPayload(reply));
    }
    return id != null;
  }

  void _handleTyping(bool isTyping) {
    // `sendTyping` is a fire-and-forget ephemeral packet; we don't want
    // to block the composer's keystroke path on its resolution. `unawaited`
    // signals that intent to linters while keeping the Future alive.
    unawaited(
      ref
          .read(messagingNotifierProvider.notifier)
          .sendTyping(widget.peerId, isTyping),
    );
  }

  Future<void> _openStickerPicker() async {
    // Sheet returns after pop via its own onPick; we don't wait for the
    // future ourselves. Dismissing without a pick is a no-op.
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => StickerPickerSheet(
        onPick: _handleStickerPick,
      ),
    );
  }

  Future<void> _handleStickerPick(Map<String, Object?> sticker) async {
    final notifier = ref.read(messagingNotifierProvider.notifier);
    final reply = _consumeReplyTarget();
    final id = await notifier.sendSticker(
      widget.peerId,
      sticker,
      replyTo: reply,
    );
    if (!mounted) return;
    if (id == null) {
      // Blocked peer, invalid sticker payload, or oversized url. The
      // sticker sheet is already gone so the user has no context for why
      // nothing happened — surface a toast so we don't silently drop the
      // tap. Same message class for all failure modes; details would leak
      // implementation.
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Не удалось отправить стикер'),
            duration: Duration(seconds: 2),
          ),
        );
      if (reply != null && _replyTo == null) {
        // Same "don't stomp the user's newer pick" guard as text sends.
        setState(() => _replyTo = _restoreReplyRowFromPayload(reply));
      }
    }
  }

  /// Opens the voice recorder modal. Its onSend callback fires after the
  /// sheet pops, so by the time we dispatch `sendVoice` the user is back
  /// at the message list. Matches the pattern used by the sticker sheet.
  Future<void> _openVoiceRecorder() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      // Sheet takes ~260dp — not worth the drag handle, and the
      // cancel/send buttons are self-explanatory.
      builder: (ctx) => VoiceRecorderSheet(
        onSend: _handleVoiceSend,
      ),
    );
  }

  Future<void> _handleVoiceSend(VoiceRecordResult result) async {
    final notifier = ref.read(messagingNotifierProvider.notifier);
    final reply = _consumeReplyTarget();
    final id = await notifier.sendVoice(
      widget.peerId,
      result.bytes,
      mime: result.mime,
      durationSec: result.durationSec,
      waveform: result.waveform,
      replyTo: reply,
    );
    if (!mounted) return;
    if (id == null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Не удалось отправить голосовое сообщение'),
            duration: Duration(seconds: 2),
          ),
        );
      if (reply != null && _replyTo == null) {
        setState(() => _replyTo = _restoreReplyRowFromPayload(reply));
      }
    }
  }

  /// Reentrance guard for the file picker — a double-tap on the
  /// paperclip spawns two `pickFiles` on Android which throws "Unable
  /// to establish connection on channel" on the second call.
  bool _attachmentBusy = false;

  /// Pops the native file picker, then dispatches `sendFile`. Kind is
  /// derived from the MIME. For images we synthesize a small JPEG
  /// thumbnail via the `image` package before send so the peer's
  /// bubble renders a preview instantly — matches the JS peer's
  /// `buildAttachmentPreview` behaviour. Video thumbnail generation
  /// needs `video_thumbnail` (deferred to Day 5+).
  Future<void> _pickAttachment() async {
    if (_attachmentBusy) return;
    _attachmentBusy = true;
    try {
      await _runAttachmentPick();
    } finally {
      _attachmentBusy = false;
    }
  }

  Future<void> _runAttachmentPick() async {
    FilePickerResult? picked;
    try {
      // `withData: true` pulls bytes into memory up front. Worst case
      // is 12 MiB (our hard cap), which is fine to hold transiently;
      // it avoids a race where iOS sweeps the picker-cached file
      // between `pickFiles` resolving and our `readAsBytes` call.
      picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Не удалось открыть файловый выбор'),
            duration: Duration(seconds: 2),
          ),
        );
      return;
    }
    if (picked == null || picked.files.isEmpty) return;
    final pf = picked.files.single;
    Uint8List? bytes = pf.bytes;
    // Some Android configurations still only return a path (no bytes),
    // despite `withData: true`. Fall back to reading the path.
    if ((bytes == null || bytes.isEmpty) && pf.path != null) {
      try {
        bytes = await File(pf.path!).readAsBytes();
      } catch (_) {
        bytes = null;
      }
    }
    if (bytes == null || bytes.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('Не удалось прочитать файл')),
        );
      return;
    }
    // 12 MiB raw cap — match the JS front gate so the user sees the
    // error before we burn time encoding base64 to learn the same
    // thing on the wire side.
    const int maxRaw = 12 * 1024 * 1024;
    if (bytes.length > maxRaw) {
      if (!mounted) return;
      final mb = (bytes.length / (1024 * 1024)).ceil();
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Файл больше 12 МБ — отправка невозможна ($mb МБ).',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      return;
    }

    final name = pf.name;
    // `file_picker` doesn't always set `extension`; fall back to `mime`
    // package which sniffs by filename (enough for the kind classifier —
    // content-sniffing would require reading the bytes again).
    final mime = lookupMimeType(name) ?? 'application/octet-stream';
    final kind = _classifyKind(mime);

    // For images, synthesise a JPEG thumbnail so the peer's bubble
    // renders a preview instantly (before the full b64 lands). Matches
    // the JS peer's `buildAttachmentPreview` contract. Decoding the
    // image can be expensive for multi-MB JPEGs — we run it off the
    // main thread to avoid jank in the composer.
    Uint8List? thumbBytes;
    int width = 0;
    int height = 0;
    if (kind == 'image') {
      final t = await _buildImageThumb(bytes);
      thumbBytes = t.bytes;
      width = t.width;
      height = t.height;
    }

    final notifier = ref.read(messagingNotifierProvider.notifier);
    final reply = _consumeReplyTarget();
    final id = await notifier.sendFile(
      widget.peerId,
      bytes,
      name: name,
      mime: mime,
      kind: kind,
      width: width,
      height: height,
      thumbBytes: thumbBytes,
      replyTo: reply,
    );
    if (!mounted) return;
    if (id == null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Не удалось отправить файл'),
            duration: Duration(seconds: 2),
          ),
        );
      if (reply != null && _replyTo == null) {
        setState(() => _replyTo = _restoreReplyRowFromPayload(reply));
      }
    }
  }

  /// Coerce a MIME type to the 4-way `kind` contract the JS peer uses
  /// (`image | video | audio | file`). Matches `classifyFile` in
  /// `src/core/attachmentPreview.js:14-20`.
  String _classifyKind(String mime) {
    final lower = mime.toLowerCase();
    if (lower.startsWith('image/')) return 'image';
    if (lower.startsWith('video/')) return 'video';
    if (lower.startsWith('audio/')) return 'audio';
    return 'file';
  }

  /// Build a ≤48KiB JPEG thumbnail + read original dimensions from the
  /// full image bytes. Mirrors the JS peer's `buildAttachmentPreview`
  /// (`src/core/attachmentPreview.js:58-171`) — 320px longest-side, JPEG
  /// quality steps down until the encoded URL fits the cap.
  ///
  /// Heavy work (decode → resize → re-encode) goes through `compute()`
  /// from foundation so a multi-megabyte JPEG doesn't freeze the UI
  /// thread for 300-800 ms while the user is mid-send. On native that's
  /// a real background isolate; on web it falls back to running on the
  /// main thread (dart2js / dart2wasm have no `dart:isolate`) which is
  /// functionally identical to the pre-isolate version, no regression.
  /// `_decodeAndEncodeThumb` lives at file scope so its body is sendable
  /// to a worker isolate — closures over `this` would not be.
  ///
  /// On any failure (HEIC on a platform without a native decoder, etc.)
  /// we return zero dims + a null thumb so the bubble falls back to the
  /// "Изображение" placeholder — better than refusing the whole send.
  Future<_ThumbResult> _buildImageThumb(Uint8List bytes) async {
    try {
      return await compute(_decodeAndEncodeThumb, bytes);
    } catch (_) {
      return const _ThumbResult(null, 0, 0);
    }
  }

  /// Pull + clear the current reply target in one step. Returns the
  /// payload-shaped map the notifier expects (id, from, fromName, type,
  /// text/stickerEmoji/attachment*), or null if nothing was pinned.
  ///
  /// Clearing happens *before* the async send so a fast double-tap
  /// doesn't send the same reply twice — the second send sees a clean
  /// slate and goes out without a quote.
  Map<String, Object?>? _consumeReplyTarget() {
    final target = _replyTo;
    if (target == null) return null;
    // Guard `setState` against a race where the page was popped between
    // the caller reading `_replyTo` and here (e.g. sticker sheet close
    // animation overlapping a system-back). The payload still needs to
    // be returned — the caller will decide whether to keep the send.
    if (!mounted) return _buildReplyPayload(target);
    setState(() => _replyTo = null);
    return _buildReplyPayload(target);
  }

  /// Derive the wire-shaped reply payload from a raw Drift row. The
  /// incoming row is whatever `MessageBubble.onReplyRequested` handed us;
  /// we flatten `payload.*` fields up and tack on the resolved sender
  /// name so the receiver's quote pill has a display label even before
  /// their profiles cache resolves.
  Map<String, Object?> _buildReplyPayload(Map<String, Object?> row) {
    final payloadRaw = row['payload'];
    final payload = payloadRaw is Map
        ? Map<String, Object?>.from(payloadRaw)
        : const <String, Object?>{};
    final msgId = (row['id'] as String?) ?? (payload['id'] as String?) ?? '';
    final dir = (row['direction'] as String?) ?? 'in';
    final selfId =
        ref.read(messagingNotifierProvider.notifier).currentSelfIdOrEmpty;
    final from = dir == 'out'
        ? selfId
        : ((payload['from'] as String?) ?? widget.peerId);
    final typeRaw = payload['type'];
    final type =
        typeRaw is String && typeRaw.isNotEmpty ? typeRaw : 'text';
    final text = (payload['text'] as String?) ?? '';

    // Sticker quote summary — cheapest field the receiver can render.
    String? stickerEmoji;
    final stickerRaw = payload['sticker'];
    if (stickerRaw is Map) {
      final emoji = stickerRaw['emoji'];
      if (emoji is String && emoji.isNotEmpty) stickerEmoji = emoji;
    }

    // Attachment quote summary — decoded fields (kind/name) only; the
    // full attachment blob stays out of the reply.
    String? attachmentKind;
    String? attachmentName;
    final attRaw = payload['attachment'];
    if (attRaw is Map) {
      final kind = attRaw['kind'];
      if (kind is String && kind.isNotEmpty) attachmentKind = kind;
      final name = attRaw['name'];
      if (name is String && name.isNotEmpty) attachmentName = name;
    }

    return <String, Object?>{
      'id': msgId,
      'from': from,
      'fromName': _resolveReplyFromName(dir, from),
      'type': type,
      'text': text,
      if (stickerEmoji != null) 'stickerEmoji': stickerEmoji,
      if (attachmentKind != null) 'attachmentKind': attachmentKind,
      if (attachmentName != null) 'attachmentName': attachmentName,
    };
  }

  /// Resolve the display label for the reply author. Uses the same name
  /// ladder as the chat header: customName > displayName > peerId.
  /// Self-quotes collapse to the currently-stored local profile name
  /// (nothing fancy — the JS build did the same thing via `peer.peerId`
  /// comparison).
  String _resolveReplyFromName(String direction, String from) {
    if (direction == 'out') {
      // TODO(self-profile): once local_profile_provider exposes the
      // current displayName we should use it here. For now the receiver's
      // client can resolve self-quotes against its own profiles cache.
      return '';
    }
    final peerRows = ref.read(peersProvider).asData?.value ?? const [];
    for (final r in peerRows) {
      if ((r['id'] as String?) != from) continue;
      final custom = (r['customName'] as String?) ?? '';
      if (custom.trim().isNotEmpty) return custom.trim();
      final remote = (r['displayName'] as String?) ?? '';
      if (remote.trim().isNotEmpty) return remote;
      break;
    }
    return '';
  }

  /// On send failure, we need to restore `_replyTo` from the sanitised
  /// payload so the pill reappears above the composer. The payload is
  /// NOT a full Drift row — we fake one by wrapping it back so the
  /// projection in [_replyPreview] keeps working.
  Map<String, Object?> _restoreReplyRowFromPayload(
    Map<String, Object?> payload,
  ) {
    return <String, Object?>{
      'id': payload['id'],
      'direction': 'in', // irrelevant for preview; pill only reads payload
      'payload': payload,
    };
  }

  /// Build the composer's reply preview pill from the current [_replyTo].
  /// Null when nothing's pinned.
  ComposerReplyPreview? _replyPreview() {
    final target = _replyTo;
    if (target == null) return null;
    final payloadRaw = target['payload'];
    final payload = payloadRaw is Map
        ? Map<String, Object?>.from(payloadRaw)
        : const <String, Object?>{};
    final dir = (target['direction'] as String?) ?? 'in';
    final fromId =
        (payload['from'] as String?) ?? (target['peerId'] as String?) ?? '';
    final selfId =
        ref.read(messagingNotifierProvider.notifier).currentSelfIdOrEmpty;
    final isSelf = dir == 'out' || (selfId.isNotEmpty && fromId == selfId);
    // Unified grammar: "Ответ: <who>" on both branches so we don't mix
    // prepositional ("на своё") with dative ("собеседнику") in the same
    // UI string. Matches the compact React fallback style.
    final author = isSelf ? 'вам' : _composerAuthorLabel(fromId);

    final typeRaw = payload['type'];
    final type = typeRaw is String && typeRaw.isNotEmpty ? typeRaw : 'text';
    String preview;
    switch (type) {
      case 'sticker':
        final stickerRaw = payload['sticker'];
        if (stickerRaw is Map) {
          final emoji = stickerRaw['emoji'];
          if (emoji is String && emoji.isNotEmpty) {
            preview = emoji;
            break;
          }
        }
        preview = '🖼 Стикер';
        break;
      case 'voice':
        preview = '🎤 Голосовое';
        break;
      case 'file':
        final attRaw = payload['attachment'];
        if (attRaw is Map) {
          final kind = attRaw['kind'];
          if (kind == 'image') {
            preview = '🖼 Фото';
            break;
          }
          if (kind == 'video') {
            preview = '🎬 Видео';
            break;
          }
          final name = attRaw['name'];
          if (name is String && name.isNotEmpty) {
            preview = '📎 $name';
            break;
          }
        }
        preview = '📎 Файл';
        break;
      default:
        final text = (payload['text'] as String?) ?? '';
        preview = text.length > 140 ? '${text.substring(0, 140)}…' : text;
    }

    return ComposerReplyPreview(
      authorLabel: author,
      preview: preview,
      onCancel: () => setState(() => _replyTo = null),
    );
  }

  /// Display label for the reply author — used in the composer pill
  /// ("Ответ X"). Goes through the same name ladder as the chat header:
  /// customName > displayName > "Контакт •<short id>". Dative form is
  /// picked at the call site (e.g. "вам" for self), so this helper only
  /// returns a nominative-style name.
  String _composerAuthorLabel(String fromId) {
    if (fromId.isEmpty) return '(без автора)';
    final peerRows = ref.read(peersProvider).asData?.value ?? const [];
    for (final r in peerRows) {
      if ((r['id'] as String?) != fromId) continue;
      final custom = (r['customName'] as String?) ?? '';
      if (custom.trim().isNotEmpty) return custom.trim();
      final remote = (r['displayName'] as String?) ?? '';
      if (remote.trim().isNotEmpty) return remote;
      break;
    }
    final tail = fromId.length <= 4
        ? fromId
        : fromId.substring(fromId.length - 4);
    return 'Контакт •$tail';
  }

  void _handleReplyRequested(Map<String, Object?> row) {
    setState(() => _replyTo = row);
  }

  /// Bump the "read watermark" whenever the chat is in focus and a new
  /// inbound message has landed. Called from build() after we notice
  /// `rows.length` grew. `rows` is oldest→newest (see
  /// `watchMessagesForPeer`) so we walk the tail backwards — the first
  /// inbound we hit is the newest, and we can stop as soon as we're below
  /// the watermark. In practice k is 1–2 (only new rows since last build).
  void _maybeMarkInboundRead(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) return;
    for (var i = rows.length - 1; i >= 0; i--) {
      final row = rows[i];
      final ts = (row['timestamp'] as num?)?.toInt() ?? 0;
      if (ts <= _lastMarkedReadTs) break;
      if (row['direction'] == 'in') {
        _lastMarkedReadTs = ts;
        unawaited(db.markChatRead(widget.peerId, at: ts));
        return;
      }
    }
  }

  /// Two messages cluster when they share an author (direction) and are less
  /// than 3 minutes apart — drives the spacing + tail collapse in the list.
  static bool _sameCluster(Map<String, Object?> a, Map<String, Object?> b) {
    if ((a['direction'] as String?) != (b['direction'] as String?)) {
      return false;
    }
    final ta = (a['timestamp'] as num?)?.toInt() ?? 0;
    final tb = (b['timestamp'] as num?)?.toInt() ?? 0;
    return (tb - ta).abs() < 180000;
  }

  Future<void> _openChatSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => ChatSettingsSheet(peerId: widget.peerId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(messagesForPeerProvider(widget.peerId));
    final isTyping = ref.watch(typingForPeerProvider(widget.peerId));
    final isOnline = ref.watch(connectedPeerIdsProvider).contains(widget.peerId);

    // Header name/fallback resolution. Goes through peersProvider rather
    // than chatListProvider because chatListProvider only emits rows for
    // peers the user has messaged — during "first contact" the peer row
    // exists but hasn't hit the chat list yet.
    //
    // customName (local rename override) wins over remote displayName so
    // the chat list and chat header stay in sync — both read through the
    // same priority ladder.
    final peersAsync = ref.watch(peersProvider);
    String displayName = widget.peerId;
    bool isBlocked = false;
    int trustLevel = 0;
    final peerRows = peersAsync.asData?.value ?? const [];
    for (final r in peerRows) {
      if ((r['id'] as String?) != widget.peerId) continue;
      final custom = (r['customName'] as String?) ?? '';
      final remote = (r['displayName'] as String?) ?? '';
      if (custom.trim().isNotEmpty) {
        displayName = custom.trim();
      } else if (remote.trim().isNotEmpty) {
        displayName = remote;
      }
      final blockedRaw = r['blocked'];
      isBlocked = blockedRaw == true ||
          (blockedRaw is num && blockedRaw.toInt() == 1);
      final trustRaw = r['trustLevel'];
      if (trustRaw is num) trustLevel = trustRaw.toInt();
      break;
    }

    // Strict TOFU gate: a contact whose key is pinned but not yet user-verified
    // (trustLevel == 1, "Защищён") has its conversation withheld until the
    // safety code is confirmed. Level 0 = no pin yet (nothing to verify);
    // level >= 2 = verified. Messages still decrypt + persist underneath — only
    // their display is gated — so the ratchet stays in sync.
    final strictVerify = ref.watch(strictVerifyProvider);
    final isGated = strictVerify && trustLevel == 1;

    final list = messagesAsync.asData?.value ?? const [];

    // Only trigger the stick-to-bottom check when the count *grew* —
    // in-place status updates should never move the scroll.
    if (list.length != _lastCount) {
      if (list.length > _lastCount) {
        _maybeStickToBottom();
        _maybeMarkInboundRead(list);
      }
      _lastCount = list.length;
    }

    return Scaffold(
      appBar: OrbitsGlassAppBar(
        titleSpacing: 0,
        leading: Navigator.of(context).canPop()
            ? Center(
                child: OrbitsGlassIconButton(
                  icon: Icons.arrow_back,
                  tooltip: 'Назад',
                  variant: OrbitsGlassVariant.subtle,
                  size: OrbitsGlassSize.small,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              )
            : null,
        title: InkWell(
          // Tapping the header opens the same sheet as the ⋮ action — the
          // React build did that too, so users rediscover the settings
          // without hunting for an icon. `borderRadius` keeps the ripple
          // from bleeding past the avatar.
          onTap: _openChatSettings,
          borderRadius: BorderRadius.circular(8),
          child: Row(
            children: [
              _HeaderAvatar(
                name: displayName,
                peerId: widget.peerId,
                isOnline: isOnline,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16),
                    ),
                    Text(
                      isBlocked
                          ? 'Заблокирован'
                          : (isOnline ? 'В сети · защищённый чат' : 'Не в сети'),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          // Audio call button. Disabled while blocked or while a call
          // is already active — the notifier will refuse the start
          // either way, but graying out the button is clearer UX.
          Consumer(
            builder: (ctx, ref, _) {
              final callActive = ref.watch(callIsActiveProvider);
              return OrbitsGlassIconButton(
                icon: Icons.call,
                tooltip: 'Аудио-звонок',
                variant: OrbitsGlassVariant.subtle,
                size: OrbitsGlassSize.small,
                onPressed: (isBlocked || callActive)
                    ? null
                    : () {
                        ref
                            .read(callsNotifierProvider.notifier)
                            .startCall(widget.peerId, video: false);
                      },
              );
            },
          ),
          // Video call button.
          Consumer(
            builder: (ctx, ref, _) {
              final callActive = ref.watch(callIsActiveProvider);
              return OrbitsGlassIconButton(
                icon: Icons.videocam,
                tooltip: 'Видео-звонок',
                variant: OrbitsGlassVariant.subtle,
                size: OrbitsGlassSize.small,
                onPressed: (isBlocked || callActive)
                    ? null
                    : () {
                        ref
                            .read(callsNotifierProvider.notifier)
                            .startCall(widget.peerId, video: true);
                      },
              );
            },
          ),
          OrbitsGlassIconButton(
            icon: Icons.more_vert,
            tooltip: 'Настройки чата',
            variant: OrbitsGlassVariant.subtle,
            size: OrbitsGlassSize.small,
            onPressed: _openChatSettings,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: isGated
          ? _VerifyGate(
              hiddenCount: list.length,
              onVerify: _openChatSettings,
            )
          : Column(
        children: [
          Expanded(
            child: messagesAsync.when(
              data: (rows) {
                if (rows.isEmpty) return const _EmptyChat();
                // `reverse: true` means index 0 is the newest; we flip the
                // row order when indexing so the data stays oldest-first
                // for everyone else (matches `watchMessagesForPeer`'s
                // contract).
                return ListView.builder(
                  controller: _scrollCtl,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: rows.length,
                  // Hold ~2000 logical px of off-screen bubbles in memory
                  // on each side of the viewport. With reverse:true and
                  // variable-height bubbles, the default 250 px cache is
                  // way too small — short scrubs back-and-forth through
                  // history would re-decode replies / re-mount voice
                  // players, which is what causes the "jitter on scroll
                  // up" noted in the optimisation doc.
                  cacheExtent: 2000,
                  // Disable the implicit RepaintBoundary — we add our own
                  // per-bubble below so each row composites on its own
                  // layer (heavy bubbles like images don't invalidate the
                  // simple text bubbles next to them on every paint).
                  addRepaintBoundaries: false,
                  itemBuilder: (context, i) {
                    final k = rows.length - 1 - i;
                    final row = rows[k];
                    // Message clustering: collapse the gap + drop the tail for
                    // consecutive messages from the same author < 3 min apart.
                    final prev = k > 0 ? rows[k - 1] : null;
                    final next = k < rows.length - 1 ? rows[k + 1] : null;
                    final groupedWithPrevious =
                        prev != null && _sameCluster(prev, row);
                    final isTail = next == null || !_sameCluster(row, next);
                    return RepaintBoundary(
                      child: MessageBubble(
                        row: row,
                        groupedWithPrevious: groupedWithPrevious,
                        isTail: isTail,
                        onRetry: () {
                          // Touching a pending message re-kicks the
                          // flusher for this peer. If the reliable channel
                          // is down this is a no-op until it reopens.
                          ref
                              .read(messagingNotifierProvider.notifier)
                              .flushOutboxForPeer(widget.peerId);
                        },
                        onReplyRequested: _handleReplyRequested,
                      ),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Не удалось загрузить сообщения: $err',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
          // Typing bubble floats above the composer when the peer is
          // typing. `AnimatedSwitcher` gives a soft slide-in without
          // pulling in a full animation package.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: isTyping
                ? const Align(
                    key: ValueKey('typing'),
                    alignment: Alignment.centerLeft,
                    child: TypingIndicator(),
                  )
                : const SizedBox(
                    key: ValueKey('no-typing'),
                    height: 0,
                  ),
          ),
          if (isBlocked)
            _BlockedComposerBanner(onUnblock: _openChatSettings)
          else
            ChatComposer(
              actions: ComposerActions(
                onSend: _handleSend,
                onTypingChanged: _handleTyping,
                onOpenStickerPicker: _openStickerPicker,
                onPickAttachment: _pickAttachment,
                onRecordVoice: _openVoiceRecorder,
              ),
              replyPreview: _replyPreview(),
            ),
        ],
      ),
    );
  }
}

/// Strict-TOFU gate shown in place of the conversation when a contact's key
/// is pinned (TOFU) but not yet user-verified. Reading is withheld until the
/// user compares the safety code in the chat settings sheet and marks the
/// contact "Проверен" (trustLevel 2). Messages still decrypt + persist behind
/// it. See `strict_verify_provider.dart`.
class _VerifyGate extends StatelessWidget {
  const _VerifyGate({required this.hiddenCount, required this.onVerify});

  final int hiddenCount;
  final VoidCallback onVerify;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: OrbitsGlassSurface(
              role: OrbitsGlassRole.card,
              borderRadius: BorderRadius.circular(tokens.radiusCard),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: tokens.accentAlpha(0.16),
                        shape: BoxShape.circle,
                        border: Border.all(color: tokens.accentAlpha(0.24)),
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.shield_outlined,
                          size: 30, color: tokens.text),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Подтвердите личность',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: tokens.fontHeading,
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: tokens.text,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Связь с этим контактом уже зашифрована, но вы ещё не '
                      'сверили код безопасности. Чтобы исключить подмену '
                      'собеседника, сравните код с ним по другому каналу — '
                      'и отметьте «Проверен».',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: tokens.fontBody,
                        fontSize: 13.5,
                        height: 1.4,
                        color: tokens.muted,
                      ),
                    ),
                    if (hiddenCount > 0) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: tokens.muted.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'Скрыто сообщений: $hiddenCount',
                          style: TextStyle(
                            fontFamily: tokens.fontBody,
                            fontSize: 12.5,
                            color: tokens.text,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    OrbitsGlassButton(
                      label: 'Сверить и подтвердить',
                      icon: Icons.verified_user,
                      variant: OrbitsGlassVariant.primary,
                      expand: true,
                      onPressed: onVerify,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Отключить строгую проверку можно в «Настройки → '
                      'Безопасность».',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: tokens.fontBody,
                        fontSize: 11.5,
                        color: tokens.muted,
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
}

/// Stand-in for the composer when the peer is blocked. Outbound sends are
/// suppressed up the stack (messagingNotifier refuses the write), but the
/// composer itself is hidden so the affordance + typing heuristics don't
/// mislead the user into thinking the message will go through.
class _BlockedComposerBanner extends StatelessWidget {
  const _BlockedComposerBanner({required this.onUnblock});

  final VoidCallback onUnblock;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            top: BorderSide(
              color: scheme.onSurface.withValues(alpha: 0.08),
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.block,
              size: 20,
              color: scheme.error,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Вы заблокировали этого пользователя',
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ),
            OrbitsGlassButton(
              label: 'Разблокировать',
              variant: OrbitsGlassVariant.subtle,
              size: OrbitsGlassSize.small,
              onPressed: onUnblock,
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderAvatar extends StatelessWidget {
  const _HeaderAvatar({
    required this.name,
    required this.peerId,
    required this.isOnline,
  });

  final String name;
  final String peerId;
  final bool isOnline;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isNotEmpty
        ? name.trim().characters.first.toUpperCase()
        : (peerId.isNotEmpty ? peerId.substring(0, 1) : '?');
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: scheme.primaryContainer,
          child: Text(
            initial,
            style: TextStyle(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (isOnline)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                // Theme-aware online dot — matches the chats list avatar.
                color: OrbitsTokens.of(context).success,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            const Text(
              'Пока ни одного сообщения',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Защищённый чат. История хранится только на ваших '
              'устройствах.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Result of a synchronous image-thumbnail build. `bytes` is the encoded
/// JPEG (or null if the source couldn't be decoded); `width`/`height`
/// carry the *original* source dimensions so the receiver's bubble can
/// lock the correct aspect ratio even while the full attachment is still
/// streaming in. Kept as a tiny value class (rather than a 3-tuple or a
/// Map) so call sites read clearly and the const constructor lets us
/// emit a zero-allocation "decode failed" sentinel.
class _ThumbResult {
  const _ThumbResult(this.bytes, this.width, this.height);

  final Uint8List? bytes;
  final int width;
  final int height;
}

/// Heavy-side of `_buildImageThumb`: decode, resize to ≤320 px on the
/// longest side, then encode JPEG with quality stepping down until the
/// raw payload fits the 33 KB budget (≈48 KB after base64). Runs through
/// `compute()` on native so it doesn't block the UI thread; the function
/// is at file scope so its body is sendable to a worker isolate
/// (closures over `this` would not be).
_ThumbResult _decodeAndEncodeThumb(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return const _ThumbResult(null, 0, 0);
  const int maxSide = 320;
  img.Image scaled = decoded;
  if (decoded.width > maxSide || decoded.height > maxSide) {
    if (decoded.width >= decoded.height) {
      scaled = img.copyResize(
        decoded,
        width: maxSide,
        interpolation: img.Interpolation.average,
      );
    } else {
      scaled = img.copyResize(
        decoded,
        height: maxSide,
        interpolation: img.Interpolation.average,
      );
    }
  }
  // Step quality down until the encoded data URL fits the 48KB wire cap.
  const int rawBudget = 33 * 1024;
  const qualitySteps = [72, 60, 50, 40, 35];
  Uint8List? out;
  for (final q in qualitySteps) {
    final encoded = Uint8List.fromList(img.encodeJpg(scaled, quality: q));
    if (encoded.length <= rawBudget) {
      out = encoded;
      break;
    }
    out = encoded; // keep the smallest we tried, as a last resort
  }
  return _ThumbResult(out, decoded.width, decoded.height);
}

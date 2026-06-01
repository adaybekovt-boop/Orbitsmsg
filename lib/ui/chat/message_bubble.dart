// Message bubble — renders a single persisted row from the chat stream.
// Supports text + sticker + voice + file bodies.
//
// Shape summary:
//   payload.type = 'text'    → text bubble (surface/primary background)
//   payload.type = 'sticker' → bare sticker image (no bubble chrome),
//                              timestamp row floats below
//   payload.type = 'voice'   → lightweight bubble wrapping [VoicePlayer]
//   payload.type = 'file'    → lightweight bubble wrapping [FileTile]
//   payload.replyTo (any type) → quoted-message pill rendered above the
//                              body inside the same bubble column
//
// The bubble takes a raw Drift message row (`Map<String, Object?>` with
// columns `id/direction/status/timestamp/payload`) rather than a typed
// model so we don't pay for a DTO layer that nobody else consumes.
//
// Long-press a peer bubble → `onReplyRequested(row)` fires with the raw
// row; the owning page decides what to do (usually: set its own
// `_replyTo` state so the composer preview pill appears). We don't force
// a specific gesture model on the page — `GestureDetector` captures both
// taps (pending retry) and long-press (reply) and routes them via
// callbacks the page owns.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../peer/security_monitor.dart' show ContactVerification;
import '../../themes/orbits_tokens.dart';
import 'file_tile.dart';
import 'voice_player.dart';

/// Delivery state glyph shown on outbound bubbles. Pure display — the
/// state is decoded from the Drift row's `status` column upstream.
enum BubbleDelivery { pending, sent, delivered, read }

BubbleDelivery _decodeDelivery(String? status) {
  switch (status) {
    case 'read':
      return BubbleDelivery.read;
    case 'delivered':
      return BubbleDelivery.delivered;
    case 'sent':
      return BubbleDelivery.sent;
    case 'pending':
    case 'queued':
    default:
      return BubbleDelivery.pending;
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.row,
    this.onRetry,
    this.onReplyRequested,
    this.groupedWithPrevious = false,
    this.isTail = true,
    this.hostPeerId,
    this.senderVerification,
  });

  /// Raw Drift row: id, peerId, timestamp, direction, status, payload (Map).
  final Map<String, Object?> row;

  /// For room messages (`row['roomId'] != null`): the room host's peer code,
  /// so an incoming message from the host gets an "Организатор" badge. Null in
  /// 1:1 chats — no sender header is shown there.
  final String? hostPeerId;

  /// For room messages: the sender's verification tier (from their contact
  /// `trustLevel`). A non-host sender renders a green "Проверен" check when
  /// [ContactVerification.verified], or a grey tappable "Не проверен" warning
  /// when [ContactVerification.unverified]. Null → no verification badge.
  final ContactVerification? senderVerification;

  /// Message clustering: true when the previous (older) message is from the
  /// same author within the grouping window — collapses the vertical gap so a
  /// run of messages reads as one block.
  final bool groupedWithPrevious;

  /// True when this is the last bubble of its cluster (or a standalone
  /// message) — only the tail bubble keeps the asymmetric "tail" corner;
  /// inner bubbles are symmetrically rounded.
  final bool isTail;

  /// Tap-to-retry for failed outbound messages. Pending rows become
  /// tappable; other states swallow the tap.
  final VoidCallback? onRetry;

  /// Long-press handler. Fires with the raw row so the owning page can
  /// pluck whatever fields it needs for the reply preview (id, from,
  /// type, text, sticker.emoji, …). Optional — pages that don't support
  /// replies (or only support them from a dedicated context menu) can
  /// leave it null.
  final void Function(Map<String, Object?> row)? onReplyRequested;

  @override
  Widget build(BuildContext context) {
    final direction = (row['direction'] as String?) ?? 'in';
    final mine = direction == 'out';
    final status = row['status'] as String?;
    final delivery = _decodeDelivery(status);
    final ts = (row['timestamp'] as num?)?.toInt() ?? 0;
    final payload = row['payload'];
    final payloadMap = payload is Map
        ? Map<String, Object?>.from(payload)
        : const <String, Object?>{};
    final msgType = _msgType(payloadMap);
    final text = (payloadMap['text'] as String?) ?? '';
    final stickerRaw = payloadMap['sticker'];
    final sticker = (msgType == 'sticker' && stickerRaw is Map)
        ? Map<String, Object?>.from(stickerRaw)
        : null;
    final voiceRaw = payloadMap['voice'];
    final voice = (msgType == 'voice' && voiceRaw is Map)
        ? Map<String, Object?>.from(voiceRaw)
        : null;
    final attachmentRaw = payloadMap['attachment'];
    final attachment = (msgType == 'file' && attachmentRaw is Map)
        ? Map<String, Object?>.from(attachmentRaw)
        : null;
    final msgId = (row['id'] as String?) ?? '';
    final replyRaw = payloadMap['replyTo'];
    final replyTo =
        replyRaw is Map ? Map<String, Object?>.from(replyRaw) : null;

    final scheme = Theme.of(context).colorScheme;
    final tokens = OrbitsTokens.of(context);
    final media = MediaQuery.of(context).size.width;
    final maxW = media * 0.75;

    // Group-chat (room) sender attribution: show the name once at the top of a
    // cluster, on incoming messages only. The "Организатор" badge marks the
    // host. 1:1 chats pass no hostPeerId and don't set roomId, so this stays
    // off there.
    final isRoom = (row['roomId'] as String?) != null;
    final showSender = isRoom && !mine && !groupedWithPrevious;
    final senderName = showSender ? _roomSenderName(payloadMap, row) : '';
    final senderIsHost = isRoom &&
        hostPeerId != null &&
        hostPeerId!.isNotEmpty &&
        (row['peerId'] as String?) == hostPeerId;

    // Reply long-press is suppressed while a message is still sending —
    // the same tap-area carries "tap to retry" on pending rows, and two
    // overlapping gestures on one bubble with no visual feedback lead
    // users into accidentally quoting their own failed message. Non-
    // pending rows (sent / delivered / read) get the full gesture set.
    final canReply =
        onReplyRequested != null && delivery != BubbleDelivery.pending;

    // Sticker branch renders bare — no background bubble, no padding, so
    // the image floats on the chat canvas the way WhatsApp / Telegram
    // stickers do. Timestamp + delivery tick sit below the image.
    if (sticker != null) {
      return _BubbleGesture(
        onRetry: mine && delivery == BubbleDelivery.pending ? onRetry : null,
        onReplyRequested: canReply ? () => onReplyRequested!(row) : null,
        child: Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.only(
                left: 8, right: 8, top: groupedWithPrevious ? 1.5 : 4, bottom: 2),
            child: Column(
              crossAxisAlignment:
                  mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (replyTo != null)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxW),
                    child: _ReplyQuote(
                      replyTo: replyTo,
                      mine: mine,
                      onOpaque: true,
                    ),
                  ),
                _StickerImage(sticker: sticker),
                const SizedBox(height: 2),
                _MetaRow(
                  ts: ts,
                  mine: mine,
                  delivery: delivery,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
                if (mine && delivery == BubbleDelivery.pending)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'отправится при подключении',
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: 0.55),
                        fontSize: 10,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    // Voice + file branches — same bubble chrome as text (rounded
    // primary/surface fill) so they align with the timeline visually,
    // but the body is a dedicated widget (VoicePlayer / FileTile). Same
    // reply quote + meta row pattern as the text branch.
    if (voice != null) {
      return _mediaBubble(
        context: context,
        mine: mine,
        delivery: delivery,
        ts: ts,
        replyTo: replyTo,
        canReply: canReply,
        maxW: maxW,
        body: VoicePlayer(
          msgId: msgId,
          voiceRef: voice,
          mine: mine,
        ),
      );
    }
    if (attachment != null) {
      // File tiles already ship with their own rounded surface; no
      // bubble chrome needed. We still want the reply quote + meta row
      // though, so we wrap in a thin padded column with an
      // `Align`-style outer so it hugs the correct side.
      return _BubbleGesture(
        onRetry: mine && delivery == BubbleDelivery.pending ? onRetry : null,
        onReplyRequested: canReply ? () => onReplyRequested!(row) : null,
        child: Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.only(
                left: 8, right: 8, top: groupedWithPrevious ? 1.5 : 4, bottom: 2),
            child: Column(
              crossAxisAlignment:
                  mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (replyTo != null)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxW),
                    child: _ReplyQuote(
                      replyTo: replyTo,
                      mine: mine,
                      onOpaque: true,
                    ),
                  ),
                if (replyTo != null) const SizedBox(height: 4),
                FileTile(
                  msgId: msgId,
                  attachment: attachment,
                  mine: mine,
                ),
                const SizedBox(height: 2),
                _MetaRow(
                  ts: ts,
                  mine: mine,
                  delivery: delivery,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
                if (mine && delivery == BubbleDelivery.pending)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'отправится при подключении',
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: 0.55),
                        fontSize: 10,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    // Regular text bubble — same layout as before, with an optional
    // reply quote pinned to the top of the column.
    final bg = mine ? tokens.bubbleOut : scheme.surfaceContainerHighest;
    final fg = mine ? _outgoingTextColor(tokens) : scheme.onSurface;
    final timeColor = fg.withValues(alpha: 0.72);

    return _BubbleGesture(
      onRetry: mine && delivery == BubbleDelivery.pending ? onRetry : null,
      onReplyRequested: canReply ? () => onReplyRequested!(row) : null,
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: maxW),
          margin: _bubbleMargin(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: _bubbleRadius(mine),
            border: mine
                ? Border.all(color: tokens.accentAlpha(0.22), width: 1)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSender)
                _RoomSenderHeader(
                  name: senderName,
                  isHost: senderIsHost,
                  verification: senderIsHost ? null : senderVerification,
                ),
              if (replyTo != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _ReplyQuote(
                    replyTo: replyTo,
                    mine: mine,
                    onOpaque: false,
                  ),
                ),
              if (text.isNotEmpty)
                Text(
                  text,
                  style: TextStyle(
                    color: fg,
                    fontSize: 15,
                    height: 1.35,
                    fontFamily: OrbitsTokens.of(context).fontBody,
                  ),
                ),
              const SizedBox(height: 2),
              _MetaRow(
                ts: ts,
                mine: mine,
                delivery: delivery,
                color: timeColor,
              ),
              if (mine && delivery == BubbleDelivery.pending)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'отправится при подключении',
                    style: TextStyle(
                      color: timeColor,
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Cluster-aware outer margin: tight top gap when this bubble continues a
  /// run from the same author, normal gap when it starts a new block.
  EdgeInsets _bubbleMargin() => EdgeInsets.only(
        left: 12,
        right: 12,
        top: groupedWithPrevious ? 1.5 : 6,
        bottom: 1.5,
      );

  /// Cluster-aware corner radii: only the tail bubble keeps the asymmetric
  /// "tail" corner; inner bubbles of a run are symmetrically rounded.
  BorderRadius _bubbleRadius(bool mine) => BorderRadius.only(
        topLeft: const Radius.circular(20),
        topRight: const Radius.circular(20),
        bottomLeft: Radius.circular(!mine && isTail ? 6 : 20),
        bottomRight: Radius.circular(mine && isTail ? 6 : 20),
      );

  /// Shared rendering for "media-in-bubble" bodies (voice). The message
  /// chrome mirrors the text bubble (same rounded tail, same fill) so
  /// rows line up visually, but we swap the core body for a player.
  /// File attachments ship their own surface so they don't go through
  /// this helper.
  Widget _mediaBubble({
    required BuildContext context,
    required bool mine,
    required BubbleDelivery delivery,
    required int ts,
    required Map<String, Object?>? replyTo,
    required bool canReply,
    required double maxW,
    required Widget body,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = OrbitsTokens.of(context);
    final bg = mine ? tokens.bubbleOut : scheme.surfaceContainerHighest;
    final fg = mine ? _outgoingTextColor(tokens) : scheme.onSurface;
    final timeColor = fg.withValues(alpha: 0.72);

    return _BubbleGesture(
      onRetry: mine && delivery == BubbleDelivery.pending ? onRetry : null,
      onReplyRequested: canReply ? () => onReplyRequested!(row) : null,
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: maxW),
          margin: _bubbleMargin(),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: _bubbleRadius(mine),
            border: mine
                ? Border.all(color: tokens.accentAlpha(0.22), width: 1)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (replyTo != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _ReplyQuote(
                    replyTo: replyTo,
                    mine: mine,
                    onOpaque: false,
                  ),
                ),
              body,
              const SizedBox(height: 2),
              _MetaRow(
                ts: ts,
                mine: mine,
                delivery: delivery,
                color: timeColor,
              ),
              if (mine && delivery == BubbleDelivery.pending)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'отправится при подключении',
                    style: TextStyle(
                      color: timeColor,
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
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

/// Extract the message type with the same falsy-coerce semantics as the
/// JS mapper — empty-string `payload.type` falls back to `'text'`, same
/// as absent.
String _msgType(Map<String, Object?> payload) {
  final t = payload['type'];
  if (t is String && t.isNotEmpty) return t;
  return 'text';
}

class _BubbleGesture extends StatelessWidget {
  const _BubbleGesture({
    required this.child,
    this.onRetry,
    this.onReplyRequested,
  });

  final Widget child;
  final VoidCallback? onRetry;
  final VoidCallback? onReplyRequested;

  @override
  Widget build(BuildContext context) {
    // `HitTestBehavior.translucent` so a tap on the sticker's invisible
    // padding still registers. Without it a sticker's transparent corners
    // swallow long-press attempts on narrow phones.
    //
    // Haptic feedback on long-press: without this the user has no signal
    // that the ~500 ms press threshold fired, and may release thinking
    // nothing happened (the reply pill shows up silently above the
    // composer). A selectionClick is the lightest haptic that still
    // registers on modern phones. JS version used `hapticTap()` (see
    // Chats.jsx:260) — same intent, platform-native equivalent here.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onRetry,
      onLongPress: onReplyRequested == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onReplyRequested!();
            },
      child: child,
    );
  }
}

class _StickerImage extends StatelessWidget {
  const _StickerImage({required this.sticker});
  final Map<String, Object?> sticker;

  @override
  Widget build(BuildContext context) {
    // Prefer `emoji` (always present on default packs) — renders via the
    // platform emoji font at ~100dp which is what the JS `<img>` tag at
    // the same size resolves to visually. Fall back to an icon if the
    // incoming sticker had no emoji and only an SVG URL (custom pack
    // rendering is a post-launch item).
    final emoji = (sticker['emoji'] as String?) ?? '';
    if (emoji.isNotEmpty) {
      return SizedBox(
        width: 112,
        height: 112,
        child: Center(
          child: Text(emoji, style: const TextStyle(fontSize: 96)),
        ),
      );
    }
    // Custom-pack fallback. Shows the user *something* so the bubble
    // isn't empty, and the recipient can still see the label via long
    // press if we add a sticker-info sheet later.
    final label = (sticker['label'] as String?) ?? '';
    return SizedBox(
      width: 112,
      height: 112,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.image_outlined, size: 52),
            if (label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Quoted-message pill shown above the body. [onOpaque] toggles the
/// background: inside a coloured text bubble we let the accent strip +
/// text stand on the bubble's own fill (translucent), but when the host
/// bubble is "bare" (sticker) we render our own opaque surface so the
/// quote is legible against the chat background.
class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({
    required this.replyTo,
    required this.mine,
    required this.onOpaque,
  });

  final Map<String, Object?> replyTo;
  final bool mine;
  final bool onOpaque;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = OrbitsTokens.of(context);
    final author = _authorName(replyTo);
    final preview = _quotePreview(replyTo);

    // Colour strategy: inside a filled bubble we can lean on the bubble's
    // own fg colour with alpha; in opaque mode (bare sticker) we need a
    // real surface. The vertical accent strip is always the primary.
    // For "mine" we mirror the bubble's derived text colour so the quote stays
    // legible on the dark graphite-blue fill (scheme.onPrimary would be dark).
    final textOnFilled =
        mine ? _outgoingTextColor(tokens) : scheme.onSurface;
    final textOnOpaque = scheme.onSurface;
    final authorColor = onOpaque
        ? scheme.primary
        : textOnFilled.withValues(alpha: 0.95);
    final previewColor = onOpaque
        ? textOnOpaque.withValues(alpha: 0.7)
        : textOnFilled.withValues(alpha: 0.75);

    return Container(
      decoration: BoxDecoration(
        color: onOpaque
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.9)
            : (mine
                ? Colors.black.withValues(alpha: 0.15)
                : Colors.black.withValues(alpha: 0.08)),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 3,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: authorColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    preview.isEmpty ? '…' : preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: previewColor, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Resolve the author label for a reply. Uses the persisted
/// `fromName` if present; otherwise a short hash of the id so the quote
/// doesn't collapse to literally the word "Сообщение" for every peer
/// whose profile we haven't indexed yet.
String _authorName(Map<String, Object?> replyTo) {
  final fromName = replyTo['fromName'];
  if (fromName is String && fromName.trim().isNotEmpty) {
    return fromName.trim();
  }
  final from = replyTo['from'];
  if (from is String && from.isNotEmpty) {
    // Match the JS "Контакт •XXXX" placeholder style — last 4 id chars.
    final tail = from.length <= 4 ? from : from.substring(from.length - 4);
    return 'Контакт •$tail';
  }
  return 'Сообщение';
}

/// One-line preview for a quoted message. Dispatches on `replyTo.type`
/// the same way `chat_list_provider._buildPreview` does on chat-list
/// rows — keeps the quote semantics identical between the two surfaces.
String _quotePreview(Map<String, Object?> replyTo) {
  final type = replyTo['type'];
  final typeStr = type is String && type.isNotEmpty ? type : 'text';
  switch (typeStr) {
    case 'sticker':
      final emoji = replyTo['stickerEmoji'];
      if (emoji is String && emoji.isNotEmpty) return emoji;
      return '🖼 Стикер';
    case 'voice':
      return '🎤 Голосовое сообщение';
    case 'file':
      final kind = replyTo['attachmentKind'];
      if (kind == 'image') return '🖼 Фото';
      if (kind == 'video') return '🎬 Видео';
      final name = replyTo['attachmentName'];
      if (name is String && name.isNotEmpty) return '📎 $name';
      return '📎 Файл';
    case 'text':
    default:
      final text = replyTo['text'];
      if (text is String && text.isNotEmpty) {
        // JS caps quotes at 140; we already clamp on send (280) but do a
        // soft UI trim too so the bubble stays compact.
        return text.length > 140 ? '${text.substring(0, 140)}…' : text;
      }
      return '';
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.ts,
    required this.mine,
    required this.delivery,
    required this.color,
  });

  final int ts;
  final bool mine;
  final BubbleDelivery delivery;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _formatTime(ts),
          style: TextStyle(
            color: color,
            fontSize: 11,
            // Warm body font (Inter) for the clock — mono is reserved for
            // profile codes + safety fingerprints. Tabular figures keep the
            // HH:MM width steady so the row doesn't jitter.
            fontFamily: OrbitsTokens.of(context).fontBody,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (mine) ...[
          const SizedBox(width: 4),
          _DeliveryIcon(delivery: delivery, color: color),
        ],
      ],
    );
  }
}

class _DeliveryIcon extends StatelessWidget {
  const _DeliveryIcon({required this.delivery, required this.color});
  final BubbleDelivery delivery;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const size = 14.0;
    // "Read" ticks pop in the theme's `deliveryRead` token regardless of
    // the bubble's own fg colour. Mirrors the JS `text-blue-200` trick;
    // each manifest decides whether that's brand-blue, accent-pink, or a
    // green for terminal-themed Matrix.
    final readColor = OrbitsTokens.of(context).deliveryRead;

    return switch (delivery) {
      BubbleDelivery.pending =>
        Icon(Icons.access_time, size: size, color: color),
      BubbleDelivery.sent => Icon(Icons.check, size: size, color: color),
      BubbleDelivery.delivered =>
        Icon(Icons.done_all, size: size, color: color),
      BubbleDelivery.read =>
        Icon(Icons.done_all, size: size, color: readColor),
    };
  }
}

/// Display name for a room message's sender. Prefers the wire `fromName`,
/// falls back to a "Контакт •XXXX" placeholder from the peer-id tail.
String _roomSenderName(Map<String, Object?> payload, Map<String, Object?> row) {
  final fn = (payload['fromName'] as String?)?.trim();
  if (fn != null && fn.isNotEmpty) return fn;
  final from = (row['peerId'] as String?) ?? '';
  if (from.isEmpty) return 'Участник';
  final tail = from.length <= 4 ? from : from.substring(from.length - 4);
  return 'Контакт •$tail';
}

/// Sender attribution shown at the top of an incoming room-message bubble:
/// the name plus an optional "Организатор" (host) badge.
class _RoomSenderHeader extends StatelessWidget {
  const _RoomSenderHeader({
    required this.name,
    required this.isHost,
    this.verification,
  });
  final String name;
  final bool isHost;
  final ContactVerification? verification;

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: t.text,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFamily: t.fontBody,
              ),
            ),
          ),
          // Host badge takes precedence; otherwise show the verification tier.
          if (isHost) ...[
            const SizedBox(width: 6),
            const _HostBadge(),
          ] else if (verification == ContactVerification.verified) ...[
            const SizedBox(width: 6),
            const _VerifiedBadge(),
          ] else if (verification == ContactVerification.unverified) ...[
            const SizedBox(width: 6),
            const _UnverifiedBadge(),
          ],
        ],
      ),
    );
  }
}

class _HostBadge extends StatelessWidget {
  const _HostBadge();

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: t.accentAlpha(0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.accentAlpha(0.32)),
      ),
      child: Text(
        'Организатор',
        style: TextStyle(
          color: t.text,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          fontFamily: t.fontBody,
        ),
      ),
    );
  }
}

/// Green "verified" chip — sender's contact trustLevel ≥ 2 (safety number was
/// personally confirmed).
class _VerifiedBadge extends StatelessWidget {
  const _VerifiedBadge();

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    return Tooltip(
      message: 'Личность подтверждена',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: t.success.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: t.success.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_rounded, size: 11, color: t.success),
            const SizedBox(width: 3),
            Text(
              'Проверен',
              style: TextStyle(
                color: t.success,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                fontFamily: t.fontBody,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Grey "unverified" chip — sender has no confirmed trustLevel. Tap opens a
/// man-in-the-middle warning.
class _UnverifiedBadge extends StatelessWidget {
  const _UnverifiedBadge();

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    return GestureDetector(
      onTap: () => _showUnverifiedWarning(context, t),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: t.muted.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: t.muted.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, size: 11, color: t.muted),
            const SizedBox(width: 3),
            Text(
              'Не проверен',
              style: TextStyle(
                color: t.muted,
                fontSize: 9,
                fontWeight: FontWeight.w600,
                fontFamily: t.fontBody,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _showUnverifiedWarning(BuildContext context, OrbitsTokens t) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: t.surface,
      title: Text(
        'Личность не подтверждена',
        style: TextStyle(fontFamily: t.fontHeading, color: t.text),
      ),
      content: Text(
        'Вы ещё не сверяли код безопасности этого участника. Переписка '
        'зашифрована, но без проверки нельзя исключить подмену ключа '
        '(«человек посередине»). Сверьте код безопасности лично, прежде '
        'чем полностью доверять отправителю.',
        style: TextStyle(fontFamily: t.fontBody, color: t.text, height: 1.4),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Понятно'),
        ),
      ],
    ),
  );
}

/// Legible text colour for an outgoing bubble, derived from the (dark in both
/// themes) [OrbitsTokens.bubbleOut] fill so we never paint dark glyphs on a
/// dark glass tile.
Color _outgoingTextColor(OrbitsTokens tokens) =>
    ThemeData.estimateBrightnessForColor(tokens.bubbleOut) == Brightness.dark
        ? Colors.white.withValues(alpha: 0.95)
        : Colors.black.withValues(alpha: 0.9);

String _formatTime(int epochMs) {
  if (epochMs <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

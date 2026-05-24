// Typed "chat row" view over the raw peer + message rows. The ChatsPage
// wants a stable object per contact with (peerId, name, trust, online,
// unread badge, last-message preview, block flag) and doesn't want to read
// a loose `Map<String, Object?>` at every cell build.
//
// The provider fuses two streams:
//   - `peersProvider`        → contact list (one row per peer)
//   - `chatMetasProvider`    → per-peer derived metadata (last message blob,
//                              newest ts, unread count) joined against the
//                              messages table + peer.lastReadAt watermark.
//
// Peers with no messages still appear (freshly-added contact) — they just
// get an empty preview and 0 unread. Ordering is: most-recent *activity*
// first (max of last-message ts, lastSeenAt) so new inbound traffic
// promotes a chat to the top even if the peer hasn't updated their
// profile recently.
//
// Blocked peers (`isBlocked == true`) stay in the list — the chat row just
// renders a subdued variant. Hiding blocked peers is the ChatsPage's call,
// not this provider's.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/db.dart' as db;
import 'connections_notifier.dart';
import 'peers_provider.dart';

/// Trust level enum — mirrors the integers persisted in the `trustLevel`
/// column so UI can `switch` without magic numbers.
enum ChatTrust { unknown, tofu, verified }

ChatTrust _decodeTrust(Object? raw) {
  final v = (raw as num?)?.toInt() ?? 0;
  return switch (v) {
    >= 2 => ChatTrust.verified,
    1 => ChatTrust.tofu,
    _ => ChatTrust.unknown,
  };
}

class ChatSummary {
  const ChatSummary({
    required this.peerId,
    required this.displayName,
    required this.customName,
    required this.lastSeenAt,
    required this.lastMessageAt,
    required this.trust,
    required this.isOnline,
    required this.isBlocked,
    this.unreadCount = 0,
    this.preview = '',
  });

  final String peerId;

  /// Name broadcast by the peer's profile packet. Empty until the first
  /// handshake completes.
  final String displayName;

  /// Local rename override set via chat settings. Takes precedence over
  /// `displayName` when non-empty. Never touched by remote packets.
  final String customName;

  final int lastSeenAt;

  /// Timestamp of the newest message in history (0 if no messages yet).
  /// Used for sort order — a fresh inbound message should float the chat
  /// to the top of the list even if the peer hasn't re-broadcast profile.
  final int lastMessageAt;

  final ChatTrust trust;

  /// True iff we currently have an open reliable DataConnection to this
  /// peer. Multiple peers can be online simultaneously — this flag is
  /// per-row, read off `connectedPeerIdsProvider`.
  final bool isOnline;

  /// User flipped "заблокировать" in chat settings. Inbound packets from
  /// this peer are dropped in `messaging_notifier.pushInbound`; outbound
  /// sends are disabled in the composer.
  final bool isBlocked;

  /// Inbound messages newer than `lastReadAt` — the chat list badge.
  final int unreadCount;

  /// One-line plaintext of the latest message (kind-specific placeholder
  /// for non-text payloads). Empty string if the chat has no history.
  final String preview;

  /// Priority: customName → remote displayName → peerId. The chat list
  /// should never render a blank row.
  String get effectiveName {
    final trimmed = customName.trim();
    if (trimmed.isNotEmpty) return trimmed;
    if (displayName.trim().isNotEmpty) return displayName;
    return peerId;
  }

  /// Timestamp used for sort order — newest activity wins. Falls back to
  /// `lastSeenAt` when the peer has no message history yet.
  int get sortTimestamp =>
      lastMessageAt > lastSeenAt ? lastMessageAt : lastSeenAt;
}

/// Raw per-peer chat metadata keyed by peerId. Values carry the last
/// message's decoded payload map (or null when no messages yet) plus
/// `lastTs` and `unreadCount`. Consumers typically want `chatListProvider`
/// instead of reading this directly.
final chatMetasProvider =
    StreamProvider<Map<String, Map<String, Object?>>>((ref) {
  return db.watchChatMetas().map((rows) {
    final out = <String, Map<String, Object?>>{};
    for (final r in rows) {
      final peerId = r['peerId'] as String? ?? '';
      if (peerId.isEmpty) continue;
      out[peerId] = r;
    }
    return out;
  });
});

/// Build a short plaintext preview for the chat list.
///
/// Payload shape mirrors `message_mapper.dart::rowToUiMessage`:
///   kind = payload['type'] || 'text'
///     'text'     → payload['text']
///     'sticker'  → '🖼 Стикер' (+ emoji if the sent sticker had one)
///     'voice'    → '🎤 Голосовое сообщение'
///     'attachment' → kind-specific ('🖼 Фото' / '🎬 Видео' / '📎 <name>')
///
/// Returns an empty string when we can't derive anything — the UI renders
/// that as a muted em-dash rather than a blank row.
String _buildPreview(Map<String, Object?>? lastData) {
  if (lastData == null) return '';
  final payloadRaw = lastData['payload'];
  if (payloadRaw is! Map) return '';
  final payload = Map<String, Object?>.from(payloadRaw);
  final typeRaw = payload['type'];
  final type = typeRaw is String && typeRaw.isNotEmpty ? typeRaw : 'text';

  switch (type) {
    case 'text':
      final text = (payload['text'] as String?) ?? '';
      return _flattenOneLine(text);
    case 'sticker':
      final sticker = payload['sticker'];
      if (sticker is Map) {
        final emoji = sticker['emoji'];
        if (emoji is String && emoji.isNotEmpty) return emoji;
      }
      return '🖼 Стикер';
    case 'voice':
      return '🎤 Голосовое сообщение';
    case 'file':
      final att = payload['attachment'];
      if (att is Map) {
        final kind = att['kind'];
        if (kind == 'image') return '🖼 Фото';
        if (kind == 'video') return '🎬 Видео';
        final name = att['name'];
        if (name is String && name.isNotEmpty) return '📎 $name';
      }
      return '📎 Файл';
    default:
      return '';
  }
}

/// Collapse newlines and excess whitespace into a single space; trim to
/// 120 chars so the chat list doesn't explode on pasted essays.
String _flattenOneLine(String s) {
  if (s.isEmpty) return '';
  final collapsed = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= 120) return collapsed;
  return '${collapsed.substring(0, 120)}…';
}

final chatListProvider = Provider<List<ChatSummary>>((ref) {
  final peersAsync = ref.watch(peersProvider);
  final metasAsync = ref.watch(chatMetasProvider);
  final connectedIds = ref.watch(connectedPeerIdsProvider);
  // Metas haven't loaded yet? Fall through with an empty map — the chat
  // list still renders with 0 unread + empty previews until the join lands
  // (sub-frame in practice).
  final metas = metasAsync.asData?.value ?? const <String, Map<String, Object?>>{};

  return peersAsync.maybeWhen(
    data: (rows) {
      final list = rows.map((row) {
        final peerId = (row['id'] as String?) ?? '';
        final displayName = (row['displayName'] as String?) ?? '';
        final customName = (row['customName'] as String?) ?? '';
        final lastSeenAt = (row['lastSeenAt'] as num?)?.toInt() ?? 0;
        final trust = _decodeTrust(row['trustLevel']);
        final blockedRaw = row['blocked'];
        final isBlocked =
            blockedRaw == true || (blockedRaw is num && blockedRaw.toInt() == 1);
        // Real "online" now — the connections registry tracks every live
        // reliable DataConnection. A row lights up green iff we have an
        // open channel to that exact peer id.
        final isOnline = peerId.isNotEmpty && connectedIds.contains(peerId);

        final meta = metas[peerId];
        final lastMessageAt = (meta?['lastTs'] as num?)?.toInt() ?? 0;
        final unreadCount = (meta?['unreadCount'] as num?)?.toInt() ?? 0;
        final preview = _buildPreview(meta?['lastData'] as Map<String, Object?>?);

        return ChatSummary(
          peerId: peerId,
          displayName: displayName,
          customName: customName,
          lastSeenAt: lastSeenAt,
          lastMessageAt: lastMessageAt,
          trust: trust,
          isOnline: isOnline,
          isBlocked: isBlocked,
          unreadCount: unreadCount,
          preview: preview,
        );
      }).where((c) => c.peerId.isNotEmpty).toList();

      // Most-recent activity first. Ties broken by display name for stability.
      list.sort((a, b) {
        final byTime = b.sortTimestamp.compareTo(a.sortTimestamp);
        if (byTime != 0) return byTime;
        return a.effectiveName
            .toLowerCase()
            .compareTo(b.effectiveName.toLowerCase());
      });
      return list;
    },
    orElse: () => const <ChatSummary>[],
  );
});

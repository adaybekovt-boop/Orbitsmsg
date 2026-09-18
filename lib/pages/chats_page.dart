// Port of `src/components/ChatListView.jsx` — the "Чаты" tab's list of
// known peers ordered by recency.
//
// Visual targets (from the JS sidebar):
//   • Section header `ЧАТЫ` in monospace caps + tracking
//   • Each peer is a rounded-2xl card on a translucent surface, NOT a
//     bare ListTile — this is the change that makes the list "feel
//     orbits-y" instead of generic Material
//   • Avatar 44 px with a 4 px online dot in the success-token colour
//   • Last-message preview gets dim-muted + truncated; peerId fallback
//     uses the monospace font so IDs line up
//   • Unread badge is an orb-gradient pill in the accent colour
//   • Active row (chat currently open in split view) carries an accent
//     ring — irrelevant on mobile where we always push to a detail page
//     but kept on desktop layout

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/chat_list_provider.dart';
import '../themes/orbits_tokens.dart';
import '../ui/peer/peer_status_pill.dart';
import '../ui/primitives/adaptive_page_frame.dart';
import '../ui/primitives/orbits_glass_app_bar.dart';
import '../ui/primitives/orbits_glass_button.dart';
import '../ui/primitives/orbits_glass_list_tile.dart';
import '../ui/primitives/orbs_card.dart';
import '../ui/profile/add_contact_page.dart';
import 'chat_view_page.dart';

class ChatsPage extends ConsumerWidget {
  const ChatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(chatListProvider);
    final tokens = OrbitsTokens.of(context);

    return Scaffold(
      appBar: OrbitsGlassAppBar(
        title: Text(
          'Чаты',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
        actions: [
          // Servers/rooms are now a first-class nav section (ServersHomePage),
          // no longer hidden behind a tiny icon here.
          OrbitsGlassIconButton(
            icon: Icons.person_add_alt_1_outlined,
            tooltip: 'Добавить контакт',
            variant: OrbitsGlassVariant.subtle,
            size: OrbitsGlassSize.small,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AddContactPage()),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AdaptivePageFrame(
        maxWidth: 620,
        child: chats.isEmpty
            ? const _EmptyState()
            : ListView.builder(
                padding: const EdgeInsets.only(
                  top: kPillReserveHeight + 4,
                  bottom: 16,
                ),
                itemCount: chats.length,
                itemBuilder: (context, i) => Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: _ChatRow(chat: chats[i]),
                ),
              ),
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({required this.chat});
  final ChatSummary chat;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);

    final initial = chat.effectiveName.isNotEmpty
        ? chat.effectiveName.characters.first.toUpperCase()
        : (chat.peerId.isNotEmpty ? chat.peerId.substring(0, 1) : '?');

    final subtitleText = chat.isBlocked
        ? 'Вы заблокировали этого пользователя'
        : (chat.preview.isNotEmpty ? chat.preview : 'Нет сообщений');
    // Never show the raw profile code as the chat subtitle — it's technical
    // noise for a normal user (the code lives in the contact's info instead).

    return OrbitsGlassListTile(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatViewPage(peerId: chat.peerId),
          ),
        );
      },
      leading: OrbsAvatar(
        fallbackInitial: initial,
        online: chat.isOnline,
        size: 44,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              chat.effectiveName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight:
                    chat.unreadCount > 0 ? FontWeight.w700 : FontWeight.w600,
                color: chat.isBlocked
                    ? tokens.text.withValues(alpha: 0.55)
                    : tokens.text,
                fontFamily: tokens.fontHeading,
              ),
            ),
          ),
          if (chat.lastMessageAt > 0) ...[
            const SizedBox(width: 8),
            Text(
              _formatChatListTime(chat.lastMessageAt),
              style: TextStyle(
                fontSize: 11,
                // Warm body font for the timestamp — mono is reserved for
                // profile codes + safety fingerprints, not everyday clocks.
                fontFamily: tokens.fontBody,
                color: chat.unreadCount > 0 ? tokens.accent : tokens.muted,
                fontWeight:
                    chat.unreadCount > 0 ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        subtitleText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontFamily: tokens.fontBody,
          color: chat.isBlocked
              ? tokens.danger.withValues(alpha: 0.85)
              : (chat.unreadCount > 0 ? tokens.text : tokens.muted),
          fontWeight: chat.unreadCount > 0 ? FontWeight.w500 : FontWeight.w400,
        ),
      ),
      trailing: SizedBox(
        width: 28,
        child: Align(
          alignment: Alignment.centerRight,
          child: chat.isBlocked
              ? Icon(Icons.block, size: 16, color: tokens.danger)
              : (chat.unreadCount > 0
                  ? _UnreadBadge(count: chat.unreadCount)
                  : _TrustBadge(trust: chat.trust)),
        ),
      ),
    );
  }
}

/// Telegram/iMessage-ish relative timestamp:
///   • today → HH:MM
///   • this week → weekday abbreviation (пн, вт, …)
///   • older → дд.мм.гг
String _formatChatListTime(int ms) {
  if (ms <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final sameDay = dt.year == now.year &&
      dt.month == now.month &&
      dt.day == now.day;
  if (sameDay) {
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
  final diff = now.difference(dt).inDays;
  if (diff < 7 && diff >= 0) {
    const weekdays = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
    return weekdays[(dt.weekday - 1).clamp(0, 6)];
  }
  final dd = dt.day.toString().padLeft(2, '0');
  final mo = dt.month.toString().padLeft(2, '0');
  final yy = (dt.year % 100).toString().padLeft(2, '0');
  return '$dd.$mo.$yy';
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final label = count > 99 ? '99+' : count.toString();
    return Container(
      constraints: const BoxConstraints(minWidth: 22, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        // Match the JS `orb-gradient` — a subtle accent → accent2 sweep.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tokens.accent, tokens.accent2],
        ),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            // White on accent gradient reads well on every theme — the
            // gradient itself is always darker than `bg`, so white wins
            // on both the dark themes (Graphite/Matrix) and the cream
            // ones (Paper/Sakura).
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            fontFamily: tokens.fontBody,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}

class _TrustBadge extends StatelessWidget {
  const _TrustBadge({required this.trust});
  final ChatTrust trust;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return switch (trust) {
      ChatTrust.verified => Tooltip(
          message: 'Проверен',
          child: Icon(Icons.verified, size: 16, color: tokens.success),
        ),
      ChatTrust.tofu => Tooltip(
          message: 'Защищён',
          child: Icon(Icons.lock_outline, size: 16, color: tokens.muted),
        ),
      ChatTrust.unknown => Tooltip(
          message: 'Нужно проверить',
          child: Icon(Icons.help_outline, size: 16, color: tokens.accent2),
        ),
    };
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: tokens.accentAlpha(0.12),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.chat_bubble_outline,
                size: 28,
                color: tokens.accent,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Пока нет чатов',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                fontFamily: tokens.fontHeading,
                color: tokens.text,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                'Добавь человека по коду или QR. '
                'Защищённый канал появится, когда транспорт будет доступен.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: tokens.muted,
                  fontFamily: tokens.fontBody,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 24),
            OrbitsGlassButton(
              label: 'Добавить контакт',
              icon: Icons.person_add_alt_1,
              variant: OrbitsGlassVariant.primary,
              size: OrbitsGlassSize.large,
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AddContactPage(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

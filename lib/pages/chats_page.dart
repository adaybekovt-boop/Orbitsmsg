// Чаты — React list (search, filters, rows) wired to chatListProvider.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/chat_list_provider.dart';
import '../themes/orbits_tokens.dart';
import '../ui/chat/contact_panel.dart';
import '../ui/layout/orbits_breakpoints.dart';
import '../ui/primitives/liquid_glass_sphere.dart';
import '../ui/primitives/orbits_glass_button.dart';
import '../ui/primitives/orbits_glass_surface.dart';
import '../ui/primitives/orbs_card.dart';
import '../ui/profile/add_contact_page.dart';
import 'chat_view_page.dart';

enum _ChatFilter { all, unread, online }

class ChatsPage extends ConsumerStatefulWidget {
  const ChatsPage({super.key});

  @override
  ConsumerState<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends ConsumerState<ChatsPage> {
  final _search = TextEditingController();
  _ChatFilter _filter = _ChatFilter.all;
  String? _selectedPeerId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ChatSummary> _visible(List<ChatSummary> chats) {
    final q = _search.text.trim().toLowerCase();
    return chats.where((c) {
      if (q.isNotEmpty) {
        final hay = '${c.effectiveName} ${c.peerId} ${c.preview}'.toLowerCase();
        if (!hay.contains(q)) return false;
      }
      switch (_filter) {
        case _ChatFilter.all:
          return true;
        case _ChatFilter.unread:
          return c.unreadCount > 0;
        case _ChatFilter.online:
          return c.isOnline && !c.isBlocked;
      }
    }).toList();
  }

  void _openChat(String peerId) {
    final wide = isWideLayout(context);
    setState(() => _selectedPeerId = peerId);
    if (wide) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ChatViewPage(peerId: peerId)));
  }

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(chatListProvider);
    final tokens = OrbitsTokens.of(context);
    final visible = _visible(chats);
    final wide = isWideLayout(context);
    final showPanel =
        showContactPanel(context) && _selectedPeerId != null && wide;
    final phonePad = isPhoneLayout(context) ? 72.0 : 16.0;

    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 20, 14, 0),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Чаты',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: tokens.fontHeading,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.6,
                          color: tokens.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: tokens.glassBorder),
                      ),
                      child: Text(
                        '${chats.length}',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: tokens.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
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
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
          child: OrbitsGlassSurface(
            role: OrbitsGlassRole.input,
            borderRadius: BorderRadius.circular(11),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Icon(Icons.search, size: 16, color: tokens.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    style: TextStyle(
                      fontFamily: tokens.fontBody,
                      fontSize: 13,
                      color: tokens.text,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Поиск',
                      hintStyle: TextStyle(color: tokens.muted, fontSize: 13),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                if (_search.text.isNotEmpty)
                  IconButton(
                    tooltip: 'Очистить',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () {
                      _search.clear();
                      setState(() {});
                    },
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      '⌘K',
                      style: TextStyle(
                        fontSize: 9,
                        color: tokens.muted,
                        fontFamily: tokens.fontMono,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _FilterChip(
                label: 'Все',
                selected: _filter == _ChatFilter.all,
                onTap: () => setState(() => _filter = _ChatFilter.all),
              ),
              _FilterChip(
                label: 'Непрочитанные',
                selected: _filter == _ChatFilter.unread,
                count: chats.where((c) => c.unreadCount > 0).length,
                onTap: () => setState(() => _filter = _ChatFilter.unread),
              ),
              _FilterChip(
                label: 'В сети',
                selected: _filter == _ChatFilter.online,
                onTap: () => setState(() => _filter = _ChatFilter.online),
              ),
            ],
          ),
        ),
        Expanded(
          child: chats.isEmpty
              ? const _EmptyState()
              : visible.isEmpty
              ? _NoMatches(query: _search.text)
              : ListView.builder(
                  padding: EdgeInsets.only(bottom: phonePad, top: 4),
                  itemCount: visible.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    child: _ChatRow(
                      chat: visible[i],
                      selected: wide && visible[i].peerId == _selectedPeerId,
                      onTap: () => _openChat(visible[i].peerId),
                    ),
                  ),
                ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(18, 0, 18, phone ? 8 : 14),
          child: Row(
            children: [
              Icon(Icons.lock_outline, size: 11, color: tokens.muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Защищённый локальный сеанс',
                  style: TextStyle(color: tokens.muted, fontSize: 10),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    Widget wrap(Widget child) =>
        Material(type: MaterialType.transparency, child: child);

    if (!wide) return wrap(list);

    return wrap(
      Row(
        children: [
          SizedBox(width: 302, child: list),
          VerticalDivider(width: 1, color: tokens.border),
          Expanded(
            child: _selectedPeerId == null
                ? const _WideEmptyConversation()
                : ChatViewPage(
                    key: ValueKey(_selectedPeerId),
                    peerId: _selectedPeerId!,
                    embedded: true,
                    onClose: () => setState(() => _selectedPeerId = null),
                  ),
          ),
          if (showPanel) ...[
            VerticalDivider(width: 1, color: tokens.border),
            SizedBox(
              width: 242,
              child: ChatContactPanel(peerId: _selectedPeerId!),
            ),
          ],
        ],
      ),
    );
  }

  bool get phone => isPhoneLayout(context);
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Material(
      color: selected
          ? tokens.glassTint.withValues(alpha: 0.9)
          : tokens.glassTint.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? tokens.glassBorder : tokens.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: selected ? tokens.text : tokens.muted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              if (count != null && count! > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: TextStyle(fontSize: 9, color: tokens.text),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.chat,
    required this.onTap,
    this.selected = false,
  });
  final ChatSummary chat;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);

    final initial = chat.effectiveName.isNotEmpty
        ? chat.effectiveName.characters.first.toUpperCase()
        : (chat.peerId.isNotEmpty ? chat.peerId.substring(0, 1) : '?');

    final subtitleText = chat.isBlocked
        ? 'Вы заблокировали этого пользователя'
        : (chat.preview.isNotEmpty ? chat.preview : 'Нет сообщений');

    return Material(
      color: selected
          ? tokens.glassTint.withValues(alpha: 0.85)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? tokens.glassBorder : Colors.transparent,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
            child: Row(
              children: [
                if (selected)
                  Container(
                    width: 2.5,
                    height: 28,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: tokens.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                OrbsAvatar(
                  fallbackInitial: initial,
                  online: chat.isOnline,
                  size: 43,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              chat.effectiveName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: chat.unreadCount > 0
                                    ? FontWeight.w700
                                    : FontWeight.w600,
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
                                fontSize: 10,
                                fontFamily: tokens.fontBody,
                                color: chat.unreadCount > 0
                                    ? tokens.accent
                                    : tokens.muted,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              subtitleText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: tokens.fontBody,
                                color: chat.isBlocked
                                    ? tokens.danger.withValues(alpha: 0.85)
                                    : tokens.muted,
                              ),
                            ),
                          ),
                          if (chat.isBlocked)
                            Icon(Icons.block, size: 14, color: tokens.danger)
                          else if (chat.unreadCount > 0)
                            _UnreadBadge(count: chat.unreadCount)
                          else
                            _TrustBadge(trust: chat.trust),
                        ],
                      ),
                    ],
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

String _formatChatListTime(int ms) {
  if (ms <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final sameDay =
      dt.year == now.year && dt.month == now.month && dt.day == now.day;
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? Colors.white : tokens.accent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: isDark ? Colors.black : Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          fontFamily: tokens.fontBody,
          height: 1.0,
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
        child: Icon(Icons.verified, size: 14, color: tokens.success),
      ),
      ChatTrust.tofu => Tooltip(
        message: 'Защищён',
        child: Icon(Icons.lock_outline, size: 14, color: tokens.muted),
      ),
      ChatTrust.unknown => const SizedBox.shrink(),
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
            const LiquidGlassSphere(size: 96),
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
                  MaterialPageRoute(builder: (_) => const AddContactPage()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, color: tokens.muted, size: 28),
            const SizedBox(height: 10),
            Text(
              'Ничего не найдено',
              style: TextStyle(
                fontFamily: tokens.fontHeading,
                fontWeight: FontWeight.w600,
                color: tokens.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              query.trim().isEmpty
                  ? 'Попробуй другой фильтр'
                  : 'Попробуй другой запрос',
              style: TextStyle(color: tokens.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _WideEmptyConversation extends StatelessWidget {
  const _WideEmptyConversation();

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LiquidGlassSphere(size: 110),
            const SizedBox(height: 18),
            Text(
              'Выберите чат',
              style: TextStyle(
                fontFamily: tokens.fontHeading,
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: tokens.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Переписка откроется рядом со списком.',
              textAlign: TextAlign.center,
              style: TextStyle(color: tokens.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

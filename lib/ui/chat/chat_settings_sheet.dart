// Per-peer chat settings bottom sheet. Opened from the chat view header
// (⋮ action or tapping the title). Lets the user:
//
//   • Rename the peer locally (customName — never broadcast back)
//   • Flip the trust level (unknown / TOFU / verified)
//   • Block / unblock (stops inbound + outbound via `messaging_notifier`)
//   • Wipe local chat history for this peer
//
// The React app spread these across multiple screens (verify dialog lived
// in the chat header, block list in Settings). For the Flutter port we
// consolidate them — a single sheet keeps the code small and matches what
// users tap their way into anyway.
//
// All writes go through `storage/db.dart` helpers which share `savePeer`
// merge semantics — a patch like `{'id':…, 'blocked': true}` leaves the
// display name / pub key / trust level alone.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/identity_key.dart' as identity_key;
import '../../core/peer_pins.dart' as peer_pins;
import '../../pages/settings/complaint_page.dart';
import '../../state/chat_list_provider.dart';
import '../../storage/db.dart' as db;
import '../../state/peers_provider.dart';
import '../primitives/orbits_glass_button.dart';
import '../primitives/orbits_glass_dialog.dart';
import '../primitives/orbits_glass_switch.dart';

class ChatSettingsSheet extends ConsumerStatefulWidget {
  const ChatSettingsSheet({super.key, required this.peerId});

  final String peerId;

  @override
  ConsumerState<ChatSettingsSheet> createState() => _ChatSettingsSheetState();
}

class _ChatSettingsSheetState extends ConsumerState<ChatSettingsSheet> {
  late final TextEditingController _nameCtl;

  /// Seed-value guard. We only want to pre-fill the text field once — on
  /// first successful peers emit. After that the user might be typing and
  /// we shouldn't clobber their draft when `peersProvider` re-emits for
  /// an unrelated reason (e.g. another peer's lastSeenAt update).
  bool _seeded = false;

  /// In-flight flag for the destructive "clear history" button. Keeps the
  /// user from double-tapping and queuing two DELETEs back-to-back.
  bool _clearing = false;

  /// Safety-number state (audit H1). Loaded once on open. `_remoteFp` is null
  /// until the peer's identity has been pinned via a verified handshake.
  String? _localFp;
  String? _remoteFp;
  bool _fpLoading = true;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController();
    _loadFingerprints();
  }

  Future<void> _loadFingerprints() async {
    String? local;
    String? remote;
    try {
      local = await identity_key.getLocalIdentityFingerprint();
    } catch (_) {}
    try {
      final pin = await peer_pins.getPin(widget.peerId);
      remote = pin?.fingerprint;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _localFp = local;
      _remoteFp = (remote != null && remote.isNotEmpty) ? remote : null;
      _fpLoading = false;
    });
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  void _seedName(Map<String, Object?> peer) {
    if (_seeded) return;
    final custom = (peer['customName'] as String?) ?? '';
    final displayName = (peer['displayName'] as String?) ?? '';
    _nameCtl.text = custom.isNotEmpty ? custom : displayName;
    _seeded = true;
  }

  Future<void> _handleSaveName() async {
    final next = _nameCtl.text.trim();
    await db.setPeerCustomName(widget.peerId, next);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            next.isEmpty ? 'Локальное имя сброшено' : 'Имя сохранено: $next',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _copyFingerprints() async {
    final mine = _localFp ?? '';
    final theirs = _remoteFp ?? '';
    await Clipboard.setData(
      ClipboardData(text: 'Мой код:\n$mine\n\nКод собеседника:\n$theirs'),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('Код скопирован'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  Future<void> _handleClearHistory() async {
    // Two-step confirm — clearing a chat is destructive and there's no
    // undo. Matches the "Очистить" confirm in the JS Settings page.
    final ok = await showOrbitsConfirm(
      context: context,
      title: 'Очистить историю?',
      message:
          'Все сообщения в этом чате будут удалены только на этом '
          'устройстве. Собеседник сохранит свою копию.',
      confirmLabel: 'Удалить',
      confirmIcon: Icons.delete_outline,
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _clearing = true);
    try {
      final deleted = await db.clearMessagesForPeer(widget.peerId);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text('Удалено сообщений: $deleted'),
            duration: const Duration(seconds: 2),
          ),
        );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final peersAsync = ref.watch(peersProvider);
    final peer = peersAsync.maybeWhen(
      data: (rows) {
        for (final r in rows) {
          if ((r['id'] as String?) == widget.peerId) return r;
        }
        return const <String, Object?>{};
      },
      orElse: () => const <String, Object?>{},
    );
    if (peer.isNotEmpty) _seedName(peer);

    final displayName = (peer['displayName'] as String?) ?? '';
    final customName = (peer['customName'] as String?) ?? '';
    final headerName = customName.isNotEmpty
        ? customName
        : (displayName.isNotEmpty ? displayName : widget.peerId);
    final isBlocked =
        peer['blocked'] == true ||
        (peer['blocked'] is num && (peer['blocked'] as num).toInt() == 1);
    final trust = _decodeTrust(peer['trustLevel']);

    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 8,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Header ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: scheme.primaryContainer,
                    child: Text(
                      headerName.trim().isNotEmpty
                          ? headerName.trim().characters.first.toUpperCase()
                          : '?',
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          headerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Код контакта · ${widget.peerId}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── Rename ──────────────────────────────────────────────
            const _SectionLabel(text: 'Локальное имя'),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtl,
              maxLength: 64,
              decoration: InputDecoration(
                hintText: displayName.isNotEmpty
                    ? displayName
                    : 'Ник собеседника',
                border: const OutlineInputBorder(),
                counterText: '',
                suffixIcon: IconButton(
                  tooltip: 'Сохранить',
                  icon: const Icon(Icons.check),
                  onPressed: _handleSaveName,
                ),
              ),
              onSubmitted: (_) => _handleSaveName(),
            ),
            const SizedBox(height: 6),
            Text(
              'Видно только вам. Не перезаписывается, когда собеседник '
              'меняет профиль.',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),

            const SizedBox(height: 20),

            // ── Trust level ─────────────────────────────────────────
            const _SectionLabel(text: 'Статус контакта'),
            const SizedBox(height: 8),
            SegmentedButton<ChatTrust>(
              segments: const [
                ButtonSegment(
                  value: ChatTrust.unknown,
                  label: Text('Нужно проверить'),
                  icon: Icon(Icons.help_outline),
                ),
                ButtonSegment(
                  value: ChatTrust.tofu,
                  label: Text('Защищён'),
                  icon: Icon(Icons.lock_outline),
                ),
                ButtonSegment(
                  value: ChatTrust.verified,
                  label: Text('Проверен'),
                  icon: Icon(Icons.verified_user),
                ),
              ],
              selected: {trust},
              onSelectionChanged: (sel) async {
                final next = sel.first;
                final level = switch (next) {
                  ChatTrust.unknown => 0,
                  ChatTrust.tofu => 1,
                  ChatTrust.verified => 2,
                };
                await db.setPeerTrustLevel(widget.peerId, level);
              },
            ),
            const SizedBox(height: 6),
            Text(
              '«Защищён» — связь зашифрована автоматически при первом '
              'соединении. «Проверен» отметьте сами, когда сверите код '
              'безопасности с собеседником.',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),

            const SizedBox(height: 20),

            // ── Safety number (key fingerprints) ────────────────────
            const _SectionLabel(text: 'Код безопасности контакта'),
            const SizedBox(height: 8),
            _SafetyNumber(
              loading: _fpLoading,
              localFp: _localFp,
              remoteFp: _remoteFp,
              verified: trust == ChatTrust.verified,
              onCopy: _copyFingerprints,
            ),

            const SizedBox(height: 20),

            // ── Block toggle ────────────────────────────────────────
            Material(
              color: scheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: scheme.onSurface.withValues(alpha: 0.12),
                ),
              ),
              child: ListTile(
                onTap: () => db.setPeerBlocked(widget.peerId, !isBlocked),
                leading: Icon(
                  Icons.block,
                  color: isBlocked
                      ? scheme.error
                      : scheme.onSurface.withValues(alpha: 0.5),
                ),
                title: const Text('Заблокировать'),
                subtitle: Text(
                  isBlocked
                      ? 'Сообщения от этого собеседника не будут '
                            'приниматься и отправляться.'
                      : 'Принимать входящие и отправлять сообщения.',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                trailing: OrbitsGlassSwitch(
                  value: isBlocked,
                  onChanged: (v) => db.setPeerBlocked(widget.peerId, v),
                  semanticLabel: 'Заблокировать собеседника',
                ),
              ),
            ),

            const SizedBox(height: 20),

            // ── Destructive: clear history ──────────────────────────
            OrbitsGlassButton(
              label: 'Пожаловаться на собеседника',
              icon: Icons.report_outlined,
              variant: OrbitsGlassVariant.subtle,
              expand: true,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ComplaintPage(peerId: widget.peerId),
                ),
              ),
            ),

            const SizedBox(height: 20),

            OrbitsGlassButton(
              label: _clearing ? 'Удаление...' : 'Очистить историю',
              icon: Icons.delete_outline,
              variant: OrbitsGlassVariant.danger,
              expand: true,
              enabled: !_clearing,
              onPressed: _clearing ? null : _handleClearHistory,
            ),
          ],
        ),
      ),
    );
  }
}

/// Internal: decode the int-valued `trustLevel` column into the shared
/// enum. Duplicated from chat_list_provider.dart so the sheet stays
/// self-contained — the Chat list provider's private helper is
/// intentionally not re-exported.
ChatTrust _decodeTrust(Object? raw) {
  final v = (raw as num?)?.toInt() ?? 0;
  return switch (v) {
    >= 2 => ChatTrust.verified,
    1 => ChatTrust.tofu,
    _ => ChatTrust.unknown,
  };
}

/// Group a 64-hex-char SHA-256 fingerprint into space-separated 4-char blocks,
/// uppercased, for easier out-of-band reading ("compare these aloud").
String _formatFingerprint(String fp) {
  final s = fp.toUpperCase();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i += 4) {
    if (i > 0) buf.write(' ');
    buf.write(s.substring(i, i + 4 > s.length ? s.length : i + 4));
  }
  return buf.toString();
}

/// Safety-number block: shows the local + remote key fingerprints so the user
/// can compare them out-of-band before trusting the channel (audit H1).
class _SafetyNumber extends StatelessWidget {
  const _SafetyNumber({
    required this.loading,
    required this.localFp,
    required this.remoteFp,
    required this.verified,
    required this.onCopy,
  });

  final bool loading;
  final String? localFp;
  final String? remoteFp;
  final bool verified;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hint = TextStyle(
      fontSize: 11,
      color: scheme.onSurface.withValues(alpha: 0.6),
    );

    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (remoteFp == null) {
      return Text(
        'Код безопасности появится после первого защищённого '
        'соединения с этим контактом.',
        style: hint,
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.12)),
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                verified ? Icons.verified_user : Icons.shield_outlined,
                size: 16,
                color: verified
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 6),
              Text(
                verified ? 'Контакт проверен' : 'Проверь контакт',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: verified ? scheme.primary : scheme.onSurface,
                ),
              ),
              const Spacer(),
              OrbitsGlassIconButton(
                icon: Icons.copy,
                tooltip: 'Скопировать',
                variant: OrbitsGlassVariant.subtle,
                size: OrbitsGlassSize.small,
                onPressed: onCopy,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Собеседник', style: hint),
          const SizedBox(height: 2),
          SelectableText(
            _formatFingerprint(remoteFp!),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.4,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text('Вы', style: hint),
          const SizedBox(height: 2),
          SelectableText(
            localFp == null ? '—' : _formatFingerprint(localFp!),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.4,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Сравните этот код с собеседником, чтобы убедиться, что '
            'переписку никто не подменил. Сверять удобно лично или по '
            'звонку. Совпал — отметьте «Проверен» выше.',
            style: hint,
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
      ),
    );
  }
}

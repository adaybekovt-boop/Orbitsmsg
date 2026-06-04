// Orbits Drop — the P2P file-transfer tab.
//
// Pick a peer, pick a file, and stream it straight over the encrypted
// DataChannel via [DropNotifier] / the Drop engine. Incoming files land in the
// transfers list with a live progress bar and (once integrity-verified) a
// Save button. Mirrors the JS `src/components/drop/*` UX at a high level.

import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';

import '../core/attachment_preview.dart' show formatBytes;
import '../core/orbits_drop.dart' show DropDirection;
import '../state/connections_notifier.dart';
import '../state/drop_provider.dart';
import '../state/peers_provider.dart';
import '../storage/db.dart' as db;
import '../themes/orbits_tokens.dart';
import '../ui/peer/peer_status_pill.dart';
import '../ui/primitives/adaptive_page_frame.dart';
import '../ui/primitives/orbits_glass_button.dart';
import '../ui/primitives/orbits_glass_app_bar.dart';
import '../ui/primitives/orbits_glass_surface.dart';
import '../ui/profile/add_contact_page.dart';
import '../ui/chat/web_download_stub.dart'
    if (dart.library.html) '../ui/chat/web_download_html.dart' as web_download;

class DropPage extends ConsumerStatefulWidget {
  const DropPage({super.key});

  @override
  ConsumerState<DropPage> createState() => _DropPageState();
}

class _DropPageState extends ConsumerState<DropPage> {
  String? _sendingToPeer; // peerId currently mid-pick/send, for the spinner

  Future<void> _pickAndSend(String peerId) async {
    if (_sendingToPeer != null) return;
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform
          .pickFiles(type: FileType.any, allowMultiple: false, withData: true);
    } catch (_) {
      _toast('Не удалось открыть файловый выбор');
      return;
    }
    if (picked == null || picked.files.isEmpty) return;
    final pf = picked.files.single;

    Uint8List? bytes = pf.bytes;
    if ((bytes == null || bytes.isEmpty) && pf.path != null) {
      try {
        bytes = await File(pf.path!).readAsBytes();
      } catch (_) {
        bytes = null;
      }
    }
    if (bytes == null || bytes.isEmpty) {
      _toast('Не удалось прочитать файл');
      return;
    }

    final name = pf.name;
    final mime = lookupMimeType(name) ?? 'application/octet-stream';

    setState(() => _sendingToPeer = peerId);
    try {
      final id = await ref
          .read(dropNotifierProvider.notifier)
          .sendFile(peerId, bytes, name: name, mime: mime);
      if (id == null) _toast('Нет соединения с получателем');
    } finally {
      if (mounted) setState(() => _sendingToPeer = null);
    }
  }

  Future<void> _saveReceived(DropTransfer t) async {
    final blobId = t.blobId;
    if (blobId == null) return;
    try {
      final row = await db.getFileBlob(blobId);
      final bytes = row?['blob'];
      if (bytes is! Uint8List || bytes.isEmpty) {
        _toast('Файл недоступен');
        return;
      }
      final safeName = _safeFilename(t.name);
      if (kIsWeb) {
        web_download.triggerBrowserDownload(
          bytes: bytes,
          filename: safeName,
          mime: t.mime,
        );
        _toast('Файл скачан: $safeName');
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}${Platform.pathSeparator}$safeName');
        await file.writeAsBytes(bytes, flush: true);
        _toast('Сохранено: $safeName');
      }
    } catch (_) {
      _toast('Не удалось сохранить файл');
    }
  }

  String _safeFilename(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'file' : cleaned;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final peersAsync = ref.watch(peersProvider);
    final connected = ref.watch(
      connectionsNotifierProvider.select((s) => s.connectedPeerIds),
    );
    final transfers = ref.watch(
      dropNotifierProvider.select((s) => s.transfers),
    );
    final peers = peersAsync.maybeWhen(
      data: (rows) => rows,
      orElse: () => const <Map<String, Object?>>[],
    );

    return Scaffold(
      appBar: OrbitsGlassAppBar(
        title: Text(
          'Drop',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
      ),
      body: AdaptivePageFrame(
        maxWidth: 880,
        child: (peers.isEmpty && transfers.isEmpty)
            ? _buildEmptyState(tokens)
            : ListView(
                padding: const EdgeInsets.only(
                    top: kPillReserveHeight + 12, bottom: 24),
                children: [
                  _hero(tokens),
                  if (transfers.isNotEmpty) ...[
                    _SectionHeader(text: 'Передачи', tokens: tokens),
                    for (final t in transfers)
                      _TransferRow(
                        transfer: t,
                        tokens: tokens,
                        onCancel: () =>
                            ref.read(dropNotifierProvider.notifier).cancel(t.id),
                        onDismiss: () => ref
                            .read(dropNotifierProvider.notifier)
                            .dismiss(t.id),
                        onSave: () => _saveReceived(t),
                      ),
                  ],
                  _SectionHeader(text: 'Отправить контакту', tokens: tokens),
                  if (peers.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: _emptyCard(tokens),
                    )
                  else
                    for (final p in peers)
                      _PeerSendRow(
                        peer: p,
                        online: connected.contains((p['id'] as String?) ?? ''),
                        busy: _sendingToPeer == (p['id'] as String?),
                        tokens: tokens,
                        onTap: () {
                          final id = (p['id'] as String?) ?? '';
                          if (id.isNotEmpty) _pickAndSend(id);
                        },
                      ),
                ],
              ),
      ),
    );
  }

  Widget _hero(OrbitsTokens tokens) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: tokens.accentAlpha(0.14),
                shape: BoxShape.circle,
                border: Border.all(color: tokens.accentAlpha(0.3)),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.swap_vert, size: 32, color: tokens.accent),
            ),
            const SizedBox(height: 14),
            Text(
              'Orbits Drop',
              style: TextStyle(
                fontFamily: tokens.fontHeading,
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: tokens.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Выбери контакт и файл. Передача идёт напрямую между устройствами.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: tokens.fontBody, fontSize: 13, color: tokens.muted),
            ),
          ],
        ),
      );

  /// Full centered empty state — shown when there are no contacts and no
  /// transfers. A single glass card with a clear call to action.
  Widget _buildEmptyState(OrbitsTokens tokens) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: _emptyCard(tokens),
          ),
        ),
      );

  Widget _emptyCard(OrbitsTokens tokens) => OrbitsGlassSurface(
        role: OrbitsGlassRole.card,
        borderRadius: BorderRadius.circular(tokens.radiusCard),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: tokens.accentAlpha(0.14),
                shape: BoxShape.circle,
                border: Border.all(color: tokens.accentAlpha(0.3)),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.send_outlined, size: 28, color: tokens.accent),
            ),
            const SizedBox(height: 18),
            Text(
              'Некому отправить файл',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: tokens.fontHeading,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: tokens.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Добавь контакт, чтобы отправлять файлы напрямую между '
              'устройствами.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: tokens.fontBody,
                fontSize: 14,
                height: 1.5,
                color: tokens.muted,
              ),
            ),
            const SizedBox(height: 20),
            OrbitsGlassButton(
              label: 'Добавить контакт',
              icon: Icons.person_add_alt_1,
              variant: OrbitsGlassVariant.primary,
              size: OrbitsGlassSize.large,
              onPressed: _openAddContact,
            ),
          ],
        ),
      );

  void _openAddContact() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AddContactPage()),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.text, required this.tokens});
  final String text;
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: tokens.muted,
          ),
        ),
      );
}

class _PeerSendRow extends StatelessWidget {
  const _PeerSendRow({
    required this.peer,
    required this.online,
    required this.busy,
    required this.tokens,
    required this.onTap,
  });

  final Map<String, Object?> peer;
  final bool online;
  final bool busy;
  final OrbitsTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final id = (peer['id'] as String?) ?? '';
    final custom = (peer['customName'] as String?) ?? '';
    final display = (peer['displayName'] as String?) ?? '';
    final label = custom.isNotEmpty ? custom : (display.isNotEmpty ? display : id);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: OrbitsGlassSurface(
        role: OrbitsGlassRole.card,
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: busy ? null : onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  Stack(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: tokens.accentAlpha(0.16),
                        child: Text(
                          label.trim().isNotEmpty
                              ? label.trim().characters.first.toUpperCase()
                              : '?',
                          style: TextStyle(
                              color: tokens.accent, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (online)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 11,
                            height: 11,
                            decoration: BoxDecoration(
                              color: tokens.success,
                              shape: BoxShape.circle,
                              border: Border.all(color: tokens.bg, width: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: tokens.fontBody,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: tokens.text,
                          ),
                        ),
                        Text(
                          online
                              ? 'В сети'
                              : 'Не в сети — подключимся при отправке',
                          style: TextStyle(fontSize: 12, color: tokens.muted),
                        ),
                      ],
                    ),
                  ),
                  busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.upload_file, color: tokens.accent),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({
    required this.transfer,
    required this.tokens,
    required this.onCancel,
    required this.onDismiss,
    required this.onSave,
  });

  final DropTransfer transfer;
  final OrbitsTokens tokens;
  final VoidCallback onCancel;
  final VoidCallback onDismiss;
  final VoidCallback onSave;

  /// Map an internal failure reason to a short, human status line. We never
  /// surface raw integrity/exception wording — the user only needs to know
  /// the file didn't go through. The reason string is matched loosely so we
  /// stay resilient to upstream wording tweaks.
  static String _failureText(String? reason, bool incoming) {
    final r = (reason ?? '').toLowerCase();
    if (r.contains('целостн') || r.contains('повреж')) {
      return 'Проверка файла не прошла';
    }
    if (r.contains('отмен')) {
      return 'Передача отменена';
    }
    if (r.contains('сохран')) {
      return 'Файл не удалось сохранить';
    }
    return incoming ? 'Передача прервана' : 'Файл не удалось отправить';
  }

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final incoming = t.direction == DropDirection.incoming;
    final active = t.status == DropStatus.active;
    final completed = t.status == DropStatus.completed;
    final failed = t.status == DropStatus.failed;

    final IconData icon;
    final Color iconColor;
    if (failed) {
      icon = Icons.error_outline;
      iconColor = tokens.danger;
    } else if (completed) {
      icon = Icons.check_circle;
      iconColor = tokens.success;
    } else {
      icon = incoming ? Icons.download : Icons.upload;
      iconColor = tokens.accent;
    }

    final subtitle = failed
        ? _failureText(t.error, incoming)
        : completed
            ? (incoming ? 'Получено · ${formatBytes(t.size)}' : 'Отправлено · ${formatBytes(t.size)}')
            : '${formatBytes(t.transferred)} / ${formatBytes(t.size)} · ${(t.progress * 100).round()}%';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: OrbitsGlassSurface(
        role: OrbitsGlassRole.card,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: iconColor, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: tokens.fontBody,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: tokens.text,
                          ),
                        ),
                        Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(fontSize: 12, color: tokens.muted)),
                      ],
                    ),
                  ),
                  if (active && !incoming)
                    OrbitsGlassIconButton(
                      icon: Icons.close,
                      tooltip: 'Отменить',
                      variant: OrbitsGlassVariant.subtle,
                      size: OrbitsGlassSize.small,
                      onPressed: onCancel,
                    )
                  else if (completed && incoming && t.blobId != null)
                    OrbitsGlassIconButton(
                      icon: Icons.save_alt,
                      tooltip: 'Сохранить',
                      variant: OrbitsGlassVariant.subtle,
                      size: OrbitsGlassSize.small,
                      onPressed: onSave,
                    )
                  else if (!active)
                    OrbitsGlassIconButton(
                      icon: Icons.close,
                      tooltip: 'Убрать',
                      variant: OrbitsGlassVariant.subtle,
                      size: OrbitsGlassSize.small,
                      onPressed: onDismiss,
                    ),
                ],
              ),
              if (active) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: t.size == 0 ? null : t.progress,
                    minHeight: 4,
                    backgroundColor: tokens.accentAlpha(0.15),
                    color: tokens.accent,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

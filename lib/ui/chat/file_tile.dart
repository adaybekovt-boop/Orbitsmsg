// File attachment tile — renders a single inbound / outbound file row in
// a message bubble. Port of `src/components/AttachmentBubble.jsx`.
//
// Three visual variants, dispatched on `attachment.kind`:
//   • image  — 260-max-width thumbnail bubble with original aspect ratio.
//              Tap → full-screen dialog with Image.memory + pinch-to-zoom.
//   • video  — same 260 thumbnail with a centred play overlay. Tap → full
//              download + toast (in-line video playback needs `video_player`
//              which we haven't pulled in for Day 4; we'll revisit if users
//              miss it).
//   • file   — 220–320 horizontal pill with a MIME-derived icon + name +
//              human-readable size + download chevron.
//
// Wire-format notes (see `docs/research-day4-js-voice-file.md`):
//   • `attachment.thumb` is a FULL data URL (`data:image/jpeg;base64,...`),
//     unlike `attachment.b64` which is raw base64. The asymmetry is a
//     carry-over from the JS peer — we render the thumb by stripping the
//     `data:...;base64,` prefix and decoding the rest.
//   • `attachment.kind` is trusted verbatim — the sender's classification
//     wins, even if it doesn't match `mime` (JS peer does the same).
//   • `attachment.missing == true` means the b64 never landed (oversize /
//     decode-failed on receive). The thumb still renders; download is
//     disabled; the tile grays out slightly.
//
// Download path on Flutter: without `open_file` / `share_plus` in deps we
// fall back to writing the blob into the app documents directory and
// surfacing a snackbar with the filename. The user can pull it off the
// device via the platform file browser. Good enough for MVP — revisit
// when we add proper share-intents on Day 5+.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../storage/db.dart' as db;
import 'web_download_stub.dart'
    if (dart.library.html) 'web_download_html.dart' as web_download;

class FileTile extends StatefulWidget {
  const FileTile({
    super.key,
    required this.msgId,
    required this.attachment,
    required this.mine,
  });

  /// Row id the bytes are keyed under in `file_blobs`.
  final String msgId;

  /// The `payload.attachment` map: `{name, size, mime, kind, thumb?,
  /// width?, height?, duration?, missing?}`. Never null — the bubble
  /// only mounts us on rows where attachment was persisted.
  final Map<String, Object?> attachment;

  /// Mine = my outbound bubble (translucent white tint on primary fill).
  /// Peer = their bubble (surface-container tint).
  final bool mine;

  @override
  State<FileTile> createState() => _FileTileState();
}

class _FileTileState extends State<FileTile> {
  /// True while `_loadBytes` is mid-flight. Gates the play / open actions
  /// so a double-tap doesn't spawn two decoders.
  bool _busy = false;

  /// Flipped to true once we've tried to hydrate the blob and failed
  /// (missing row, IO error). Disables the action button thereafter.
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final kind = (widget.attachment['kind'] as String?) ?? 'file';
    // `missing:true` from the decoder means b64 never landed. We can still
    // show the thumb (if any), just not download.
    final missing = widget.attachment['missing'] == true;

    switch (kind) {
      case 'image':
        return _buildImage(context, missing: missing);
      case 'video':
        return _buildVideo(context, missing: missing);
      case 'audio':
      case 'file':
      default:
        return _buildFilePill(context, missing: missing);
    }
  }

  // ── Image variant ───────────────────────────────────────────────────

  Widget _buildImage(BuildContext context, {required bool missing}) {
    final scheme = Theme.of(context).colorScheme;
    final name = (widget.attachment['name'] as String?) ?? 'image';
    final size = _asInt(widget.attachment['size']);
    final width = _asInt(widget.attachment['width']);
    final height = _asInt(widget.attachment['height']);
    // JS uses `width/height || 4/3`; we match so rows without metadata
    // don't collapse to a zero-height strip.
    final aspect =
        width > 0 && height > 0 ? width / height : 4 / 3;
    final thumbBytes = _decodeThumb(widget.attachment['thumb']);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: aspect,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.2),
                    child: thumbBytes != null
                        ? Image.memory(
                            thumbBytes,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            // Force the decoder to rasterise at the actual
                            // on-screen size (max bubble width 260 logical
                            // px × DPR). Without this the JPEG inside
                            // `thumbBytes` decodes at native resolution —
                            // a 4032×3024 phone shot eats 49 MB of bitmap
                            // RAM regardless of the visible 260×195 tile.
                            cacheWidth: (260 *
                                    MediaQuery.devicePixelRatioOf(context))
                                .round(),
                          )
                        : Center(
                            child: Text(
                              missing ? 'нет превью' : 'Изображение',
                              style: TextStyle(
                                color: scheme.onSurface
                                    .withValues(alpha: 0.6),
                                fontSize: 12,
                              ),
                            ),
                          ),
                  ),
                ),
                // Tap area — whole tile opens the full-screen viewer.
                Positioned.fill(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: missing ? null : () => _openImageViewer(context),
                    ),
                  ),
                ),
                if (_busy)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          _FooterRow(
            name: name,
            size: size,
            mime: (widget.attachment['mime'] as String?) ?? '',
            mine: widget.mine,
            missing: missing,
            onDownload: missing ? null : () => _saveToDocuments(context),
          ),
        ],
      ),
    );
  }

  // ── Video variant ───────────────────────────────────────────────────

  Widget _buildVideo(BuildContext context, {required bool missing}) {
    final scheme = Theme.of(context).colorScheme;
    final name = (widget.attachment['name'] as String?) ?? 'video';
    final size = _asInt(widget.attachment['size']);
    final width = _asInt(widget.attachment['width']);
    final height = _asInt(widget.attachment['height']);
    // JS uses 16:9 as the fallback for video since the recorder hints
    // landscape. We match so vertical phone clips don't get cropped but
    // unknown-dimension clips still sit in a reasonable aspect.
    final aspect =
        width > 0 && height > 0 ? width / height : 16 / 9;
    final thumbBytes = _decodeThumb(widget.attachment['thumb']);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: aspect,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.3),
                    child: thumbBytes != null
                        ? Image.memory(
                            thumbBytes,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            // Same downscale budget as the image variant —
                            // video poster frames can also be huge.
                            cacheWidth: (260 *
                                    MediaQuery.devicePixelRatioOf(context))
                                .round(),
                          )
                        : Center(
                            child: Text(
                              missing ? 'видео недоступно' : 'Видео',
                              style: TextStyle(
                                color: scheme.onSurface
                                    .withValues(alpha: 0.6),
                                fontSize: 12,
                              ),
                            ),
                          ),
                  ),
                ),
                // Centred play overlay — tap saves-to-doc and toasts.
                // (Inline playback needs `video_player` which we haven't
                // pulled in; this is the MVP fallback.)
                Positioned.fill(
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.15),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap:
                          missing ? null : () => _saveToDocuments(context),
                      child: Center(
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.white
                                .withValues(alpha: missing ? 0.4 : 0.9),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Icon(
                            _busy ? Icons.hourglass_top : Icons.play_arrow,
                            color: Colors.black,
                            size: 26,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          _FooterRow(
            name: name,
            size: size,
            mime: (widget.attachment['mime'] as String?) ?? '',
            mine: widget.mine,
            missing: missing,
            onDownload: missing ? null : () => _saveToDocuments(context),
          ),
        ],
      ),
    );
  }

  // ── Generic file pill ────────────────────────────────────────────────

  Widget _buildFilePill(BuildContext context, {required bool missing}) {
    final scheme = Theme.of(context).colorScheme;
    final name = (widget.attachment['name'] as String?) ?? 'file';
    final mime = (widget.attachment['mime'] as String?) ?? '';
    final size = _asInt(widget.attachment['size']);
    final iconData = _fileIconFor(mime: mime, name: name);

    // Palette matches the JS build: mine → translucent white on primary,
    // peer → surfaceContainer fill on the chat canvas.
    final bg = widget.mine
        ? Colors.white.withValues(alpha: 0.1)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.85);
    final fg = widget.mine ? scheme.onPrimary : scheme.onSurface;
    final iconBg = widget.mine
        ? Colors.white.withValues(alpha: 0.18)
        : scheme.primary.withValues(alpha: 0.15);
    final iconFg = widget.mine ? scheme.onPrimary : scheme.primary;

    return Opacity(
      opacity: missing ? 0.6 : 1.0,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: missing ? null : () => _saveToDocuments(context),
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(minWidth: 220, maxWidth: 320),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: iconBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: _busy
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(iconFg),
                            ),
                          )
                        : Icon(iconData, color: iconFg, size: 22),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: fg,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _fileSubtitle(size, mime, missing: missing),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: fg.withValues(alpha: 0.65),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!missing) ...[
                    const SizedBox(width: 8),
                    Icon(
                      Icons.file_download_outlined,
                      size: 18,
                      color: fg.withValues(alpha: 0.7),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Actions ─────────────────────────────────────────────────────────

  /// Load the blob bytes + push up a full-screen viewer for images. The
  /// viewer uses `Image.memory` wrapped in `InteractiveViewer` so users
  /// can pinch-zoom and pan. Close via the top-left ✕ or back gesture.
  Future<void> _openImageViewer(BuildContext context) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await _loadBytes();
      if (!mounted || !context.mounted) return;
      if (bytes == null) {
        _showToast('Изображение недоступно');
        return;
      }
      await Navigator.of(context).push(
        PageRouteBuilder<void>(
          opaque: true,
          barrierDismissible: true,
          barrierColor: Colors.black,
          pageBuilder: (_, __, ___) => _ImageViewer(
            bytes: bytes,
            name: (widget.attachment['name'] as String?) ?? 'image',
          ),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Write the blob to the app documents dir + toast. On failure, flips
  /// `_failed` so subsequent taps no-op instead of spinning forever.
  Future<void> _saveToDocuments(BuildContext context) async {
    if (_busy || _failed) return;
    setState(() => _busy = true);
    try {
      final bytes = await _loadBytes();
      if (!mounted) return;
      if (bytes == null) {
        _showToast('Файл недоступен');
        setState(() => _failed = true);
        return;
      }
      final name = (widget.attachment['name'] as String?) ?? 'file';
      final safeName = _safeFilename(name);
      if (kIsWeb) {
        // Browsers don't expose a writable file system to Dart — hand
        // the bytes off to the conditional-import helper which triggers
        // the standard "Save As" download via a hidden anchor. The
        // browser appends its own " (n)" when the user already has a
        // file by that name in Downloads, so we skip our own
        // disambiguation here.
        final mime =
            (widget.attachment['mime'] as String?) ?? 'application/octet-stream';
        web_download.triggerBrowserDownload(
          bytes: bytes,
          filename: safeName,
          mime: mime,
        );
        if (!mounted) return;
        HapticFeedback.mediumImpact();
        _showToast('Файл скачан: $safeName');
      } else {
        final dir = await getApplicationDocumentsDirectory();
        // Avoid silent overwrites: if a file with the same name exists,
        // append ` (n)` before the extension. Matches how desktop file
        // browsers disambiguate duplicate downloads.
        final finalName =
            await _uniqueFilename(dir.path, safeName);
        final file =
            File('${dir.path}${Platform.pathSeparator}$finalName');
        await file.writeAsBytes(bytes, flush: true);
        if (!mounted) return;
        HapticFeedback.mediumImpact();
        _showToast('Сохранено: $finalName');
      }
    } catch (_) {
      if (!mounted) return;
      _showToast('Не удалось сохранить файл');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Uint8List?> _loadBytes() async {
    try {
      final row = await db.getFileBlob(widget.msgId);
      if (row == null) return null;
      final b = row['blob'];
      if (b is Uint8List && b.isNotEmpty) return b;
      return null;
    } catch (_) {
      return null;
    }
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
        ),
      );
  }
}

/// Strip illegal path characters from a filename so `File(...)` on
/// Windows / iOS doesn't reject it. Matches the set the OS file APIs
/// complain about; we keep extensions intact.
String _safeFilename(String name) {
  // Coerce to <= 200 chars (matches `_maxFileNameLen` on the notifier).
  final trimmed = name.length > 200 ? name.substring(0, 200) : name;
  final sanitized = trimmed.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return sanitized.isEmpty ? 'file' : sanitized;
}

/// If a file called [name] already exists in [dirPath], return a
/// disambiguated variant ("photo (1).jpg"). Probes up to 64 suffixes;
/// past that we fall back to a timestamp so we never loop forever on
/// a genuinely packed directory.
Future<String> _uniqueFilename(String dirPath, String name) async {
  final candidate = File('$dirPath${Platform.pathSeparator}$name');
  if (!await candidate.exists()) return name;
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 1; i <= 64; i++) {
    final try_ = '$base ($i)$ext';
    final f = File('$dirPath${Platform.pathSeparator}$try_');
    if (!await f.exists()) return try_;
  }
  final ts = DateTime.now().millisecondsSinceEpoch;
  return '$base-$ts$ext';
}

/// Footer row shared by image + video tiles: truncated name + optional
/// size chip + optional download button. Matches the JS layout beat.
class _FooterRow extends StatelessWidget {
  const _FooterRow({
    required this.name,
    required this.size,
    required this.mime,
    required this.mine,
    required this.missing,
    required this.onDownload,
  });

  final String name;
  final int size;
  final String mime;
  final bool mine;
  final bool missing;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = mine
        ? scheme.onPrimary.withValues(alpha: 0.8)
        : scheme.onSurface.withValues(alpha: 0.75);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (size > 0 || missing)
                  Text(
                    _fileSubtitle(size, mime, missing: missing),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.7),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          if (onDownload != null) ...[
            const SizedBox(width: 6),
            InkResponse(
              onTap: onDownload,
              radius: 16,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.file_download_outlined,
                  size: 16,
                  color: textColor,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Full-screen image viewer used by the image tile. Pinch + pan, tap
/// outside to close. Kept lean — no share menu yet (Day 5 item).
class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.bytes, required this.name});

  final Uint8List bytes;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.4),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      body: GestureDetector(
        onTap: () => Navigator.of(context).maybePop(),
        child: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 6.0,
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────

/// Decode a `data:...;base64,<payload>` thumb URL to raw bytes. Returns
/// null for missing / malformed input rather than throwing — a broken
/// thumb shouldn't take out the whole bubble.
Uint8List? _decodeThumb(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  final idx = raw.indexOf('base64,');
  if (idx < 0) return null;
  try {
    final payload = raw.substring(idx + 'base64,'.length);
    return base64Decode(payload);
  } catch (_) {
    return null;
  }
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

/// Human-readable byte size, matches `formatBytes` in the JS build
/// (`src/core/attachmentPreview.js:22-28`). Units in Russian.
String _formatBytes(int n) {
  if (n < 1024) return '$n Б';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} КБ';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} ГБ';
}

/// Subtitle line under the filename. Mirrors the JS priority:
/// size > mime fallback > "файл". `missing` appends " • недоступен".
String _fileSubtitle(int size, String mime, {required bool missing}) {
  String base;
  if (size > 0) {
    base = _formatBytes(size);
  } else if (mime.isNotEmpty) {
    base = mime;
  } else {
    base = 'файл';
  }
  if (missing) base = '$base • недоступен';
  return base;
}

/// Map a MIME type + filename to a Material icon. Mirrors the bucket
/// layout in `src/utils/fileIcon.jsx`: extension match beats MIME;
/// falls back to a generic file icon.
IconData _fileIconFor({required String mime, required String name}) {
  // Extension match wins — filename lowercased, last `.xxx` looked up
  // against the bucket tables below.
  final dot = name.lastIndexOf('.');
  if (dot > -1 && dot < name.length - 1) {
    final ext = name.substring(dot + 1).toLowerCase();
    final hit = _extIcon(ext);
    if (hit != null) return hit;
  }
  final lower = mime.toLowerCase();
  if (lower.startsWith('image/')) return Icons.image_outlined;
  if (lower.startsWith('video/')) return Icons.movie_outlined;
  if (lower.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (lower.startsWith('text/')) return Icons.description_outlined;
  if (lower == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (lower == 'application/zip' ||
      lower == 'application/x-tar' ||
      lower == 'application/x-rar' ||
      lower == 'application/x-7z' ||
      lower == 'application/gzip') {
    return Icons.folder_zip_outlined;
  }
  if (lower.startsWith('application/vnd.ms-excel') ||
      lower.startsWith(
          'application/vnd.openxmlformats-officedocument.spreadsheetml')) {
    return Icons.table_chart_outlined;
  }
  if (lower.startsWith('application/vnd.ms-word') ||
      lower == 'application/msword' ||
      lower.startsWith(
          'application/vnd.openxmlformats-officedocument.wordprocessingml')) {
    return Icons.description_outlined;
  }
  if (lower == 'application/json' || lower == 'application/xml') {
    return Icons.code_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

/// Extension → icon bucket. Mirrors `EXT_MAP` in
/// `src/utils/fileIcon.jsx`. Returns null when no bucket matches so the
/// caller can try MIME next.
IconData? _extIcon(String ext) {
  // Images
  const images = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'heic', 'bmp', 'tiff',
  };
  if (images.contains(ext)) return Icons.image_outlined;
  // Video
  const videos = {'mp4', 'mov', 'webm', 'mkv', 'avi', 'm4v'};
  if (videos.contains(ext)) return Icons.movie_outlined;
  // Audio
  const audios = {
    'mp3', 'wav', 'ogg', 'flac', 'm4a', 'aac', 'opus',
  };
  if (audios.contains(ext)) return Icons.audiotrack_outlined;
  // Archives
  const archives = {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'};
  if (archives.contains(ext)) return Icons.folder_zip_outlined;
  // Code
  const code = {
    'js', 'ts', 'jsx', 'tsx', 'py', 'rb', 'go', 'rs', 'java',
    'c', 'cpp', 'h', 'hpp', 'cs', 'php', 'sh', 'html', 'css',
    'json', 'xml', 'yaml', 'yml', 'toml',
  };
  if (code.contains(ext)) return Icons.code_outlined;
  // Spreadsheets
  const sheets = {'xls', 'xlsx', 'csv', 'ods'};
  if (sheets.contains(ext)) return Icons.table_chart_outlined;
  // Docs / text
  const docs = {'pdf', 'doc', 'docx', 'odt', 'rtf', 'txt', 'md'};
  if (docs.contains(ext)) {
    return ext == 'pdf'
        ? Icons.picture_as_pdf_outlined
        : Icons.description_outlined;
  }
  return null;
}

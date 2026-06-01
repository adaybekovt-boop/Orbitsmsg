// Voice player — renders a single inbound / outbound voice row in a
// message bubble. Port of `src/components/VoicePlayer.jsx`.
//
// Responsibilities:
//  • Round 40dp play/pause button (primary-tinted for own bubbles).
//  • 40-bar progress waveform; bars left of the cursor are
//    accent-coloured, bars right are muted.
//  • Duration counter in `MM:SS` — counts DOWN from total during play,
//    matching the JS version (shownSeconds = duration − duration*progress).
//  • First play: load raw bytes from `voice_blobs[msgId]`, write to a
//    temp file, hand to `just_audio` (the package can't consume
//    Uint8List directly on all platforms — temp-file trick is the
//    canonical workaround and cheap: OS sweeps the cache dir on its
//    own timeline).
//
// Design choices that differ from the React build:
//  • No transcript toggle for the MVP — the JS version shows a
//    collapsible secondary bubble when `voice.transcript` is non-empty.
//    Web-Speech-transcripts are Chromium-only anyway, so most rows
//    arrive with empty transcript; we'll add the UI back on Day 5
//    alongside local ASR.
//  • Single player instance per widget — no shared bus. Tapping play on
//    another voice bubble should pause this one, which we handle by
//    listening to a playing-bubble notifier if needed later. For MVP
//    two voice bubbles can play concurrently (acceptable).

import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../storage/db.dart' as db;

class VoicePlayer extends StatefulWidget {
  const VoicePlayer({
    super.key,
    required this.msgId,
    required this.voiceRef,
    required this.mine,
  });

  /// Row id the bytes are keyed under in `voice_blobs`.
  final String msgId;

  /// The `payload.voice` map: `{duration, mime, waveform, transcript}`.
  /// Waveform is `List<double>` 0..1; older rows may have come back from
  /// `jsonDecode` as `List<num>` — we coerce at paint time.
  final Map<String, Object?> voiceRef;

  /// Mine = my outbound bubble (primary-tinted). Peer = their bubble
  /// (neutral tint against the surface fill).
  final bool mine;

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;

  bool _loading = false;
  bool _loaded = false;
  bool _loadFailed = false;

  /// Path of the temp file we wrote the bytes to, so dispose can try to
  /// sweep it. OS would do it anyway, but we prefer deterministic
  /// cleanup for chats with many voice messages.
  String? _tempPath;

  /// Playback position in ms. Updated via the position stream; kept as
  /// int so the counter's tabular-figures layout doesn't jitter.
  int _positionMs = 0;

  /// Best-known total duration. Once the decoder has reported a real
  /// duration we prefer that — older rows may carry an int-rounded
  /// meta (legacy send path) that rounds 0.3 s messages to 0, which
  /// the player would otherwise display as 0:00 forever. Meta is the
  /// fallback until the file is loaded, so the bar doesn't flash empty.
  int get _totalMs {
    if (_loaded) {
      final actual = _player.duration?.inMilliseconds;
      if (actual != null && actual > 0) return actual;
    }
    final meta = widget.voiceRef['duration'];
    if (meta is num && meta > 0) {
      return (meta.toDouble() * 1000).round();
    }
    final actual = _player.duration?.inMilliseconds;
    if (actual != null && actual > 0) return actual;
    return 0;
  }

  bool get _playing => _player.playing;

  @override
  void initState() {
    super.initState();
    _stateSub = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed) {
        // Reset to start so the next tap plays from 0 — default
        // just_audio behaviour is to keep position at end, which
        // confuses the countdown.
        unawaited(_player.pause());
        unawaited(_player.seek(Duration.zero));
        setState(() => _positionMs = 0);
        return;
      }
      setState(() {}); // refresh play/pause icon on state flips
    });
    _posSub = _player.positionStream.listen((p) {
      if (!mounted) return;
      setState(() => _positionMs = p.inMilliseconds);
    });
    _durSub = _player.durationStream.listen((_) {
      if (!mounted) return;
      setState(() {}); // refresh total once decoder reports it
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    unawaited(_player.dispose());
    final path = _tempPath;
    // Only the native load-path writes a temp file; on web `_tempPath`
    // stays null (we feed the player a `data:` URI) so there's nothing
    // to sweep.
    if (path != null && !kIsWeb) {
      unawaited(() async {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }());
    }
    super.dispose();
  }

  Future<void> _loadIfNeeded() async {
    if (_loaded || _loading) return;
    // Bump `_loading` inside setState so the play button shows the
    // spinner immediately — plain assignment misses the frame and a
    // fast-tapping user sees an unresponsive button instead.
    if (mounted) {
      setState(() => _loading = true);
    } else {
      _loading = true;
    }
    try {
      final blob = await db.getVoiceBlob(widget.msgId);
      if (blob == null) {
        if (!mounted) return;
        setState(() {
          _loadFailed = true;
          _loading = false;
        });
        return;
      }
      final bytes = blob['blob'];
      if (bytes is! Uint8List || bytes.isEmpty) {
        if (!mounted) return;
        setState(() {
          _loadFailed = true;
          _loading = false;
        });
        return;
      }
      final mime = (blob['mime'] as String?) ?? 'audio/mp4';
      if (kIsWeb) {
        // On web `dart:io` File/path_provider are stubs that throw — feed
        // bytes straight into just_audio as a `data:` URI instead. The URL
        // lives entirely in memory, so there's nothing to clean up in
        // dispose.
        await _player.setAudioSource(
          AudioSource.uri(Uri.dataFromBytes(bytes, mimeType: mime)),
        );
      } else {
        final ext = _extForMime(mime);
        final dir = await getTemporaryDirectory();
        final path =
            '${dir.path}${Platform.pathSeparator}voice_${widget.msgId}.$ext';
        await File(path).writeAsBytes(bytes, flush: true);
        _tempPath = path;
        await _player.setFilePath(path);
      }
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadFailed = true;
        _loading = false;
      });
    }
  }

  Future<void> _togglePlay() async {
    HapticFeedback.selectionClick();
    if (_loadFailed) return;
    if (!_loaded) await _loadIfNeeded();
    if (!_loaded || !mounted) return;
    if (_playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  String _extForMime(String mime) {
    final lower = mime.toLowerCase();
    if (lower.contains('mp4') || lower.contains('aac')) return 'm4a';
    if (lower.contains('webm')) return 'webm';
    if (lower.contains('ogg')) return 'ogg';
    if (lower.contains('wav')) return 'wav';
    return 'm4a'; // safe default — aac in mp4 container
  }

  List<double> _waveform() {
    final raw = widget.voiceRef['waveform'];
    if (raw is List) {
      final out = <double>[];
      for (final v in raw) {
        if (v is num) {
          final d = v.toDouble();
          out.add(d.isNaN ? 0.0 : d.clamp(0.0, 1.0).toDouble());
        }
      }
      return out;
    }
    return const <double>[];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = widget.mine ? scheme.onPrimary : scheme.primary;
    final muted = widget.mine
        ? scheme.onPrimary.withValues(alpha: 0.4)
        : scheme.onSurface.withValues(alpha: 0.35);
    final textColor = widget.mine
        ? scheme.onPrimary
        : scheme.onSurface.withValues(alpha: 0.8);

    final total = _totalMs;
    final shownMs = _playing && total > 0
        ? math.max(0, total - _positionMs)
        : total;
    final progress =
        total > 0 ? (_positionMs / total).clamp(0.0, 1.0) : 0.0;

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 260),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _PlayButton(
            playing: _playing,
            loading: _loading,
            failed: _loadFailed,
            accent: accent,
            onTap: _togglePlay,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 28,
                  child: CustomPaint(
                    painter: _ProgressWaveformPainter(
                      samples: _waveform(),
                      progress: progress,
                      accent: accent,
                      muted: muted,
                    ),
                    size: Size.infinite,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _loadFailed
                      ? 'Запись недоступна'
                      : _formatMs(shownMs),
                  style: TextStyle(
                    color: textColor,
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 40x40 circular play/pause button. Shows a spinner while the bytes
/// are being hydrated from disk, and a broken-mic icon if the blob
/// went missing (chat storage cleared, older row, etc.).
class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.loading,
    required this.failed,
    required this.accent,
    required this.onTap,
  });

  final bool playing;
  final bool loading;
  final bool failed;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: accent.withValues(alpha: 0.15),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: failed ? null : onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: loading
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(accent),
                    ),
                  )
                : Icon(
                    failed
                        ? Icons.mic_off
                        : (playing ? Icons.pause : Icons.play_arrow),
                    color: accent,
                    size: 22,
                  ),
          ),
        ),
      ),
    );
  }
}

/// Waveform painter with a progress cursor — bars below the cursor
/// render in [accent], bars above in [muted]. Matches the JS
/// `ProgressWaveform` component (40 bars, centered, progress linear).
class _ProgressWaveformPainter extends CustomPainter {
  _ProgressWaveformPainter({
    required this.samples,
    required this.progress,
    required this.accent,
    required this.muted,
  });

  final List<double> samples;
  final double progress;
  final Color accent;
  final Color muted;

  static const int _targetBars = 40;

  @override
  void paint(Canvas canvas, Size size) {
    final bars = _resample(samples, _targetBars);
    const gap = 2.0;
    final barWidth = math.max(
      1.5,
      (size.width - gap * (bars.length - 1)) / bars.length,
    );
    final centerY = size.height / 2;
    final cursorX = progress * size.width;
    final paint = Paint()..strokeCap = StrokeCap.round;

    for (var i = 0; i < bars.length; i++) {
      final amp = bars[i].clamp(0.0, 1.0);
      final barHeight = math.max(2.0, amp * (size.height - 4));
      final left = i * (barWidth + gap);
      final x = left + barWidth / 2;
      paint.color = x <= cursorX ? accent : muted;
      paint.strokeWidth = barWidth;
      canvas.drawLine(
        Offset(x, centerY - barHeight / 2),
        Offset(x, centerY + barHeight / 2),
        paint,
      );
    }
  }

  /// Resample [src] to exactly [n] entries. Upsample by nearest-neighbour
  /// (duplicates are fine since the input is short), downsample by
  /// bucket-max so peaks don't get averaged away.
  List<double> _resample(List<double> src, int n) {
    if (src.isEmpty) {
      // Idle baseline — 14 % height, matches JS empty-waveform fallback.
      return List<double>.filled(n, 0.14);
    }
    if (src.length == n) return src;
    if (src.length < n) {
      final out = <double>[];
      for (var i = 0; i < n; i++) {
        final idx = ((i / n) * src.length).floor().clamp(0, src.length - 1);
        out.add(src[idx]);
      }
      return out;
    }
    final bucketSize = src.length / n;
    final out = <double>[];
    for (var i = 0; i < n; i++) {
      final start = (i * bucketSize).floor();
      final end = math.min(src.length, ((i + 1) * bucketSize).ceil());
      var peak = 0.0;
      for (var j = start; j < end; j++) {
        if (src[j] > peak) peak = src[j];
      }
      out.add(peak);
    }
    return out;
  }

  @override
  bool shouldRepaint(covariant _ProgressWaveformPainter old) =>
      old.progress != progress ||
      old.accent != accent ||
      old.muted != muted ||
      !identical(old.samples, samples);
}

String _formatMs(int ms) {
  if (ms < 0) ms = 0;
  final totalSec = ms ~/ 1000;
  final m = totalSec ~/ 60;
  final s = totalSec % 60;
  return '${m.toString()}:${s.toString().padLeft(2, '0')}';
}

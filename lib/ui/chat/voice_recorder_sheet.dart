// Voice recorder bottom sheet — captures a short voice message via the
// `record` package and hands the raw bytes back to the chat composer.
//
// Cross-platform notes:
//  • Encoder: WAV (PCM) by default. It's universally decodable by just_audio
//    on every target, and — because it's raw PCM — lets us compute an honest
//    waveform from the finished bytes (see [_buildWaveform]). On the rare
//    native platform that doesn't support WAV we fall back to AAC/m4a and a
//    synthetic waveform.
//  • Reading bytes back differs per platform (temp file vs `blob:` URL), so
//    that step lives behind the conditional-import helper (`voice_blob_*`).
//  • Live waveform: web's WAV path (MicRecorderDelegate) doesn't surface
//    amplitude, so the in-progress visual is a decorative VU animation. The
//    *sent* waveform is always derived from the real audio after stop().
//
// Public API ([VoiceRecorderSheet], [VoiceRecordResult]) is unchanged from the
// previous stub so the call site in `chat_view_page.dart` keeps compiling.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../../themes/orbits_tokens.dart';
import '../primitives/orbits_glass_button.dart';
import '../primitives/orbits_glass_surface.dart';
import 'voice_blob_stub.dart'
    if (dart.library.io) 'voice_blob_io.dart'
    if (dart.library.html) 'voice_blob_web.dart' as blob;

/// Payload handed to [VoiceRecorderSheet.onSend]. Shape matches the named
/// args of `MessagingNotifier.sendVoice` so the caller can splat it.
class VoiceRecordResult {
  const VoiceRecordResult({
    required this.bytes,
    required this.mime,
    required this.durationSec,
    required this.waveform,
  });

  final Uint8List bytes;
  final String mime;
  final double durationSec;

  /// Normalized amplitudes in 0..1, ≤48 entries.
  final List<double> waveform;
}

enum _Phase { checking, denied, ready, recording, sending }

class VoiceRecorderSheet extends StatefulWidget {
  const VoiceRecorderSheet({super.key, required this.onSend});

  /// Fires with the finished recording. Invoked after the sheet pops.
  final void Function(VoiceRecordResult result) onSend;

  @override
  State<VoiceRecorderSheet> createState() => _VoiceRecorderSheetState();
}

class _VoiceRecorderSheetState extends State<VoiceRecorderSheet>
    with SingleTickerProviderStateMixin {
  /// Hard cap so a forgotten recording can't blow the `sendVoice` size gate
  /// (WAV at the browser's native rate is ~96 KB/s; 60 s stays well under the
  /// 6 MiB raw cap).
  static const Duration _maxDuration = Duration(seconds: 60);
  static const int _waveformBars = 40;

  final AudioRecorder _recorder = AudioRecorder();
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _ticker;
  late final AnimationController _pulse;

  _Phase _phase = _Phase.checking;
  String? _pathOrUrl;
  AudioEncoder _encoder = AudioEncoder.wav;
  String _mime = 'audio/wav';
  String _ext = 'wav';
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _init();
  }

  Future<void> _init() async {
    bool granted;
    try {
      granted = await _recorder.hasPermission();
    } catch (_) {
      granted = false;
    }
    if (!mounted) return;
    setState(() => _phase = granted ? _Phase.ready : _Phase.denied);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pulse.dispose();
    // If the sheet was swiped away mid-record, stop + release the recorder.
    // Touches only [_recorder] (no State/context), so it's safe post-dispose.
    final recorder = _recorder;
    unawaited(() async {
      try {
        if (await recorder.isRecording()) await recorder.stop();
      } catch (_) {}
      try {
        await recorder.dispose();
      } catch (_) {}
    }());
    super.dispose();
  }

  // ── Recording lifecycle ──────────────────────────────────

  Future<void> _startRecording() async {
    // Prefer WAV (universal + lets us build a real waveform); fall back to
    // AAC/m4a only where WAV isn't supported by the platform encoder.
    _encoder = AudioEncoder.wav;
    _mime = 'audio/wav';
    _ext = 'wav';
    try {
      if (!await _recorder.isEncoderSupported(AudioEncoder.wav)) {
        _encoder = AudioEncoder.aacLc;
        _mime = 'audio/mp4';
        _ext = 'm4a';
      }
    } catch (_) {
      // Keep the WAV default if the probe itself fails.
    }

    String path;
    try {
      path = await blob.prepareRecordingPath(_ext);
    } catch (_) {
      path = 'orbits_voice.$_ext';
    }

    try {
      await _recorder.start(
        RecordConfig(
          encoder: _encoder,
          numChannels: 1,
          sampleRate: 16000,
        ),
        path: path,
      );
    } catch (_) {
      if (!mounted) return;
      _toast('Не удалось включить микрофон');
      setState(() => _phase = _Phase.ready);
      return;
    }

    _stopwatch
      ..reset()
      ..start();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), _onTick);
    if (!mounted) return;
    setState(() {
      _pathOrUrl = path;
      _elapsed = Duration.zero;
      _phase = _Phase.recording;
    });
  }

  void _onTick(Timer _) {
    if (!mounted) return;
    setState(() => _elapsed = _stopwatch.elapsed);
    if (_stopwatch.elapsed >= _maxDuration) {
      _toast('Максимум 60 секунд');
      unawaited(_finishAndSend());
    }
  }

  Future<void> _finishAndSend() async {
    if (_phase != _Phase.recording) return;
    setState(() => _phase = _Phase.sending);
    _ticker?.cancel();
    _stopwatch.stop();
    _pulse.stop();

    final durationSec = _stopwatch.elapsedMilliseconds / 1000.0;

    String? out;
    try {
      out = await _recorder.stop();
    } catch (_) {
      out = null;
    }
    final url = out ?? _pathOrUrl;

    if (url == null) {
      await _bailOut('Запись не удалась');
      return;
    }
    if (durationSec < 0.8) {
      unawaited(_safeDiscard(url));
      await _bailOut('Слишком коротко');
      return;
    }

    Uint8List bytes;
    try {
      bytes = await blob.readRecordingBytes(url);
    } catch (_) {
      bytes = Uint8List(0);
    }
    if (bytes.isEmpty) {
      unawaited(_safeDiscard(url));
      await _bailOut('Запись не удалась');
      return;
    }

    final result = VoiceRecordResult(
      bytes: bytes,
      mime: _mime,
      durationSec: durationSec,
      waveform: _buildWaveform(bytes),
    );
    unawaited(_safeDiscard(url));
    if (!mounted) return;
    Navigator.of(context).maybePop();
    widget.onSend(result);
  }

  Future<void> _cancel() async {
    _ticker?.cancel();
    _stopwatch.stop();
    try {
      if (await _recorder.isRecording()) await _recorder.cancel();
    } catch (_) {}
    final url = _pathOrUrl;
    if (url != null) unawaited(_safeDiscard(url));
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  Future<void> _bailOut(String message) async {
    if (!mounted) return;
    _toast(message);
    Navigator.of(context).maybePop();
  }

  Future<void> _safeDiscard(String url) async {
    try {
      await blob.discardRecording(url);
    } catch (_) {}
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  // ── Waveform ─────────────────────────────────────────────

  /// Build a ≤[_waveformBars] bar waveform (0..1) from the finished audio.
  /// For WAV we read real PCM peaks; otherwise we return a gentle synthetic
  /// shape so the bubble isn't a flat line.
  List<double> _buildWaveform(Uint8List bytes) {
    final pcm = _extractPcm16(bytes);
    if (pcm == null || pcm.isEmpty) return _syntheticWaveform();

    final bars = <double>[];
    final bucket = (pcm.length / _waveformBars).ceil().clamp(1, pcm.length);
    for (int i = 0; i < pcm.length; i += bucket) {
      final end = math.min(i + bucket, pcm.length);
      int peak = 0;
      for (int j = i; j < end; j++) {
        final a = pcm[j].abs();
        if (a > peak) peak = a;
      }
      bars.add((peak / 32768.0).clamp(0.0, 1.0));
    }

    // Normalize to the loudest bar so quiet recordings still render with shape.
    final maxBar = bars.fold<double>(0, (m, v) => v > m ? v : m);
    if (maxBar > 0.01) {
      for (int i = 0; i < bars.length; i++) {
        bars[i] = (bars[i] / maxBar).clamp(0.0, 1.0);
      }
    }
    return bars.length > _waveformBars
        ? bars.sublist(0, _waveformBars)
        : bars;
  }

  List<double> _syntheticWaveform() {
    return List<double>.generate(_waveformBars, (i) {
      final t = i / _waveformBars;
      final env = 1 - (t - 0.5).abs() * 1.4;
      final v = 0.3 + 0.5 * (0.5 + 0.5 * math.sin(t * math.pi * 6)) * env;
      return v.clamp(0.06, 1.0);
    });
  }

  /// Decode 16-bit PCM samples (channel 0) out of a canonical WAV byte buffer.
  /// Returns null if the buffer isn't 16-bit PCM WAV.
  Int16List? _extractPcm16(Uint8List bytes) {
    if (bytes.length < 44) return null;
    bool tag(int off, String s) {
      for (int i = 0; i < s.length; i++) {
        if (off + i >= bytes.length || bytes[off + i] != s.codeUnitAt(i)) {
          return false;
        }
      }
      return true;
    }

    if (!tag(0, 'RIFF') || !tag(8, 'WAVE')) return null;
    final bd = ByteData.sublistView(bytes);
    int off = 12;
    int channels = 1;
    int bits = 16;
    int dataOff = -1;
    int dataLen = 0;
    while (off + 8 <= bytes.length) {
      final size = bd.getUint32(off + 4, Endian.little);
      if (tag(off, 'fmt ') && off + 24 <= bytes.length) {
        channels = bd.getUint16(off + 10, Endian.little);
        bits = bd.getUint16(off + 22, Endian.little);
      } else if (tag(off, 'data')) {
        dataOff = off + 8;
        dataLen = size;
        break;
      }
      off += 8 + size + (size.isOdd ? 1 : 0);
    }
    if (dataOff < 0 || bits != 16 || channels < 1) return null;

    final available = bytes.length - dataOff;
    if (dataLen <= 0 || dataLen > available) dataLen = available;
    final total = dataLen ~/ 2;
    if (total <= 0) return null;
    final all = Int16List(total);
    for (int i = 0; i < total; i++) {
      all[i] = bd.getInt16(dataOff + i * 2, Endian.little);
    }
    if (channels == 1) return all;
    final mono = Int16List(total ~/ channels);
    for (int i = 0; i < mono.length; i++) {
      mono[i] = all[i * channels];
    }
    return mono;
  }

  // ── UI ───────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.sheet,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: tokens.muted.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              _body(tokens),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(OrbitsTokens tokens) {
    switch (_phase) {
      case _Phase.checking:
        return _Centered(
          tokens: tokens,
          children: [
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(height: 14),
            Text('Проверяем микрофон…', style: _hintStyle(tokens)),
          ],
        );

      case _Phase.denied:
        return _Centered(
          tokens: tokens,
          children: [
            Icon(Icons.mic_off, size: 44, color: tokens.muted),
            const SizedBox(height: 14),
            Text(
              'Нет доступа к микрофону',
              style: TextStyle(
                fontFamily: tokens.fontHeading,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: tokens.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Разрешите доступ к микрофону в настройках браузера или системы '
              'и попробуйте снова.',
              textAlign: TextAlign.center,
              style: _hintStyle(tokens),
            ),
            const SizedBox(height: 20),
            OrbitsGlassButton(
              label: 'Закрыть',
              variant: OrbitsGlassVariant.secondary,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        );

      case _Phase.ready:
        return _Centered(
          tokens: tokens,
          children: [
            _RecordButton(tokens: tokens, onTap: _startRecording),
            const SizedBox(height: 18),
            Text(
              'Нажмите и говорите',
              style: TextStyle(
                fontFamily: tokens.fontHeading,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: tokens.text,
              ),
            ),
            const SizedBox(height: 4),
            Text('До 60 секунд', style: _hintStyle(tokens)),
          ],
        );

      case _Phase.recording:
      case _Phase.sending:
        final sending = _phase == _Phase.sending;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _RecDot(pulse: _pulse, color: tokens.danger),
                const SizedBox(width: 8),
                Text(
                  _format(_elapsed),
                  style: TextStyle(
                    fontFamily: tokens.fontMono,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: tokens.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _LiveWaveform(pulse: _pulse, color: tokens.text),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: OrbitsGlassButton(
                    label: 'Отмена',
                    icon: Icons.close,
                    variant: OrbitsGlassVariant.subtle,
                    expand: true,
                    enabled: !sending,
                    onPressed: sending ? null : _cancel,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OrbitsGlassButton(
                    label: sending ? 'Отправляем…' : 'Отправить',
                    icon: Icons.arrow_upward_rounded,
                    variant: OrbitsGlassVariant.primary,
                    expand: true,
                    enabled: !sending,
                    onPressed: sending ? null : _finishAndSend,
                  ),
                ),
              ],
            ),
          ],
        );
    }
  }

  TextStyle _hintStyle(OrbitsTokens tokens) => TextStyle(
        fontFamily: tokens.fontBody,
        fontSize: 13,
        color: tokens.muted,
      );

  static String _format(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.tokens, required this.children});
  final OrbitsTokens tokens;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// Big circular start-recording button, built from the glass primitive.
class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.tokens, required this.onTap});
  final OrbitsTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.button,
      borderRadius: BorderRadius.circular(48),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 96,
            height: 96,
            child: Icon(Icons.mic, size: 38, color: tokens.text),
          ),
        ),
      ),
    );
  }
}

/// Pulsing red dot shown while recording.
class _RecDot extends StatelessWidget {
  const _RecDot({required this.pulse, required this.color});
  final Animation<double> pulse;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        final o = 0.45 + 0.55 * pulse.value;
        return Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color.withValues(alpha: o),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: o * 0.6), blurRadius: 6),
            ],
          ),
        );
      },
    );
  }
}

/// Decorative VU-style waveform shown during recording. Not data-driven (the
/// web WAV path doesn't expose live amplitude) — the *sent* waveform is the
/// honest one, computed from the recorded PCM.
class _LiveWaveform extends StatelessWidget {
  const _LiveWaveform({required this.pulse, required this.color});
  final Animation<double> pulse;
  final Color color;

  static const int _bars = 27;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: AnimatedBuilder(
        animation: pulse,
        builder: (context, _) {
          final phase = pulse.value * math.pi * 2;
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List<Widget>.generate(_bars, (i) {
              final wobble = 0.5 + 0.5 * math.sin(phase + i * 0.7);
              final env = 1 - (i / (_bars - 1) - 0.5).abs() * 1.2;
              final h = (6 + 34 * wobble * env).clamp(4.0, 44.0);
              return Container(
                width: 3,
                height: h,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.35 + 0.45 * wobble),
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

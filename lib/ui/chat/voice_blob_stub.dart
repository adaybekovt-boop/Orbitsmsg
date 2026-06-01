// Default stub for the conditional-import trick in `voice_recorder_sheet.dart`.
//
// The recorder writes a recording, then has to read the raw bytes back out so
// `MessagingNotifier.sendVoice` can persist + transmit them. How you get those
// bytes is platform-specific:
//   • native (dart:io)  → `record` writes a temp file; we read it off disk.
//   • web   (dart:html) → `record` returns a `blob:` URL; we fetch it.
// This stub is selected on any platform that is neither — it never runs in a
// real build (the chat composer only offers voice where the recorder works),
// but Dart still needs a default so every target compiles.
import 'dart:typed_data';

/// Native: a writable temp path passed to `AudioRecorder.start(path:)`.
/// Web: ignored by `record` — we return a throwaway filename for parity.
Future<String> prepareRecordingPath(String ext) async {
  throw UnsupportedError('Voice recording is not supported on this platform.');
}

/// Read the finished recording back as raw bytes. [pathOrUrl] is the value
/// returned by `AudioRecorder.stop()` (a file path on native, a `blob:` URL
/// on web).
Future<Uint8List> readRecordingBytes(String pathOrUrl) async {
  throw UnsupportedError('Voice recording is not supported on this platform.');
}

/// Release the recording resource once we hold the bytes (delete the temp
/// file on native, revoke the object URL on web). Best-effort; never throws.
Future<void> discardRecording(String pathOrUrl) async {}

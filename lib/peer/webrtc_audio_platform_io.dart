import 'dart:io';

/// Linux: Pulse socket or ALSA device nodes. Other platforms leave capture
/// to the OS permission prompt — this probe exists to avoid creating a
/// platform ADM that Fatals when no sound server is present.
bool orbitsPlatformAudioAvailable() {
  try {
    if (!Platform.isLinux) return true;
    final runtime = Platform.environment['XDG_RUNTIME_DIR'];
    if (runtime != null && runtime.isNotEmpty) {
      if (File('$runtime/pulse/native').existsSync()) return true;
      if (Directory('$runtime/pulse').existsSync()) {
        final dir = Directory('$runtime/pulse');
        if (dir.listSync().isNotEmpty) return true;
      }
    }
    final snd = Directory('/dev/snd');
    if (snd.existsSync() && snd.listSync().isNotEmpty) return true;
    if (Platform.environment['PULSE_SERVER']?.isNotEmpty == true) return true;
  } catch (_) {}
  return false;
}

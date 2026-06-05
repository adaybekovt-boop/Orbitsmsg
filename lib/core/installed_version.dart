// Reads the installed app version (package_info_plus). Kept tiny + separate so
// the update notifier can depend on it without pulling a whole page in, and so
// tests override it via `installedVersionReaderProvider` (no platform channel).
// Web-safe — package_info_plus ships a web implementation.

import 'package:package_info_plus/package_info_plus.dart';

/// The installed app version, e.g. "9.0.6" (without the +build suffix). Returns
/// an empty string if the platform channel is unavailable — the checker treats
/// an unparseable current version as "can't compare", never a false update.
Future<String> readInstalledVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  } catch (_) {
    return '';
  }
}

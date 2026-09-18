// Vault-wrapped snapshots for long-term pairing / device state.
// Never writes plaintext. Locked vault skips persist (fail closed).

import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/vault_kek.dart';

typedef WrappedSnapshotWriter = Future<void> Function(List<int> plaintext);
typedef WrappedSnapshotReader = Future<Uint8List?> Function();

const String kDiscoverySecretsPrefsKey = 'orbits.discovery.secrets.v1';
const String kDeviceRegistryPrefsKey = 'orbits.device.registry.v1';

Future<void> writeWrappedPrefsSnapshot(String key, List<int> plaintext) async {
  if (!hasVaultKek()) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(key, await wrapSecret(plaintext));
}

Future<Uint8List?> readWrappedPrefsSnapshot(String key) async {
  if (!hasVaultKek()) return null;
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(key);
  if (raw == null || raw.isEmpty) return null;
  return unwrapSecret(raw);
}

Future<void> writeDiscoverySecretsSnapshot(List<int> plaintext) =>
    writeWrappedPrefsSnapshot(kDiscoverySecretsPrefsKey, plaintext);

Future<Uint8List?> readDiscoverySecretsSnapshot() =>
    readWrappedPrefsSnapshot(kDiscoverySecretsPrefsKey);

Future<void> writeDeviceRegistrySnapshot(List<int> plaintext) =>
    writeWrappedPrefsSnapshot(kDeviceRegistryPrefsKey, plaintext);

Future<Uint8List?> readDeviceRegistrySnapshot() =>
    readWrappedPrefsSnapshot(kDeviceRegistryPrefsKey);

Map<String, List<int>> decodeSecretMap(List<int> bytes) {
  final raw = jsonDecode(utf8.decode(bytes));
  if (raw is! Map) return <String, List<int>>{};
  final out = <String, List<int>>{};
  raw.forEach((key, value) {
    if (key is! String || value is! String || value.isEmpty) return;
    out[key] = base64Decode(value);
  });
  return out;
}

List<int> encodeSecretMap(Map<String, List<int>> secrets) {
  final encoded = <String, String>{
    for (final e in secrets.entries) e.key: base64Encode(e.value),
  };
  return utf8.encode(jsonEncode(encoded));
}

List<int> base64Decode(String value) => base64.decode(value);

String base64Encode(List<int> bytes) => base64.encode(bytes);

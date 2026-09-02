// Per-device Double Ratchet sessions. Each device pair has its own
// RatchetState and rootKey. Devices never share a mutable instance.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/base64_helpers.dart';
import '../core/double_ratchet.dart';
import '../core/spki_codec.dart';
import '../transport/layers.dart';
import 'device_registry.dart';

const Set<String> kRatchetSecretSnapshotKeys = {
  'rootKey',
  'sendCk',
  'recvCk',
  'dhPriv',
  'skipped',
};

class DeviceRatchetSessions {
  DeviceRatchetSessions({this.localDeviceId = ''});

  final String localDeviceId;
  final Map<String, RatchetState> _sessions = <String, RatchetState>{};
  final Set<String> _revoked = <String>{};

  static String sessionKey(String localDeviceId, String remoteDeviceId) =>
      '$localDeviceId->$remoteDeviceId';

  Iterable<String> get sessionKeys => _sessions.keys;
  Set<String> get revokedDeviceIds => Set<String>.unmodifiable(_revoked);
  int get sessionCount => _sessions.length;

  void bind({
    required String localDeviceId,
    required String remoteDeviceId,
    required RatchetState state,
  }) {
    if (_revoked.contains(remoteDeviceId) || _revoked.contains(localDeviceId)) {
      throw StateError('revoked device cannot receive a ratchet session');
    }
    for (final existing in _sessions.values) {
      if (identical(existing, state)) {
        throw StateError('devices must not share a ratchet instance');
      }
      if (identical(existing.rootKey, state.rootKey) ||
          _bytesEqual(existing.rootKey, state.rootKey)) {
        throw StateError('devices must not share a rootKey');
      }
    }
    _sessions[sessionKey(localDeviceId, remoteDeviceId)] = state;
  }

  RatchetState? session(String localDeviceId, String remoteDeviceId) {
    return _sessions[sessionKey(localDeviceId, remoteDeviceId)];
  }

  void revoke(String deviceId) {
    _revoked.add(deviceId);
    _sessions.removeWhere(
      (key, _) => key.startsWith('$deviceId->') || key.endsWith('->$deviceId'),
    );
  }

  bool isRevoked(String deviceId) => _revoked.contains(deviceId);

  /// Separately encrypted envelope for every still-active target device.
  Future<Map<String, String>> fanoutEncrypt({
    required String sendingDeviceId,
    required Iterable<AuthorizedDevice> targets,
    required Object plaintext,
  }) async {
    final out = <String, String>{};
    for (final target in targets) {
      if (_revoked.contains(target.deviceId)) continue;
      if (target.status != DeviceStatus.active) continue;
      final state = session(sendingDeviceId, target.deviceId);
      if (state == null) continue;
      final env = await ratchetEncrypt(state, plaintext);
      out[target.deviceId] = encodeWire(env);
    }
    return out;
  }

  Future<Uint8List> decryptFrom({
    required String localDeviceId,
    required String remoteDeviceId,
    required String wire,
  }) async {
    if (_revoked.contains(remoteDeviceId) || _revoked.contains(localDeviceId)) {
      throw StateError('revoked device');
    }
    final state = session(localDeviceId, remoteDeviceId);
    if (state == null) {
      throw StateError('no ratchet session for this device pair');
    }
    final env = decodeWire(wire);
    if (env == null) {
      throw const FormatException('not a v2 ratchet envelope');
    }
    return ratchetDecrypt(state, env);
  }

  /// Persistence snapshot. Callers must wrap secret fields; logs must use
  /// [diagnostics] instead.
  Future<Map<String, Object?>> snapshot(String key) async {
    final state = _sessions[key];
    if (state == null) {
      throw StateError('unknown session');
    }
    final dhPriv = Uint8List.fromList((await state.dhKeyPair.extract()).d);
    return <String, Object?>{
      'key': key,
      'rootKey': bytesToBase64(state.rootKey),
      'sendCk': state.sendCk == null ? null : bytesToBase64(state.sendCk!),
      'recvCk': state.recvCk == null ? null : bytesToBase64(state.recvCk!),
      'dhPriv': bytesToBase64(dhPriv),
      'dhPubSpki': bytesToBase64(state.dhPubSpki),
      'remoteDhPub': state.remoteDhPub == null
          ? null
          : bytesToBase64(state.remoteDhPub!),
      'ns': state.ns,
      'nr': state.nr,
      'pn': state.pn,
      'skipped': {
        for (final entry in state.skipped.entries)
          entry.key: bytesToBase64(entry.value),
      },
    };
  }

  Future<void> restore(Map<String, Object?> row) async {
    final key = row['key'] as String? ?? '';
    if (key.isEmpty || !row.containsKey('rootKey')) {
      throw const FormatException('incomplete ratchet snapshot');
    }
    final pub = base64ToBytes(row['dhPubSpki'] as String);
    final point = parseP256Spki(pub);
    final pair = EcKeyPairData(
      d: base64ToBytes(row['dhPriv'] as String),
      x: point.x,
      y: point.y,
      type: KeyPairType.p256,
    );
    final skippedRaw = row['skipped'] as Map? ?? const {};
    _sessions[key] = RatchetState(
      rootKey: base64ToBytes(row['rootKey'] as String),
      sendCk: row['sendCk'] is String
          ? base64ToBytes(row['sendCk'] as String)
          : null,
      recvCk: row['recvCk'] is String
          ? base64ToBytes(row['recvCk'] as String)
          : null,
      dhKeyPair: pair,
      dhPubSpki: pub,
      remoteDhPub: row['remoteDhPub'] is String
          ? base64ToBytes(row['remoteDhPub'] as String)
          : null,
      ns: row['ns'] as int? ?? 0,
      nr: row['nr'] as int? ?? 0,
      pn: row['pn'] as int? ?? 0,
      skipped: {
        for (final entry in skippedRaw.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: base64ToBytes(entry.value as String),
      },
    );
  }

  /// Privacy-safe counters only. Never includes keys, peer IDs, or bodies.
  Map<String, Object?> diagnostics() => <String, Object?>{
    'sessionCount': _sessions.length,
    'revokedCount': _revoked.length,
  };

  static String redactSnapshotForLog(Map<String, Object?> snapshot) {
    final safe = <String, Object?>{};
    snapshot.forEach((key, value) {
      if (kRatchetSecretSnapshotKeys.contains(key) ||
          kForbiddenReplicationFields.contains(key)) {
        return;
      }
      safe[key] = value;
    });
    return jsonEncode(safe);
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

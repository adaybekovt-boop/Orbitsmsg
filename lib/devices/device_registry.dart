// Multi-device authorization log. Each device has its own writer and
// ratchet sessions. Revoked writers are ignored.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/vault_kek.dart';
import '../peer/helpers.dart';
import '../storage/wrapped_snapshot.dart';

enum DeviceStatus { active, revoked }

bool _deviceIdSafe(String id) => id.isNotEmpty && !id.contains('://');

bool _optionalPeerSafe(String? id) =>
    id == null || id.isEmpty || !id.contains('://');

class AuthorizedDevice {
  const AuthorizedDevice({
    required this.deviceId,
    required this.transportPublicKey,
    required this.hypercorePublicKey,
    required this.name,
    required this.kind,
    required this.createdAt,
    required this.status,
    this.ownerPeerId = '',
    this.transportPeerId,
  });

  final String deviceId;
  final List<int> transportPublicKey;
  final List<int> hypercorePublicKey;
  final String name;
  final String kind;
  final int createdAt;
  final DeviceStatus status;

  /// Identity / conversation this device belongs to.
  final String ownerPeerId;

  /// This device's own transport id. Distinct from [ownerPeerId] so
  /// fan-out does not share a ratchet snapshot.
  final String? transportPeerId;

  AuthorizedDevice revoke() => AuthorizedDevice(
        deviceId: deviceId,
        transportPublicKey: transportPublicKey,
        hypercorePublicKey: hypercorePublicKey,
        name: name,
        kind: kind,
        createdAt: createdAt,
        status: DeviceStatus.revoked,
        ownerPeerId: ownerPeerId,
        transportPeerId: transportPeerId,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'deviceId': deviceId,
        'transportPublicKey': base64Encode(transportPublicKey),
        'hypercorePublicKey': base64Encode(hypercorePublicKey),
        'name': name,
        'kind': kind,
        'createdAt': createdAt,
        'status': status.name,
        'ownerPeerId': ownerPeerId,
        'transportPeerId': transportPeerId,
      };

  static AuthorizedDevice fromJson(Map<String, Object?> json) {
    final statusName = json['status'] as String? ?? DeviceStatus.active.name;
    final deviceId = json['deviceId'] as String? ?? '';
    if (!_deviceIdSafe(deviceId)) {
      throw ArgumentError('refusing secret field in device registry');
    }
    final ownerPeerId = json['ownerPeerId'] as String? ?? '';
    final transportPeerId = json['transportPeerId'] as String?;
    if (!_optionalPeerSafe(ownerPeerId) || !_optionalPeerSafe(transportPeerId)) {
      throw ArgumentError('refusing secret field in device registry');
    }
    return AuthorizedDevice(
      deviceId: deviceId,
      transportPublicKey: base64Decode(json['transportPublicKey'] as String? ?? ''),
      hypercorePublicKey: base64Decode(json['hypercorePublicKey'] as String? ?? ''),
      name: json['name'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
      createdAt: json['createdAt'] as int? ?? 0,
      status: DeviceStatus.values.firstWhere(
        (s) => s.name == statusName,
        orElse: () => DeviceStatus.active,
      ),
      ownerPeerId: ownerPeerId,
      transportPeerId: transportPeerId,
    );
  }
}

class DeviceRegistry {
  DeviceRegistry({
    this.writeSnapshot,
    this.readSnapshot,
  });

  WrappedSnapshotWriter? writeSnapshot;
  WrappedSnapshotReader? readSnapshot;

  final Map<String, AuthorizedDevice> _devices = <String, AuthorizedDevice>{};

  List<AuthorizedDevice> get all =>
      _devices.values.toList(growable: false);

  List<AuthorizedDevice> get active => _devices.values
      .where((d) => d.status == DeviceStatus.active)
      .toList(growable: false);

  AuthorizedDevice? getDevice(String deviceId) => _devices[deviceId];

  void authorize(AuthorizedDevice device) {
    if (!_deviceIdSafe(device.deviceId) ||
        !_optionalPeerSafe(device.ownerPeerId) ||
        !_optionalPeerSafe(device.transportPeerId)) {
      throw ArgumentError('refusing secret field in device registry');
    }
    final existing = _devices[device.deviceId];
    if (existing?.status == DeviceStatus.revoked) {
      throw StateError('revoked device cannot be re-authorized in place');
    }
    _devices[device.deviceId] = device;
    unawaited(persist());
  }

  AuthorizedDevice? revoke(String deviceId) {
    if (!_deviceIdSafe(deviceId)) return null;
    final existing = _devices[deviceId];
    if (existing == null) return null;
    final revoked = existing.revoke();
    _devices[deviceId] = revoked;
    unawaited(persist());
    return revoked;
  }

  bool acceptsWriter(String deviceId) {
    final device = _devices[deviceId];
    return device != null && device.status == DeviceStatus.active;
  }

  /// True only for a known revoked writer. Unknown ids stay allowed so
  /// 1:1 Hypercore frames are not dropped before a device-link exists.
  bool isRevoked(String deviceId) {
    final device = _devices[deviceId];
    return device != null && device.status == DeviceStatus.revoked;
  }

  /// Fan-out targets: every active device of the recipient, plus own
  /// devices except the sending one (sync copy).
  List<AuthorizedDevice> fanout({
    required DeviceRegistry recipient,
    required DeviceRegistry sender,
    required String sendingDeviceId,
  }) {
    return [
      ...recipient.active,
      ...sender.active.where((d) => d.deviceId != sendingDeviceId),
    ];
  }

  /// Distinct transport ids that must each get their own ratchet session
  /// for [ownerPeerId]. Always includes [ownerPeerId] itself.
  Set<String> transportTargets(String ownerPeerId) {
    final primary = normalizePeerId(ownerPeerId);
    final out = <String>{primary};
    for (final device in active) {
      final transportId = device.transportPeerId;
      if (transportId == null || transportId.isEmpty) continue;
      if (normalizePeerId(device.ownerPeerId) != primary) continue;
      out.add(normalizePeerId(transportId));
    }
    return out;
  }

  /// Live send fan-out: every active recipient device, plus own devices
  /// except the sending one (sync copy). Never the local live peer id.
  Set<String> sendTargets(
    String recipientPeerId, {
    required String selfPeerId,
    required String sendingDeviceId,
  }) {
    final out = transportTargets(recipientPeerId);
    final self = normalizePeerId(selfPeerId);
    if (self.isEmpty || sendingDeviceId.contains('://')) return out;
    for (final device in active) {
      if (device.deviceId == sendingDeviceId) continue;
      if (!_deviceIdSafe(device.deviceId)) continue;
      if (normalizePeerId(device.ownerPeerId) != self) continue;
      final tid = device.transportPeerId;
      if (tid == null || tid.isEmpty || !_optionalPeerSafe(tid)) continue;
      final norm = normalizePeerId(tid);
      if (norm.isEmpty || norm == self) continue;
      out.add(norm);
    }
    return out;
  }

  /// Noise public key for a transport or owner id. Not the identity key.
  List<int>? noisePublicKeyFor(String peerId) {
    final norm = normalizePeerId(peerId);
    AuthorizedDevice? ownerMatch;
    for (final device in active) {
      final transport = device.transportPeerId;
      if (transport != null &&
          transport.isNotEmpty &&
          normalizePeerId(transport) == norm &&
          device.transportPublicKey.isNotEmpty) {
        return List<int>.from(device.transportPublicKey);
      }
      if (normalizePeerId(device.ownerPeerId) == norm &&
          device.transportPublicKey.isNotEmpty) {
        ownerMatch ??= device;
      }
    }
    final key = ownerMatch?.transportPublicKey;
    return key == null || key.isEmpty ? null : List<int>.from(key);
  }

  Future<void> hydrate() async {
    final reader = readSnapshot ?? readDeviceRegistrySnapshot;
    try {
      final bytes = await reader();
      if (bytes == null || bytes.isEmpty) return;
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map) return;
      final list = raw['devices'];
      if (list is! List) return;
      for (final item in list) {
        if (item is! Map) continue;
        final rawId = item['deviceId'] as String? ?? '';
        if (!_deviceIdSafe(rawId)) continue;
        final owner = item['ownerPeerId'];
        if (owner is String && !_optionalPeerSafe(owner)) continue;
        final transport = item['transportPeerId'];
        if (transport is String && !_optionalPeerSafe(transport)) continue;
        final AuthorizedDevice device;
        try {
          device = AuthorizedDevice.fromJson(Map<String, Object?>.from(item));
        } catch (_) {
          continue;
        }
        if (!_deviceIdSafe(device.deviceId)) continue;
        if (!_optionalPeerSafe(device.ownerPeerId) ||
            !_optionalPeerSafe(device.transportPeerId)) {
          continue;
        }
        _devices[device.deviceId] = device;
      }
    } catch (_) {}
  }

  Future<void> persist() async {
    try {
      final bytes = utf8.encode(jsonEncode(toJson()));
      if (writeSnapshot != null) {
        await writeSnapshot!(bytes);
        return;
      }
      if (!hasVaultKek()) return;
      await writeDeviceRegistrySnapshot(bytes);
    } catch (_) {}
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'devices': all.map((d) => d.toJson()).toList(),
      };
}

/// Transport ids that hold a distinct Double Ratchet snapshot for this
/// device. Never the owner identity peer id — revoking a tablet must
/// not tear down the phone's conversation ratchet.
List<String> ratchetKeysForRevokedDevice(AuthorizedDevice? device) {
  if (device == null) return const [];
  final tid = device.transportPeerId;
  if (tid == null || tid.isEmpty) return const [];
  return [normalizePeerId(tid)];
}

final deviceRegistry = DeviceRegistry();

Uint8List base64Decode(String value) =>
    Uint8List.fromList(value.isEmpty ? const <int>[] : base64.decode(value));

String base64Encode(List<int> bytes) => base64.encode(bytes);

// Multi-device authorization log. Each device has its own writer and
// ratchet sessions. Revoked writers are ignored.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/vault_kek.dart';
import '../peer/helpers.dart';
import '../storage/wrapped_snapshot.dart';
import '../transport/discovery_secret_store.dart';

enum DeviceStatus { active, revoked }

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
    return AuthorizedDevice(
      deviceId: json['deviceId'] as String? ?? '',
      transportPublicKey: base64Decode(json['transportPublicKey'] as String? ?? ''),
      hypercorePublicKey: base64Decode(json['hypercorePublicKey'] as String? ?? ''),
      name: json['name'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
      createdAt: json['createdAt'] as int? ?? 0,
      status: DeviceStatus.values.firstWhere(
        (s) => s.name == statusName,
        orElse: () => DeviceStatus.active,
      ),
      ownerPeerId: json['ownerPeerId'] as String? ?? '',
      transportPeerId: json['transportPeerId'] as String?,
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

  /// Restart / replay hydrate. Does not re-authorize revoked devices.
  void replaceAll(Iterable<AuthorizedDevice> devices) {
    _devices
      ..clear()
      ..addEntries(devices.map((d) => MapEntry(d.deviceId, d)));
  }

  void authorize(AuthorizedDevice device) {
    final existing = _devices[device.deviceId];
    if (existing?.status == DeviceStatus.revoked) {
      throw StateError('revoked device cannot be re-authorized in place');
    }
    _devices[device.deviceId] = device;
    unawaited(persist());
  }

  void revoke(String deviceId) {
    final existing = _devices[deviceId];
    if (existing == null) return;
    _devices[deviceId] = existing.revoke();
    unawaited(persist());
  }

  bool acceptsWriter(String deviceId) {
    final device = _devices[deviceId];
    return device != null && device.status == DeviceStatus.active;
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
      if (device.transportPeerId == null || device.transportPeerId!.isEmpty) {
        continue;
      }
      if (normalizePeerId(device.ownerPeerId) != primary) continue;
      out.add(normalizePeerId(device.transportPeerId!));
    }
    return out;
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
        final device = AuthorizedDevice.fromJson(Map<String, Object?>.from(item));
        if (device.deviceId.isEmpty) continue;
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

final deviceRegistry = DeviceRegistry();

Uint8List base64Decode(String value) =>
    Uint8List.fromList(value.isEmpty ? const <int>[] : base64.decode(value));

String base64Encode(List<int> bytes) => base64.encode(bytes);

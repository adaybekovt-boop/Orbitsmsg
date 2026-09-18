// Multi-device authorization log. Each device has its own writer and
// ratchet sessions. Revoked writers are ignored.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/vault_kek.dart';
import '../peer/helpers.dart';
import '../storage/wrapped_snapshot.dart';

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

  static DeviceStatus? parseStatus(String? name) {
    if (name == null || name.isEmpty) return null;
    for (final status in DeviceStatus.values) {
      if (status.name == name) return status;
    }
    return null;
  }

  static AuthorizedDevice fromJson(Map<String, Object?> json) {
    final status = parseStatus(json['status'] as String?);
    if (status == null) {
      throw FormatException('invalid device status: ${json['status']}');
    }
    return AuthorizedDevice(
      deviceId: json['deviceId'] as String? ?? '',
      transportPublicKey: base64Decode(json['transportPublicKey'] as String? ?? ''),
      hypercorePublicKey: base64Decode(json['hypercorePublicKey'] as String? ?? ''),
      name: json['name'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
      createdAt: json['createdAt'] as int? ?? 0,
      status: status,
      ownerPeerId: json['ownerPeerId'] as String? ?? '',
      transportPeerId: json['transportPeerId'] as String?,
    );
  }
}

class DeviceRegistry {
  DeviceRegistry({
    this.writeSnapshot,
    this.readSnapshot,
    this.onError,
  });

  WrappedSnapshotWriter? writeSnapshot;
  WrappedSnapshotReader? readSnapshot;

  /// Last hydrate/persist failure. Empty on success.
  String lastError = '';

  /// True when the last hydrate read corrupt/incomplete bytes. While
  /// set, [acceptsWriter] returns false and [authorize] throws — a
  /// broken snapshot is never a silent empty revoke set.
  bool hydrateFailed = false;

  /// Optional host hook for hydrate/persist failures.
  void Function(String error)? onError;

  final Map<String, AuthorizedDevice> _devices = <String, AuthorizedDevice>{};

  List<AuthorizedDevice> get all =>
      _devices.values.toList(growable: false);

  List<AuthorizedDevice> get active => _devices.values
      .where((d) => d.status == DeviceStatus.active)
      .toList(growable: false);

  /// Restart / replay hydrate. A revoked row never becomes active.
  void replaceAll(Iterable<AuthorizedDevice> devices) {
    final incoming = <String, AuthorizedDevice>{
      for (final device in devices) device.deviceId: device,
    };
    for (final id in incoming.keys.toList()) {
      final existing = _devices[id];
      if (existing?.status == DeviceStatus.revoked) {
        incoming[id] = existing!;
      }
    }
    _devices
      ..clear()
      ..addAll(incoming);
  }

  Future<void> authorize(AuthorizedDevice device) async {
    if (hydrateFailed) {
      throw StateError(
        lastError.isEmpty ? 'registry hydrate failed' : lastError,
      );
    }
    final existing = _devices[device.deviceId];
    if (existing?.status == DeviceStatus.revoked) {
      throw StateError('revoked device cannot be re-authorized in place');
    }
    _devices[device.deviceId] = device;
    await _persistOrRecord();
  }

  Future<void> revoke(String deviceId, {String ownerPeerId = ''}) async {
    final existing = _devices[deviceId];
    if (existing == null) {
      // Revoked stub: a later authorize/QR for this id must not admit.
      _devices[deviceId] = AuthorizedDevice(
        deviceId: deviceId,
        transportPublicKey: const <int>[],
        hypercorePublicKey: const <int>[],
        name: deviceId,
        kind: 'revoked',
        createdAt: 0,
        status: DeviceStatus.revoked,
        ownerPeerId: ownerPeerId,
      );
    } else {
      _devices[deviceId] = existing.revoke();
    }
    await _persistOrRecord();
  }

  /// Awaited (ordering matters for revoke-before-hydrate) but never
  /// throws: failures land on [lastError] instead of unhandled futures.
  Future<void> _persistOrRecord() async {
    try {
      await persist();
    } catch (_) {
      // lastError already set by persist().
    }
  }

  bool acceptsWriter(String deviceId) {
    if (hydrateFailed) return false;
    final device = _devices[deviceId];
    return device != null && device.status == DeviceStatus.active;
  }

  AuthorizedDevice? byId(String deviceId) => _devices[deviceId];

  String ownerPeerIdFor(String deviceId) {
    final device = _devices[deviceId];
    if (device == null) return '';
    if (device.ownerPeerId.isNotEmpty) {
      return normalizePeerId(device.ownerPeerId);
    }
    return normalizePeerId(device.transportPeerId ?? '');
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
    Uint8List? bytes;
    try {
      bytes = await reader();
    } catch (_) {
      // The reader itself is unavailable (missing file, no platform
      // snapshot backend): same as no snapshot, not a failure.
      return;
    }
    if (bytes == null || bytes.isEmpty) return;
    try {
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map || raw['devices'] is! List) {
        _failHydrate('registry-snapshot-incomplete');
        return;
      }
      final list = raw['devices'] as List;
      for (final item in list) {
        if (item is! Map) continue;
        final raw = Map<String, Object?>.from(item);
        if (AuthorizedDevice.parseStatus(raw['status'] as String?) == null) {
          continue;
        }
        final device = AuthorizedDevice.fromJson(raw);
        if (device.deviceId.isEmpty) continue;
        final existing = _devices[device.deviceId];
        if (existing?.status == DeviceStatus.revoked) continue;
        _devices[device.deviceId] = device;
      }
      lastError = '';
      hydrateFailed = false;
    } catch (err) {
      _failHydrate(err.toString());
    }
  }

  void _failHydrate(String error) {
    lastError = error;
    hydrateFailed = true;
    onError?.call(error);
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
    } catch (err) {
      lastError = err.toString();
      onError?.call(lastError);
      rethrow;
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'devices': all.map((d) => d.toJson()).toList(),
      };
}

final deviceRegistry = DeviceRegistry();

Uint8List base64Decode(String value) =>
    Uint8List.fromList(value.isEmpty ? const <int>[] : base64.decode(value));

String base64Encode(List<int> bytes) => base64.encode(bytes);

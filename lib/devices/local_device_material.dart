// Distinct per-device transport and Hypercore public material.
// Never reuse identity/Noise/ratchet keys. Never log private bytes.

import 'dart:math';
import 'dart:typed_data';

import '../core/identity_key.dart';
import '../core/key_store.dart';
import '../transport/device_binding.dart';
import 'device_registry.dart';

const String kLocalDeviceMaterialTable = 'device-material';
const String kLocalDeviceMaterialId = 'local';
const String kLocalDeviceKind = 'phone';

class LocalDeviceMaterial {
  const LocalDeviceMaterial({
    required this.deviceId,
    required this.transportPublicKey,
    required this.hypercorePublicKey,
  });

  final String deviceId;
  final Uint8List transportPublicKey;
  final Uint8List hypercorePublicKey;
}

Future<LocalDeviceMaterial> loadOrCreateLocalDeviceMaterial({
  KeyStore? store,
}) async {
  final keys = store ?? keyStore();
  final row = await keys.get(kLocalDeviceMaterialTable, kLocalDeviceMaterialId);
  var deviceId = row?['deviceId'] as String?;
  var transport = _asBytes(row?['transportPublicKey']);
  var writer = _asBytes(row?['hypercorePublicKey']);
  if (deviceId == null ||
      deviceId.isEmpty ||
      transport.length != 32 ||
      writer.length != 32 ||
      _isPlaceholder(transport) ||
      _isPlaceholder(writer)) {
    deviceId = _newDeviceId();
    transport = _randomKey();
    writer = _randomKey();
    if (_bytesEqual(transport, writer)) {
      writer = _randomKey();
    }
    await keys.put(kLocalDeviceMaterialTable, {
      'id': kLocalDeviceMaterialId,
      'deviceId': deviceId,
      'transportPublicKey': base64Encode(transport),
      'hypercorePublicKey': base64Encode(writer),
    });
  }
  return LocalDeviceMaterial(
    deviceId: deviceId,
    transportPublicKey: transport,
    hypercorePublicKey: writer,
  );
}

Future<DeviceBinding> issueLocalDeviceBinding({
  required LocalDeviceMaterial material,
  required List<String> capabilities,
  required int createdAt,
  required int expiresAt,
  Future<Uint8List> Function()? exportIdentity,
  Future<Uint8List> Function(List<int> payload)? sign,
}) async {
  final identity = await (exportIdentity ?? exportIdentityPubSpki)();
  if (identity.isEmpty) {
    throw StateError('identity public material is unavailable');
  }
  final draft = DeviceBinding(
    version: kDeviceBindingVersion,
    identityPublicKey: identity,
    deviceId: material.deviceId,
    transportPublicKey: material.transportPublicKey,
    hypercorePublicKey: material.hypercorePublicKey,
    capabilities: capabilities,
    createdAt: createdAt,
    expiresAt: expiresAt,
    signatureByIdentityKey: Uint8List(0),
  );
  final signature = await (sign ?? signBytes)(draft.signedPayload());
  if (signature.isEmpty) {
    throw StateError('device binding signature is unavailable');
  }
  return DeviceBinding(
    version: draft.version,
    identityPublicKey: draft.identityPublicKey,
    deviceId: draft.deviceId,
    transportPublicKey: draft.transportPublicKey,
    hypercorePublicKey: draft.hypercorePublicKey,
    capabilities: draft.capabilities,
    createdAt: draft.createdAt,
    expiresAt: draft.expiresAt,
    signatureByIdentityKey: signature,
  );
}

Future<void> authorizeLocalDevice(LocalDeviceMaterial material) async {
  deviceRegistry.authorize(
    AuthorizedDevice(
      deviceId: material.deviceId,
      transportPublicKey: material.transportPublicKey,
      hypercorePublicKey: material.hypercorePublicKey,
      name: 'this-device',
      kind: kLocalDeviceKind,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: DeviceStatus.active,
    ),
  );
}

bool _isPlaceholder(List<int> bytes) {
  if (bytes.isEmpty) return true;
  final first = bytes.first;
  return bytes.every((b) => b == first);
}

Uint8List _asBytes(Object? raw) {
  if (raw is List<int>) return Uint8List.fromList(raw);
  if (raw is String && raw.isNotEmpty) {
    try {
      return Uint8List.fromList(base64Decode(raw));
    } catch (_) {
      return Uint8List(0);
    }
  }
  return Uint8List(0);
}

Uint8List _randomKey() {
  final rng = Random.secure();
  return Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
}

String _newDeviceId() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

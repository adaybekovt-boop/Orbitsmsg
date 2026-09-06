// Connect-time authorization. Signature-by-embedded-key is not enough:
// the identity key must already be trusted, the device must already be
// registered, and the Noise key must match the binding.

import '../devices/device_registry.dart';
import '../peer/helpers.dart';
import 'device_binding.dart';
import 'trusted_identity_store.dart';

enum BindingAuthDecision {
  reject,
  contact,
  ownDevice,
}

class BindingAuthResult {
  const BindingAuthResult.reject(this.reason)
    : decision = BindingAuthDecision.reject,
      device = null;

  const BindingAuthResult.contact(this.device)
    : decision = BindingAuthDecision.contact,
      reason = 'trusted-contact';

  const BindingAuthResult.ownDevice(this.device)
    : decision = BindingAuthDecision.ownDevice,
      reason = 'own-device';

  final BindingAuthDecision decision;
  final String reason;
  final AuthorizedDevice? device;

  bool get accepted => decision != BindingAuthDecision.reject;
  bool get ownDevicePrivileges => decision == BindingAuthDecision.ownDevice;
}

Future<BindingAuthResult> authorizeIncomingBinding({
  required DeviceBinding binding,
  required List<int>? connectionNoisePublicKey,
  required String transportPeerId,
  required String selfPeerId,
  required TrustedIdentityStore identities,
  required DeviceRegistry? devices,
  int? nowMs,
}) async {
  final logical = normalizePeerId(binding.ownerPeerId);
  final self = normalizePeerId(selfPeerId);
  final transport = normalizePeerId(transportPeerId);

  if (logical.isEmpty || binding.deviceId.isEmpty) {
    return const BindingAuthResult.reject('missing-owner-or-device');
  }
  if (!await verifyDeviceBinding(binding, nowMs: nowMs)) {
    return const BindingAuthResult.reject('signature-or-clock');
  }
  if (connectionNoisePublicKey != null &&
      connectionNoisePublicKey.isNotEmpty &&
      !noiseKeyMatchesBinding(
        connectionNoisePublicKey: connectionNoisePublicKey,
        binding: binding,
      )) {
    return const BindingAuthResult.reject('noise-mismatch');
  }

  final trusted = identities.lookup(logical);
  if (trusted == null) {
    return const BindingAuthResult.reject('unknown-identity');
  }
  if (trusted.tofuOnly) {
    return const BindingAuthResult.reject('tofu-is-not-authorization');
  }
  if (!identityKeysEqual(trusted.identityPublicKey, binding.identityPublicKey)) {
    return const BindingAuthResult.reject('identity-key-mismatch');
  }

  final registry = devices;
  if (registry == null) {
    return const BindingAuthResult.reject('device-registry-required');
  }
  AuthorizedDevice? registered;
  for (final device in registry.all) {
    if (device.deviceId != binding.deviceId) continue;
    registered = device;
    break;
  }
  if (registered == null) {
    return const BindingAuthResult.reject('unknown-device');
  }
  if (registered.status == DeviceStatus.revoked) {
    return const BindingAuthResult.reject('revoked-device');
  }
  if (normalizePeerId(registered.ownerPeerId) != logical) {
    return const BindingAuthResult.reject('device-owner-mismatch');
  }
  if (registered.transportPublicKey.isNotEmpty &&
      !identityKeysEqual(
        registered.transportPublicKey,
        binding.transportPublicKey,
      )) {
    return const BindingAuthResult.reject('registered-noise-mismatch');
  }
  if (registered.transportPeerId != null &&
      registered.transportPeerId!.isNotEmpty &&
      normalizePeerId(registered.transportPeerId) != transport) {
    return const BindingAuthResult.reject('transport-id-mismatch');
  }

  final claimsSelf = logical == self;
  if (claimsSelf) {
    if (!trusted.isSelf) {
      return const BindingAuthResult.reject('self-identity-not-marked');
    }
    return BindingAuthResult.ownDevice(registered);
  }

  if (trusted.isSelf) {
    return const BindingAuthResult.reject('self-identity-on-foreign-owner');
  }
  return BindingAuthResult.contact(registered);
}

/// Own-device privileges come only from a registered own device whose
/// owner matches the local identity. A peer-id string is never enough.
bool registrySaysOwnDevice({
  required String peerId,
  required String selfPeerId,
  required DeviceRegistry? devices,
  DeviceBinding? binding,
}) {
  final self = normalizePeerId(selfPeerId);
  final norm = normalizePeerId(peerId);
  if (self.isEmpty || devices == null) return false;
  for (final device in devices.active) {
    if (normalizePeerId(device.ownerPeerId) != self) continue;
    final transportId = device.transportPeerId;
    if (transportId != null && normalizePeerId(transportId) == norm) {
      return true;
    }
    if (binding != null && device.deviceId == binding.deviceId) {
      return true;
    }
  }
  return false;
}

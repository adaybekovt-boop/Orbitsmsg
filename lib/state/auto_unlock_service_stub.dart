// Web stub for biometric auto-unlock. The web build has no hardware-backed
// biometric keystore, so the feature is always unsupported and every call is a
// safe no-op. (Keeps `dart:io`/SecureKekVault out of the web build.)

import 'dart:typed_data';

import 'auto_unlock_service.dart';

AutoUnlockService createAutoUnlockService() => const _StubAutoUnlockService();

class _StubAutoUnlockService implements AutoUnlockService {
  const _StubAutoUnlockService();

  @override
  bool get isSupported => false;

  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<bool> hasStoredKek() async => false;

  @override
  Future<AutoUnlockResult> retrieve() async =>
      const AutoUnlockResult(AutoUnlockStatus.unavailable);

  @override
  Future<bool> enable(Uint8List? kekBytes) async => false;

  @override
  Future<void> disable() async {}

  @override
  Future<void> refresh(Uint8List? kekBytes) async {}

  @override
  Future<void> clear() async {}
}

// Real biometric auto-unlock (dart:io platforms). Wraps [SecureKekVault]
// (Android Keystore / iOS Keychain) and the SharedPreferences on/off flag.

import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../storage/secure_kek_vault.dart';
import 'auto_unlock_service.dart';

AutoUnlockService createAutoUnlockService() => IoAutoUnlockService();

class IoAutoUnlockService implements AutoUnlockService {
  IoAutoUnlockService({SecureKekVault? vault})
      : _vault = vault ?? SecureKekVault();

  final SecureKekVault _vault;

  @override
  bool get isSupported => SecureKekVault.isSupported;

  @override
  Future<bool> isEnabled() async {
    if (!isSupported) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(kBiometricUnlockPrefKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> hasStoredKek() async {
    if (!isSupported) return false;
    return _vault.hasStoredKek();
  }

  @override
  Future<AutoUnlockResult> retrieve() async {
    if (!isSupported) {
      return const AutoUnlockResult(AutoUnlockStatus.unavailable);
    }
    final r = await _vault.retrieveKek();
    switch (r.status) {
      case KekRetrieveStatus.ok:
        return AutoUnlockResult(AutoUnlockStatus.ok, kek: r.bytes);
      case KekRetrieveStatus.notStored:
      case KekRetrieveStatus.unsupported:
        return const AutoUnlockResult(AutoUnlockStatus.unavailable);
      case KekRetrieveStatus.cancelled:
      case KekRetrieveStatus.lockedOut:
        return const AutoUnlockResult(AutoUnlockStatus.cancelled);
      case KekRetrieveStatus.biometricInvalidated:
        // Stale entry already deleted by SecureKekVault; also clear our flag so
        // the UI reflects "off" until the user re-enables.
        await _clearFlag();
        return const AutoUnlockResult(AutoUnlockStatus.invalidated);
      case KekRetrieveStatus.error:
        return const AutoUnlockResult(AutoUnlockStatus.error);
    }
  }

  @override
  Future<bool> enable(Uint8List? kekBytes) async {
    if (!isSupported) return false;
    if (kekBytes == null || kekBytes.length != 32) return false;
    try {
      await _vault.storeKek(kekBytes);
      await _setFlag(true);
      return true;
    } catch (_) {
      // Storing failed — make sure we don't leave the flag on without a KEK.
      await _vault.deleteKek();
      await _clearFlag();
      return false;
    }
  }

  @override
  Future<void> disable() async {
    await _vault.deleteKek();
    await _clearFlag();
  }

  @override
  Future<void> refresh(Uint8List? kekBytes) async {
    if (!isSupported) return;
    if (kekBytes == null || kekBytes.length != 32) return;
    if (!await isEnabled()) return;
    try {
      await _vault.storeKek(kekBytes);
    } catch (_) {
      // Non-fatal: a refresh failure just means the next launch falls back to
      // the password, which is safe.
    }
  }

  @override
  Future<void> clear() async {
    await _vault.deleteKek();
    await _clearFlag();
  }

  Future<void> _setFlag(bool v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kBiometricUnlockPrefKey, v);
    } catch (_) {}
  }

  Future<void> _clearFlag() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kBiometricUnlockPrefKey);
    } catch (_) {}
  }
}

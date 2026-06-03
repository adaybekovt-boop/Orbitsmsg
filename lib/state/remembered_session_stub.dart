// Native/default stub for the web "Remember me" session store.
//
// Persisting an unlocked session across restarts is a *web* feature: the
// browser tab dies on every reload, dropping the in-RAM vault KEK. Native
// builds keep the process (and the KEK) alive, and have the OS keychain
// (`SecureKekVault`) for biometric auto-unlock, so there's nothing to do here.

import 'dart:typed_data';

/// Whether secure remembered-session storage is available. Always false off-web.
Future<bool> isRememberSupported() async => false;

/// Persist the 32-byte vault KEK for auto-unlock. No-op on native.
Future<void> persistKek(List<int> kek) async {}

/// Load a previously remembered KEK, or null. Always null on native.
Future<Uint8List?> loadKek() async => null;

/// Forget any remembered KEK. No-op on native.
Future<void> clearRememberedKek() async {}

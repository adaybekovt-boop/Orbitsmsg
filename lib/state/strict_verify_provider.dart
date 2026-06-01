// "Строгая проверка контактов" (strict TOFU) toggle.
//
// When ON (default), a chat with a contact whose identity key is pinned but
// NOT yet user-verified (trustLevel == 1, "Защищён") is gated: the message
// list + composer are hidden behind a "confirm identity" wall until the user
// compares the safety code and marks the contact "Проверен" (trustLevel == 2).
// This closes the silent-TOFU window flagged in the security audit (a MITM
// present at first contact would be pinned silently) — see `acceptHello`'s
// `firstContact` flag (audit H1) in `core/wire_session.dart`.
//
// The crypto layer is untouched: messages still decrypt + persist normally so
// the Double Ratchet stays in sync; only their *display* is withheld. The
// toggle is global (no per-chat bypass) so "strict" actually means strict —
// the only way to read an unverified chat is to verify it or turn this off.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kStrictVerifyKey = 'orbits_strict_verify_v1';

class StrictVerifyController extends StateNotifier<bool> {
  // Default ON — the secure-by-default posture. Hydrated from disk async.
  StrictVerifyController() : super(true) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kStrictVerifyKey);
      state = raw == null ? true : raw == '1';
    } catch (_) {
      state = true;
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kStrictVerifyKey, value ? '1' : '0');
    } catch (_) {
      // Persist failure is non-fatal — the in-memory state still applies for
      // this session, matching how the other Security toggles behave.
    }
  }
}

/// Whether strict contact verification is enabled. Watch it in the chat view
/// to decide whether to gate an unverified peer.
final strictVerifyProvider =
    StateNotifierProvider<StrictVerifyController, bool>(
  (ref) => StrictVerifyController(),
);

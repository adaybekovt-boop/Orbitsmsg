// Port of src/core/identity.js — peerId + displayName persistence.
//
// This sits ABOVE the cryptographic identity (see `identity_key.dart`):
// those are long-lived ECDSA/ECDH keys the ratchet and TOFU pins depend on.
// The "identity" here is just the user-facing peerId (ORBIT- + 6 or 16 hex)
// display name — non-secret metadata that lives next to it.
//
// Storage mapping:
//   JS localStorage 'orbits_identity_v1' → SharedPreferences same key (JSON).
//   JS localStorage 'orbits_peer_id'      → SharedPreferences same key (plain
//                                           string, legacy fallback from
//                                           before the JSON record existed).
//
// The MVP port drops the peerId-collision reservation registry (`registry.js`
// in JS). That mattered when the same browser hosted multiple test accounts;
// on a single-profile-per-device mobile app it's effectively a no-op, and we
// can add it back as an optional [PeerIdReserver] hook later.

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

const String _kIdentityKey = 'orbits_identity_v1';
const String _kLegacyPeerIdKey = 'orbits_peer_id';

/// Legacy ids are 6 hex chars (24 bits). New ids are 16 hex chars (64 bits).
/// Both remain valid so existing contacts keep working.
final RegExp _peerIdRe = RegExp(r'^ORBIT-[0-9A-F]{6}(?:[0-9A-F]{10})?$');
final Random _random = Random.secure();

/// Immutable view of the user-facing identity.
class LocalIdentity {
  const LocalIdentity({required this.peerId, required this.displayName});
  final String peerId;
  final String displayName;

  LocalIdentity copyWith({String? peerId, String? displayName}) =>
      LocalIdentity(
        peerId: peerId ?? this.peerId,
        displayName: displayName ?? this.displayName,
      );

  Map<String, Object?> toJson() => {
        'peerId': peerId,
        'displayName': displayName,
      };
}

bool isValidPeerId(String? id) => id != null && _peerIdRe.hasMatch(id);

/// Generate a random ORBIT- peer id. New ids use 8 random bytes (64 bits) —
/// the old 3-byte / 24-bit space was enumerable and collided quickly.
/// [isValidPeerId] still accepts legacy `ORBIT-` + 6 hex so existing
/// contacts keep working.
String generatePeerId() {
  final b = List<int>.generate(8, (_) => _random.nextInt(256));
  final hex = b
      .map((v) => v.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  return 'ORBIT-$hex';
}

String _normalizeName(Object? input) {
  final s = (input is String) ? input : input?.toString() ?? '';
  final trimmed = s.trim();
  return trimmed.length > 64 ? trimmed.substring(0, 64) : trimmed;
}

/// Try to load the persisted identity. Returns null if nothing valid is
/// stored. Mirrors `getIdentity()` including the legacy peerId fallback.
Future<LocalIdentity?> getIdentity() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kIdentityKey);
  if (raw != null && raw.isNotEmpty) {
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map) {
        final peerId = parsed['peerId'];
        final displayName = parsed['displayName'];
        if (peerId is String && isValidPeerId(peerId)) {
          return LocalIdentity(
            peerId: peerId,
            displayName: _normalizeName(displayName),
          );
        }
      }
    } catch (_) {
      // Corrupt JSON — fall through to legacy fallback.
    }
  }

  final legacy = prefs.getString(_kLegacyPeerIdKey);
  if (legacy != null && isValidPeerId(legacy)) {
    return LocalIdentity(peerId: legacy, displayName: '');
  }
  return null;
}

/// Persist [next]. Throws [ArgumentError] if the peerId isn't well-formed so
/// callers can't accidentally stash garbage.
Future<LocalIdentity> setIdentity(LocalIdentity next) async {
  if (!isValidPeerId(next.peerId)) {
    throw ArgumentError('identity: invalid peerId "${next.peerId}"');
  }
  final prefs = await SharedPreferences.getInstance();
  final normalized = LocalIdentity(
    peerId: next.peerId,
    displayName: _normalizeName(next.displayName),
  );
  await prefs.setString(_kIdentityKey, jsonEncode(normalized.toJson()));
  await prefs.setString(_kLegacyPeerIdKey, normalized.peerId);
  return normalized;
}

/// Ensure an identity exists. Creates a fresh peerId on first call.
Future<LocalIdentity> getOrCreateIdentity() async {
  final existing = await getIdentity();
  if (existing != null) return existing;
  return setIdentity(LocalIdentity(peerId: generatePeerId(), displayName: ''));
}

/// Shortcut when only the peerId is needed (e.g. hello-blob construction).
Future<String> getOrCreatePeerId() async =>
    (await getOrCreateIdentity()).peerId;

/// Update just the display name, keeping the peerId. Falls back to creating
/// an identity if none exists yet.
Future<LocalIdentity> setDisplayName(String displayName) async {
  final current = await getOrCreateIdentity();
  return setIdentity(current.copyWith(displayName: _normalizeName(displayName)));
}

/// Wipe and regenerate. Used on "Сбросить профиль" — the new peerId is
/// returned so the caller can update any UI state immediately.
Future<LocalIdentity> resetIdentity() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kIdentityKey);
  await prefs.remove(_kLegacyPeerIdKey);
  return setIdentity(LocalIdentity(peerId: generatePeerId(), displayName: ''));
}

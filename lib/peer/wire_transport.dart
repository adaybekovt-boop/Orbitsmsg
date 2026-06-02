// Port of `src/hooks/useWireHandshake.js` — the encrypted-send helpers and
// the per-connection wire-handshake sequence.
//
// The JS hook returns three closures (`sendEncrypted`, `sendEncryptedEphemeral`,
// `initiateHandshakeOnOpen`) that capture React refs. Dart doesn't need that
// closure dance: the methods take a [PeerDataConnection] directly, and
// identity is read via a `selfPeerId` callback so the caller keeps owning
// the source of truth (authNotifier / identity store). This also breaks what
// would otherwise be a provider-cycle with [ConnectionRegistry].
//
// All three methods are "best effort" — failure never throws, it returns
// `false` (or silently completes for the handshake). The caller is expected
// to surface UX via the connection status channel, not exceptions.

import '../core/wire_crypto.dart';
import 'helpers.dart';
import 'peerjs_client.dart';

class WireTransport {
  WireTransport({required this.selfPeerId});

  /// Dynamic read of our own peerId. Wrapped in a callback so a logout /
  /// identity-reset invalidates it for the next send without requiring a
  /// rebuild of [WireTransport].
  final String Function() selfPeerId;

  /// Reliable-channel send. Waits up to 8s for the wire session to become
  /// ready (handshake rebuild) before encrypting. Returns `false` on any
  /// error, timeout, or missing/closed connection.
  Future<bool> sendEncryptedOn(
    PeerDataConnection conn,
    String remoteId,
    Object? msg,
  ) async {
    if (!conn.open) return false;
    final norm = normalizePeerId(remoteId);
    try {
      if (!isWireReady(norm)) {
        await waitForWireReady(norm, timeout: const Duration(seconds: 8));
      }
      final wire = await encryptWirePayload(norm, msg);
      conn.send(wire);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Encrypt [msg] for [remoteId] WITHOUT sending it anywhere — returns the
  /// opaque wire-ciphertext String (the same Double-Ratchet envelope a
  /// DataChannel would carry), or `null` if no wire session is ready / encrypt
  /// fails. Used by the relay fallback: the caller hands the returned String to
  /// the relay as an opaque frame, so the relay never sees plaintext. Unlike
  /// [sendEncryptedOn] this does NOT wait for a handshake — the relay path only
  /// makes sense once a session already exists (a fresh peer has no ratchet to
  /// encrypt with), so we fail fast rather than block.
  Future<String?> encryptFrame(String remoteId, Object? msg) async {
    final norm = normalizePeerId(remoteId);
    if (!isWireReady(norm)) return null;
    try {
      return await encryptWirePayload(norm, msg);
    } catch (_) {
      return null;
    }
  }

  /// Ephemeral-channel send. **Never waits** — if the wire session isn't
  /// ready, drop the packet. Heartbeats and typing indicators are
  /// non-critical and shouldn't queue up behind a stalled handshake.
  Future<bool> sendEphemeralOn(
    PeerDataConnection conn,
    String remoteId,
    Object? msg,
  ) async {
    if (!conn.open) return false;
    final norm = normalizePeerId(remoteId);
    if (!isWireReady(norm)) return false;
    try {
      final wire = await encryptWirePayload(norm, msg);
      conn.send(wire);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Build (but do NOT send) the X3DH/Noise `wireHello` for [remoteId]. Used
  /// by the relay fallback to bootstrap a session when no DataChannel ever
  /// opened: the caller relays the returned hello (public-key material only).
  /// Returns `null` if the handshake init fails.
  Future<Map<String, Object?>?> createHandshakeHello(String remoteId) async {
    final norm = normalizePeerId(remoteId);
    try {
      final result = await initWireSession(peerId: norm, myPeerId: selfPeerId());
      return result.hello;
    } catch (_) {
      return null;
    }
  }

  /// Called after a reliable DataConnection opens. Kicks the X3DH/Noise
  /// handshake and waits for the session to become ready (or times out
  /// after 8s). Both failure modes are swallowed — the connection listener
  /// triggers a rekey if the peer sends traffic before a session exists.
  Future<void> initiateHandshakeOnOpen(
    PeerDataConnection conn,
    String remoteId,
  ) async {
    final norm = normalizePeerId(remoteId);
    try {
      final result = await initWireSession(peerId: norm, myPeerId: selfPeerId());
      try {
        conn.send(result.hello);
      } catch (_) {}
      await waitForWireReady(norm, timeout: const Duration(seconds: 8))
          .catchError((_) {});
    } catch (_) {
      // Handshake errors bubble from the ratchet layer — swallow so the
      // caller doesn't have to wrap. If the session never becomes ready,
      // the next sendEncryptedOn will surface the issue as `false`.
    }
  }
}

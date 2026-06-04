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

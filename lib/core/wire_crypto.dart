// Port of src/core/wireCrypto.js — thin facade over wire_session.dart.
//
// Keeps the public surface of the JS module so the rest of the app can call
// the same names (initWireSession, encryptWirePayload, …) without knowing
// about the ratchet internals underneath.

import 'wire_session.dart' as session;

const int orbitWireVersion = 2;

class WireSessionHandshake {
  const WireSessionHandshake({required this.version, required this.hello});
  final int version;
  final Map<String, Object?> hello;
}

/// Begin a session with a peer. Returns the handshake hello message the caller
/// should send over the reliable channel. Must be followed by [acceptWireHello]
/// once the peer's reply arrives.
Future<WireSessionHandshake> initWireSession({
  required String peerId,
  required String myPeerId,
}) async {
  final hello =
      await session.initiateHandshake(peerId: peerId, myPeerId: myPeerId);
  return WireSessionHandshake(version: orbitWireVersion, hello: hello);
}

/// Process an incoming wireHello (or wireRekey). Returns the accept outcome
/// (reply message to send, verified flag, peer fingerprint).
Future<session.AcceptHelloResult> acceptWireHello({
  required String peerId,
  required String myPeerId,
  required Map<String, Object?> helloMsg,
}) =>
    session.acceptHello(peerId: peerId, myPeerId: myPeerId, hello: helloMsg);

({bool ready, int version}) getWireSessionStatus(String peerId) =>
    (ready: session.isReady(peerId), version: orbitWireVersion);

Future<void> waitForWireReady(String peerId, {Duration? timeout}) =>
    session.waitReady(peerId, timeout: timeout);

Future<void> teardownWireSession(String peerId) =>
    session.teardownSession(peerId);

Future<String> encryptWirePayload(String peerId, Object? obj) =>
    session.encryptOutbound(peerId, obj);

Future<Object?> decryptWirePayload(
  String peerId,
  String wireStr, {
  bool commit = true,
}) =>
    session.decryptInbound(peerId, wireStr, commit: commit);

bool isWireReady(String peerId) => session.isReady(peerId);

bool isWireCiphertext(Object? data) => session.isWireCiphertext(data);

/// Read-only verification snapshot — see [session.WireVerification].
session.WireVerification? getWireVerification(String peerId) =>
    session.getVerification(peerId);

/// Development assertion — warns if a non-encrypted / non-handshake payload
/// is going out on a connection. No-op in release builds (the `assert` body
/// only runs in debug mode).
void assertEncryptedOrHandshake(Object? data) {
  assert(() {
    if (data is String && session.isWireCiphertext(data)) return true;
    if (data is Map &&
        (data['type'] == 'wireHello' || data['type'] == 'wireRekey')) {
      return true;
    }
    // ignore: avoid_print
    print(
      '[wireCrypto] Unencrypted payload detected: ${data is Map ? data['type'] : data.runtimeType}',
    );
    return true;
  }());
}

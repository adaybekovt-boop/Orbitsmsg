// Port of src/core/wireSession.js — per-peer handshake state machine on top
// of the Double Ratchet.
//
// Handshake protocol (byte-compatible with the React build):
//
//   v2 (legacy, unsigned): { type: 'wireHello', v: 2, pub }
//   v3 (signed):           { type: 'wireHello', v: 3, pub, idPub, sig }
//   v4 (signed + X3DH):    v3 fields + x3dhIk, x3dhIkSig, ek, spkId, opkId?
//
// v3+ hellos carry an ECDSA-P256/SHA-256 signature over [buildSignedHelloBlob].
// A v3+ hello with an invalid signature is rejected outright — no ratchet, no
// shared secret. The first verified hello from a peer pins their identity
// fingerprint (TOFU); subsequent hellos that don't match the pin are rejected
// until the user explicitly clears the pin.
//
// Alice/Bob roles are assigned deterministically: the peer with the
// lexicographically smaller peerId is Alice (initiator).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'base64_helpers.dart';
import 'double_ratchet.dart' as ratchet;
import 'feature_flags.dart';
import 'identity_key.dart' as identity_key;
import 'key_store.dart';
import 'peer_pins.dart';
import 'spki_codec.dart';
import 'vault_kek.dart';
import 'x3dh_session.dart';

const String _hkdfSaltTag = 'orbits-wire-v2';
const String _ratchetTable = 'ratchets';
const String _ratchetRowPrefix = 'ratchet-';

/// Upper bound on buffered inbound ciphertexts per peer while the ratchet
/// warms up — prevents an unbounded queue from a misbehaving sender.
const int _maxPendingInbound = 64;

/// How long an inbound ciphertext waits for the ratchet to come up before it
/// is rejected with a timeout.
const Duration _pendingInboundTimeout = Duration(seconds: 15);

/// Default waitReady timeout, matching the JS 8-second fallback.
const Duration _defaultWaitReadyTimeout = Duration(seconds: 8);

// ─────────────────────────────────────────────────────────────
// Session registry
// ─────────────────────────────────────────────────────────────

class _PendingInbound {
  _PendingInbound(this.wireStr, this.completer, this.timer);
  final String wireStr;
  final Completer<Object?> completer;
  final Timer timer;
}

class _Session {
  _Session(this.peerId);

  final String peerId;
  ratchet.RatchetState? state;
  EcKeyPair? localDhKeyPair;
  Uint8List? localDhPubSpki;
  Uint8List? remoteDhPubSpki;

  Uint8List? remoteIdSpki;
  String? remoteFingerprint;
  bool verified = false;
  int? protocolVersion; // 2 | 3 | 4

  Uint8List? bootstrapSk;
  String? role; // 'alice' | 'bob'
  bool ready = false;
  Completer<void> readyCompleter = Completer<void>();

  /// Serialises persistence writes so concurrent encrypt/decrypt calls don't
  /// race each other to saveRatchetState.
  Future<void> persistLock = Future<void>.value();
}

final Map<String, _Session> _sessions = <String, _Session>{};
final Map<String, List<_PendingInbound>> _pendingInbound =
    <String, List<_PendingInbound>>{};

_Session _getOrCreateSession(String peerId) =>
    _sessions.putIfAbsent(peerId, () => _Session(peerId));

void _resetPendingReady(_Session s) {
  if (s.readyCompleter.isCompleted) {
    s.readyCompleter = Completer<void>();
  }
  s.ready = false;
}

// ─────────────────────────────────────────────────────────────
// Shared-secret derivation (v2/v3 fallback path)
// ─────────────────────────────────────────────────────────────

final _ecdh = Ecdh.p256(length: 32);

Future<Uint8List> _deriveSharedSecret({
  required EcKeyPair localPriv,
  required List<int> remoteSpki,
  required String myPeerId,
  required String peerId,
}) async {
  final point = parseP256Spki(remoteSpki);
  final remoteKey =
      EcPublicKey(x: point.x, y: point.y, type: KeyPairType.p256);
  final shared = await _ecdh.sharedSecretKey(
    keyPair: localPriv,
    remotePublicKey: remoteKey,
  );
  final sharedBytes = Uint8List.fromList(await shared.extractBytes());

  // Transcript-bound salt so the shared secret is scoped to this peer pair.
  final sorted = <String>[myPeerId, peerId]..sort();
  final saltData = utf8.encode('$_hkdfSaltTag|${sorted.join('|')}');

  return ratchet.hkdfBits(
    ikm: sharedBytes,
    salt: saltData,
    infoStr: 'sk',
    lenBytes: 32,
  );
}

// ─────────────────────────────────────────────────────────────
// Persistence (KeyStore-backed ratchet snapshots)
// ─────────────────────────────────────────────────────────────

String _ratchetRowKey(String peerId) => '$_ratchetRowPrefix$peerId';

Future<Object?> _maybeWrap(Object? value) async {
  if (value == null) return null;
  return hasVaultKek() ? await wrapBytes(value) : value;
}

Future<Uint8List?> _maybeUnwrap(Object? value) async {
  if (value == null) return null;
  final unwrapped = await unwrapBytes(value);
  if (unwrapped == null) return null;
  if (unwrapped is Uint8List) return unwrapped;
  if (unwrapped is List<int>) return Uint8List.fromList(unwrapped);
  throw StateError('ratchet: unexpected unwrapped type ${unwrapped.runtimeType}');
}

Future<Map<String, Object?>> _serializeSkipped(
    Map<String, Uint8List> skipped) async {
  final shouldWrap = hasVaultKek();
  final out = <String, Object?>{};
  for (final entry in skipped.entries) {
    out[entry.key] = shouldWrap ? await wrapBytes(entry.value) : entry.value;
  }
  return out;
}

Future<Map<String, Uint8List>> _deserializeSkipped(Object? raw) async {
  final out = <String, Uint8List>{};
  if (raw is! Map) return out;
  for (final entry in raw.entries) {
    try {
      final v = await _maybeUnwrap(entry.value);
      if (v != null) out['${entry.key}'] = v;
    } catch (_) {
      // One corrupt entry shouldn't kill the session — drop it.
    }
  }
  return out;
}

Future<void> _saveRatchetSnapshot(_Session session) async {
  final state = session.state;
  if (state == null) return;
  final dhPriv = Uint8List.fromList(
    // cryptography 2.9 EcKeyPair path — scalar lives on extracted data.
    (await state.dhKeyPair.extract()).d,
  );

  final shouldWrap = hasVaultKek();
  final snapshot = <String, Object?>{
    'id': _ratchetRowKey(session.peerId),
    'peerId': session.peerId,
    'role': session.role,
    'encVersion': shouldWrap ? 1 : 0,
    'rootKey': await _maybeWrap(state.rootKey),
    'sendCk': await _maybeWrap(state.sendCk),
    'recvCk': await _maybeWrap(state.recvCk),
    'dhPriv': await _maybeWrap(dhPriv),
    'dhPubSpki': state.dhPubSpki,
    'remoteDhPub': state.remoteDhPub,
    'Ns': state.ns,
    'Nr': state.nr,
    'PN': state.pn,
    'skipped': await _serializeSkipped(state.skipped),
    'remoteIdSpki': session.remoteIdSpki,
    'remoteFingerprint': session.remoteFingerprint,
    'verified': session.verified,
    'protocolVersion': session.protocolVersion,
    'updatedAt': DateTime.now().millisecondsSinceEpoch,
  };
  await keyStore().put(_ratchetTable, snapshot);
}

Future<void> _persistSession(_Session session) {
  session.persistLock = session.persistLock.then((_) async {
    try {
      await _saveRatchetSnapshot(session);
    } catch (_) {
      // Persistence failures are non-fatal — forward secrecy may degrade
      // across restarts, but the live session is unaffected.
    }
  });
  return session.persistLock;
}

Future<_Session?> _hydrateSession(String peerId) async {
  try {
    final row = await keyStore().get(_ratchetTable, _ratchetRowKey(peerId));
    if (row == null) return null;

    final dhPubSpki = row['dhPubSpki'];
    final dhPrivRaw = row['dhPriv'];
    final rootKeyRaw = row['rootKey'];
    if (dhPubSpki is! List<int> ||
        dhPrivRaw == null ||
        rootKeyRaw == null) {
      try {
        await keyStore().delete(_ratchetTable, _ratchetRowKey(peerId));
      } catch (_) {}
      return null;
    }

    Uint8List rootKey;
    Uint8List? sendCk;
    Uint8List? recvCk;
    Uint8List dhPriv;
    try {
      rootKey = (await _maybeUnwrap(rootKeyRaw))!;
      sendCk = await _maybeUnwrap(row['sendCk']);
      recvCk = await _maybeUnwrap(row['recvCk']);
      dhPriv = (await _maybeUnwrap(dhPrivRaw))!;
    } catch (_) {
      // Vault locked — leave the row on disk for a later retry.
      return null;
    }

    final point = parseP256Spki(dhPubSpki);
    final keyPair = EcKeyPairData(
      d: dhPriv,
      x: point.x,
      y: point.y,
      type: KeyPairType.p256,
    );

    final skipped = await _deserializeSkipped(row['skipped']);
    final remoteDhPub = row['remoteDhPub'];

    final session = _getOrCreateSession(peerId);
    session.role = row['role'] as String?;
    session.state = ratchet.RatchetState(
      rootKey: rootKey,
      sendCk: sendCk,
      recvCk: recvCk,
      dhKeyPair: keyPair,
      dhPubSpki: Uint8List.fromList(dhPubSpki),
      remoteDhPub: remoteDhPub is List<int>
          ? Uint8List.fromList(remoteDhPub)
          : null,
      ns: (row['Ns'] as num?)?.toInt() ?? 0,
      nr: (row['Nr'] as num?)?.toInt() ?? 0,
      pn: (row['PN'] as num?)?.toInt() ?? 0,
      skipped: skipped,
    );
    session.localDhKeyPair = keyPair;
    session.localDhPubSpki = Uint8List.fromList(dhPubSpki);
    session.remoteDhPubSpki =
        remoteDhPub is List<int> ? Uint8List.fromList(remoteDhPub) : null;

    final remoteIdSpki = row['remoteIdSpki'];
    if (remoteIdSpki is List<int>) {
      session.remoteIdSpki = Uint8List.fromList(remoteIdSpki);
    }
    session.remoteFingerprint = row['remoteFingerprint'] as String?;
    session.verified = row['verified'] == true;
    session.protocolVersion = (row['protocolVersion'] as num?)?.toInt();

    if (session.state!.sendCk != null ||
        session.state!.recvCk != null ||
        session.role == 'bob') {
      session.ready = true;
      if (!session.readyCompleter.isCompleted) {
        session.readyCompleter.complete();
      }
    }
    return session;
  } catch (_) {
    return null;
  }
}

// ─────────────────────────────────────────────────────────────
// Signed hello build + verify
// ─────────────────────────────────────────────────────────────

/// Fields carried on a v4 signed hello (X3DH bootstrap).
class _V4Extras {
  _V4Extras({
    required this.x3dhIkSpki,
    required this.x3dhIkSig,
    required this.ekSpki,
    required this.spkId,
    this.opkId,
  });
  final Uint8List x3dhIkSpki;
  final Uint8List x3dhIkSig;
  final Uint8List ekSpki;
  final String spkId;
  final String? opkId;
}

Future<Map<String, Object?>> _buildSignedHello({
  required _Session session,
  required String myPeerId,
  required String peerId,
  String type = 'wireHello',
  InitiatorBootstrap? x3dhExtras,
}) async {
  final idSpki = await identity_key.exportIdentityPubSpki();
  final blob = identity_key.buildSignedHelloBlob(
    senderPeerId: myPeerId,
    receiverPeerId: peerId,
    senderDhSpki: session.localDhPubSpki!,
    senderIdSpki: idSpki,
    x3dhExtras: x3dhExtras == null
        ? null
        : identity_key.X3dhHelloExtras(
            x3dhIkSpki: x3dhExtras.myX3dhIkSpki,
            ekSpki: x3dhExtras.ekSpki,
            spkId: x3dhExtras.spkId,
            opkId: x3dhExtras.opkId,
          ),
  );
  final sig = await identity_key.signBytes(blob);

  final hello = <String, Object?>{
    'type': type,
    'v': x3dhExtras != null ? 4 : 3,
    'pub': bytesToBase64(session.localDhPubSpki!),
    'idPub': bytesToBase64(idSpki),
    'sig': bytesToBase64(sig),
  };
  if (x3dhExtras != null) {
    hello['x3dhIk'] = bytesToBase64(x3dhExtras.myX3dhIkSpki);
    hello['x3dhIkSig'] = bytesToBase64(x3dhExtras.myX3dhIkSig);
    hello['ek'] = bytesToBase64(x3dhExtras.ekSpki);
    hello['spkId'] = x3dhExtras.spkId;
    if (x3dhExtras.opkId != null) {
      hello['opkId'] = x3dhExtras.opkId;
    }
  }
  return hello;
}

class _HelloVerifyResult {
  _HelloVerifyResult({
    required this.idSpki,
    required this.fingerprint,
    required this.pinStatus,
  });
  final Uint8List idSpki;
  final String fingerprint;
  final PinStatus pinStatus;
}

Future<_HelloVerifyResult> _verifySignedHello({
  required Map<String, Object?> helloMsg,
  required String senderPeerId,
  required String receiverPeerId,
  required List<int> remoteDhSpki,
  _V4Extras? x3dhExtras,
}) async {
  final idPubB64 = helloMsg['idPub'];
  final sigB64 = helloMsg['sig'];
  if (idPubB64 is! String ||
      idPubB64.isEmpty ||
      sigB64 is! String ||
      sigB64.isEmpty) {
    throw StateError('signed hello missing idPub or sig');
  }
  Uint8List idSpki;
  Uint8List sigBytes;
  try {
    idSpki = base64ToBytes(idPubB64);
    sigBytes = base64ToBytes(sigB64);
  } catch (_) {
    throw const FormatException('signed hello has malformed base64 fields');
  }

  final blob = identity_key.buildSignedHelloBlob(
    senderPeerId: senderPeerId,
    receiverPeerId: receiverPeerId,
    senderDhSpki: remoteDhSpki,
    senderIdSpki: idSpki,
    x3dhExtras: x3dhExtras == null
        ? null
        : identity_key.X3dhHelloExtras(
            x3dhIkSpki: x3dhExtras.x3dhIkSpki,
            ekSpki: x3dhExtras.ekSpki,
            spkId: x3dhExtras.spkId,
            opkId: x3dhExtras.opkId,
          ),
  );
  final ok = await identity_key.verifyWithRemoteSpki(idSpki, blob, sigBytes);
  if (!ok) {
    throw StateError('wireHello signature verification failed — possible MITM');
  }

  final pin = await checkPin(senderPeerId, idSpki);
  if (pin.status == PinStatus.mismatch) {
    final expected = (pin.expected ?? '');
    final expectedShort = expected.length < 16 ? expected : expected.substring(0, 16);
    final got = pin.fingerprint;
    final gotShort = got.length < 16 ? got : got.substring(0, 16);
    throw StateError(
      'Peer $senderPeerId identity key changed (expected $expectedShort, '
      'got $gotShort) — possible MITM or legitimate key rotation. '
      'Clear the pin manually to accept the new key.',
    );
  }
  if (pin.status == PinStatus.newPin) {
    await setPin(senderPeerId, idSpki);
  }

  final fingerprint = await identity_key.computeFingerprint(idSpki);
  return _HelloVerifyResult(
    idSpki: idSpki,
    fingerprint: fingerprint,
    pinStatus: pin.status,
  );
}

// ─────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────

/// Called when the reliable DataChannel opens. Ensures a local DH key pair
/// exists, attempts to hydrate any persisted state, and returns the
/// wireHello the caller should send back.
Future<Map<String, Object?>> initiateHandshake({
  required String peerId,
  required String myPeerId,
}) async {
  await _hydrateSession(peerId);
  final session = _getOrCreateSession(peerId);

  if (session.localDhKeyPair == null) {
    final pair = await ratchet.generateDhKeyPair();
    session.localDhKeyPair = pair;
    session.localDhPubSpki = await ratchet.exportSpkiBytes(pair);
  }

  // Deterministic role assignment.
  session.role = myPeerId.compareTo(peerId) < 0 ? 'alice' : 'bob';

  // Force waitReady to block until the peer's hello arrives and the ratchet
  // resets — stale ratchet state can't encrypt messages the peer will accept.
  if (session.ready) {
    _resetPendingReady(session);
  }

  // X3DH fast path: if we're alice and have a cached bundle, bootstrap the
  // root key from X3DH instead of a plain DH-of-ephemerals round-trip.
  session.bootstrapSk = null;
  InitiatorBootstrap? x3dhExtras;
  if (session.role == 'alice' && isX3dhEnabled()) {
    try {
      final boot = await deriveInitiatorBootstrap(peerId);
      if (boot != null) {
        session.bootstrapSk = boot.sk;
        x3dhExtras = boot;
      }
    } catch (_) {
      // Fall through to v3 — the peer has no published bundle or the cache
      // was stale. Either way, a plain signed hello still works.
    }
  }

  return _buildSignedHello(
    session: session,
    myPeerId: myPeerId,
    peerId: peerId,
    x3dhExtras: x3dhExtras,
  );
}

/// Outcome of [acceptHello] — tells the caller whether it should send a
/// matching reply hello, and surfaces the verification/TOFU result for UI.
class AcceptHelloResult {
  const AcceptHelloResult({
    required this.verified,
    this.reply,
    this.fingerprint,
  });
  final bool verified;
  final Map<String, Object?>? reply;
  final String? fingerprint;
}

/// Process an incoming wireHello (or wireRekey). Verifies the signature
/// against the claimed identity, enforces the TOFU pin, and on success
/// finalises the ratchet state so outbound messages can flow.
Future<AcceptHelloResult> acceptHello({
  required String peerId,
  required String myPeerId,
  required Map<String, Object?> hello,
}) async {
  final session = _getOrCreateSession(peerId);

  final pubB64 = hello['pub'];
  if (pubB64 is! String || pubB64.isEmpty) {
    throw StateError('Hello missing pub');
  }
  final helloVerRaw = hello['v'];
  final helloVer = helloVerRaw is num ? helloVerRaw.toInt() : 0;
  final protocolVersion = helloVer >= 4 ? 4 : (helloVer >= 3 ? 3 : 2);
  final remoteDhSpki = base64ToBytes(pubB64);

  // Decode v4 fields up front — used both for signature verification and for
  // the responder X3DH replay below.
  _V4Extras? v4Extras;
  if (protocolVersion >= 4) {
    try {
      final x3dhIk = base64ToBytes('${hello['x3dhIk'] ?? ''}');
      final x3dhIkSig = base64ToBytes('${hello['x3dhIkSig'] ?? ''}');
      final ek = base64ToBytes('${hello['ek'] ?? ''}');
      final spkId = '${hello['spkId'] ?? ''}';
      final opkIdRaw = hello['opkId'];
      final opkId = (opkIdRaw is String && opkIdRaw.isNotEmpty) ? opkIdRaw : null;
      if (x3dhIk.isEmpty || ek.isEmpty || spkId.isEmpty) {
        throw const FormatException('v4 hello missing required X3DH fields');
      }
      v4Extras = _V4Extras(
        x3dhIkSpki: x3dhIk,
        x3dhIkSig: x3dhIkSig,
        ekSpki: ek,
        spkId: spkId,
        opkId: opkId,
      );
    } catch (err) {
      if (err is FormatException) rethrow;
      throw const FormatException('v4 hello has malformed X3DH fields');
    }
  }

  bool verified = false;
  Uint8List? remoteIdSpki;
  String? remoteFingerprint;
  if (protocolVersion >= 3) {
    final v = await _verifySignedHello(
      helloMsg: hello,
      senderPeerId: peerId,
      receiverPeerId: myPeerId,
      remoteDhSpki: remoteDhSpki,
      x3dhExtras: v4Extras,
    );
    verified = true;
    remoteIdSpki = v.idSpki;
    remoteFingerprint = v.fingerprint;
  }

  // If we haven't generated our own DH yet (peer's hello arrived before our
  // own open fired), do it now and return a matching hello to send back.
  Map<String, Object?>? reply;
  if (session.localDhKeyPair == null) {
    final pair = await ratchet.generateDhKeyPair();
    session.localDhKeyPair = pair;
    session.localDhPubSpki = await ratchet.exportSpkiBytes(pair);
    session.role = myPeerId.compareTo(peerId) < 0 ? 'alice' : 'bob';
    if (protocolVersion >= 3) {
      reply = await _buildSignedHello(
        session: session,
        myPeerId: myPeerId,
        peerId: peerId,
      );
    } else {
      reply = <String, Object?>{
        'type': 'wireHello',
        'v': 2,
        'pub': bytesToBase64(session.localDhPubSpki!),
      };
    }
  }

  session.remoteDhPubSpki = remoteDhSpki;
  session.protocolVersion = protocolVersion;
  session.verified = verified;
  session.remoteIdSpki = remoteIdSpki;
  session.remoteFingerprint = remoteFingerprint;

  // Treat wireRekey as a full reset; also reset on fresh wireHello if the
  // session was already completed (peer reconnected with new DH keys).
  final helloType = hello['type'];
  if (session.state != null && (helloType == 'wireRekey' || session.ready)) {
    session.state = null;
    _resetPendingReady(session);
  }

  // Clear any X3DH bootstrap secret left over from a previous handshake on
  // this session. Only a freshly-derived v4 secret (set just below) may feed
  // the `??` fallback at the `shared` derivation; otherwise a stale secret
  // would desync the ratchet when a non-X3DH hello/rekey arrives.
  session.bootstrapSk = null;

  // v4 responder: replay the X3DH DHs against our local prekey privates.
  if (v4Extras != null) {
    final boot = await deriveResponderBootstrap(
      senderIdSpki: remoteIdSpki,
      senderX3dhIkSpki: v4Extras.x3dhIkSpki,
      senderX3dhIkSig: v4Extras.x3dhIkSig,
      ekSpki: v4Extras.ekSpki,
      spkId: v4Extras.spkId,
      opkId: v4Extras.opkId,
    );
    if (!boot.ok || boot.sk == null) {
      throw StateError(boot.reason ?? 'x3dh responder failed');
    }
    session.bootstrapSk = boot.sk;
  }

  // Prefer an X3DH-derived bootstrap; otherwise fall back to the legacy
  // DH-of-ephemerals transcript-bound secret.
  final shared = session.bootstrapSk ??
      await _deriveSharedSecret(
        localPriv: session.localDhKeyPair!,
        remoteSpki: session.remoteDhPubSpki!,
        myPeerId: myPeerId,
        peerId: peerId,
      );

  if (session.role == 'alice') {
    session.state = await ratchet.ratchetInitAlice(
      sharedSecret: shared,
      remoteDhPubSpki: session.remoteDhPubSpki!,
    );
  } else {
    session.state = await ratchet.ratchetInitBob(
      sharedSecret: shared,
      dhKeyPair: session.localDhKeyPair!,
      dhPubSpki: session.localDhPubSpki!,
    );
  }
  session.ready = true;
  if (!session.readyCompleter.isCompleted) {
    session.readyCompleter.complete();
  }
  unawaited(_persistSession(session));
  unawaited(_drainPendingInbound(peerId));

  return AcceptHelloResult(
    verified: verified,
    reply: reply,
    fingerprint: remoteFingerprint,
  );
}

/// Wait until the ratchet is ready to encrypt an outgoing message.
Future<void> waitReady(String peerId, {Duration? timeout}) async {
  final session = _getOrCreateSession(peerId);
  if (session.ready) return;
  final t = timeout ?? _defaultWaitReadyTimeout;
  await session.readyCompleter.future.timeout(
    t,
    onTimeout: () =>
        throw TimeoutException('Wire session handshake timeout', t),
  );
}

bool isReady(String peerId) {
  final s = _sessions[peerId];
  return s != null && s.ready;
}

/// Encrypt an arbitrary Dart object → wire string. The object is JSON-encoded
/// first, so it must be JSON-safe (primitives, lists, maps with string keys).
Future<String> encryptOutbound(String peerId, Object? obj) async {
  final session = _getOrCreateSession(peerId);
  final state = session.state;
  if (!session.ready || state == null || state.sendCk == null) {
    throw StateError('Wire session not ready for send');
  }
  final ptBytes = utf8.encode(jsonEncode(obj));
  final envelope = await ratchet.ratchetEncrypt(state, ptBytes);
  unawaited(_persistSession(session));
  return ratchet.encodeWire(envelope);
}

/// Decrypt a wire string → Dart object. Buffers ciphertexts that arrive
/// before the handshake completes; they're drained when acceptHello finishes.
Future<Object?> decryptInbound(String peerId, String wireStr) async {
  var session = _sessions[peerId];
  if (session == null || session.state == null) {
    await _hydrateSession(peerId);
    session = _sessions[peerId];
  }
  if (session == null || session.state == null) {
    // Ratchet not ready yet — buffer the ciphertext and wait for acceptHello
    // to complete. Avoids silently dropping messages that arrive mid-race.
    return _bufferPendingInbound(peerId, wireStr);
  }

  final envelope = ratchet.decodeWire(wireStr);
  if (envelope == null) {
    throw const FormatException('Bad wire envelope');
  }
  final plaintext = await ratchet.ratchetDecrypt(session.state!, envelope);
  if (!session.ready) {
    session.ready = true;
    if (!session.readyCompleter.isCompleted) {
      session.readyCompleter.complete();
    }
  }
  unawaited(_persistSession(session));
  return jsonDecode(utf8.decode(plaintext));
}

Future<Object?> _bufferPendingInbound(String peerId, String wireStr) {
  final queue = _pendingInbound.putIfAbsent(peerId, () => <_PendingInbound>[]);
  if (queue.length >= _maxPendingInbound) {
    return Future<Object?>.error(
      StateError('Too many buffered ciphertexts before handshake'),
    );
  }
  final completer = Completer<Object?>();
  late Timer timer;
  timer = Timer(_pendingInboundTimeout, () {
    final q = _pendingInbound[peerId];
    if (q == null) return;
    q.removeWhere((e) => identical(e.completer, completer));
    if (q.isEmpty) _pendingInbound.remove(peerId);
    if (!completer.isCompleted) {
      completer.completeError(
        TimeoutException(
          'No ratchet state for peer (timeout)',
          _pendingInboundTimeout,
        ),
      );
    }
  });
  queue.add(_PendingInbound(wireStr, completer, timer));
  return completer.future;
}

Future<void> _drainPendingInbound(String peerId) async {
  final queue = _pendingInbound.remove(peerId);
  if (queue == null || queue.isEmpty) return;
  for (final entry in queue) {
    entry.timer.cancel();
    try {
      final result = await decryptInbound(peerId, entry.wireStr);
      if (!entry.completer.isCompleted) {
        entry.completer.complete(result);
      }
    } catch (err, st) {
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(err, st);
      }
    }
  }
}

/// Reset a session entirely (used by blockPeer, resetIdentity, etc.).
Future<void> teardownSession(String peerId) async {
  final s = _sessions.remove(peerId);
  if (s != null && !s.readyCompleter.isCompleted) {
    s.readyCompleter.completeError(StateError('Session torn down'));
  }
  final queue = _pendingInbound.remove(peerId);
  if (queue != null) {
    for (final entry in queue) {
      entry.timer.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(StateError('Session torn down'));
      }
    }
  }
  try {
    await keyStore().delete(_ratchetTable, _ratchetRowKey(peerId));
  } catch (_) {}
}

/// Handshake verification snapshot for a peer — used by the UI to render a
/// "verified" badge and the peer's fingerprint for out-of-band comparison.
class WireVerification {
  const WireVerification({
    required this.peerId,
    required this.verified,
    this.protocolVersion,
    this.fingerprint,
  });
  final String peerId;
  final bool verified;
  final int? protocolVersion;
  final String? fingerprint;
}

WireVerification? getVerification(String peerId) {
  final s = _sessions[peerId];
  if (s == null) return null;
  return WireVerification(
    peerId: s.peerId,
    verified: s.verified,
    protocolVersion: s.protocolVersion,
    fingerprint: s.remoteFingerprint,
  );
}

/// Whether a wire string looks like a ciphertext envelope produced by
/// [encryptOutbound]. Delegates to the ratchet's own prefix check.
bool isWireCiphertext(Object? data) => ratchet.isWireCiphertext(data);

/// Test hook — drop all in-memory session state.
void resetSessionsForTests() {
  for (final s in _sessions.values) {
    if (!s.readyCompleter.isCompleted) {
      s.readyCompleter.completeError(StateError('reset'));
    }
  }
  _sessions.clear();
  for (final queue in _pendingInbound.values) {
    for (final entry in queue) {
      entry.timer.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(StateError('reset'));
      }
    }
  }
  _pendingInbound.clear();
}

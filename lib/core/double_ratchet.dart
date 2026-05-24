// Port of src/core/doubleRatchet.js — Signal-style Double Ratchet.
//
// Provides forward secrecy (each message has an independent key from a one-way
// symmetric chain) and break-in recovery (on every new remote DH pubkey the
// root key is advanced via ECDH → HKDF). Skipped message keys are cached up
// to MAX_SKIPPED per receive chain so out-of-order delivery still decrypts.
//
// The wire format MUST stay byte-identical to the React build until every
// peer is on Flutter — see `encodeWire` / `decodeWire` below. Protocol
// constants (ROOT_INFO, CHAIN_INFO, MAX_SKIPPED, etc.) are therefore frozen.
//
// RatchetState mirrors the JS state object field-for-field. It is a plain
// mutable container; callers persist / restore it by copying the fields.

import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

import 'base64_helpers.dart';
import 'spki_codec.dart';

const int maxSkipped = 64;
const int maxSkipPerStep = 32;
const String rootInfo = 'orbits-ratchet-rk-v2';
const String chainInfo = 'orbits-ratchet-ck-v2';
const String wireVersion = 'v2';

final _ecdh = Ecdh.p256(length: 32);
final _aes = AesGcm.with256bits();

// Dart `cryptography` 2.7.x has bug #176: HKDF throws ArgumentError when salt
// is empty. RFC 5869 says an absent salt should be replaced with hashLen zero
// bytes — for SHA-256 that's 32. KDF_CK hits this because the JS side passes
// `new Uint8Array(0)`. We substitute Uint8List(32) for byte-identical output.
final Uint8List _kdfCkSalt = Uint8List(32);

/// HKDF-SHA256 helper matching the JS `hkdfBits`. [salt] may be empty; in that
/// case we substitute 32 zero bytes to work around the package bug while
/// staying RFC-5869 compliant (the derivation is identical either way).
Future<Uint8List> hkdfBits({
  required List<int> ikm,
  required List<int> salt,
  required String infoStr,
  required int lenBytes,
}) async {
  final kdf = Hkdf(hmac: Hmac.sha256(), outputLength: lenBytes);
  final effectiveSalt = salt.isEmpty ? _kdfCkSalt : salt;
  final derived = await kdf.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: effectiveSalt,
    info: utf8.encode(infoStr),
  );
  return Uint8List.fromList(await derived.extractBytes());
}

/// KDF_RK: advance root key with fresh DH output. Returns (rk', ck).
/// Mirrors doubleRatchet.js:49-52.
Future<({Uint8List rootKey, Uint8List chainKey})> kdfRk({
  required List<int> rootKey,
  required List<int> dhOutput,
}) async {
  final out = await hkdfBits(
    ikm: dhOutput,
    salt: rootKey,
    infoStr: rootInfo,
    lenBytes: 64,
  );
  return (
    rootKey: Uint8List.fromList(out.sublist(0, 32)),
    chainKey: Uint8List.fromList(out.sublist(32, 64)),
  );
}

/// KDF_CK: advance a chain key. Message key is one-shot.
/// Mirrors doubleRatchet.js:55-58 (empty salt → 32-byte zero-salt fallback).
Future<({Uint8List chainKey, Uint8List messageKey})> kdfCk(
    List<int> chainKey) async {
  final out = await hkdfBits(
    ikm: chainKey,
    salt: const <int>[],
    infoStr: chainInfo,
    lenBytes: 64,
  );
  return (
    chainKey: Uint8List.fromList(out.sublist(0, 32)),
    messageKey: Uint8List.fromList(out.sublist(32, 64)),
  );
}

/// Generate a fresh ECDH P-256 keypair for the ratchet's DH axis.
Future<EcKeyPair> generateDhKeyPair() => _ecdh.newKeyPair();

/// Export the public half of a DH key pair as 91-byte SPKI.
Future<Uint8List> exportSpkiBytes(EcKeyPair keyPair) async {
  final pub = await keyPair.extractPublicKey();
  if (pub is! EcPublicKey) {
    throw StateError('ratchet: expected EcPublicKey, got ${pub.runtimeType}');
  }
  return buildP256Spki(x: pub.x, y: pub.y);
}

Future<Uint8List> _dhShared(EcKeyPair priv, List<int> remoteSpki) async {
  final point = parseP256Spki(remoteSpki);
  final remote = EcPublicKey(
    x: point.x,
    y: point.y,
    type: KeyPairType.p256,
  );
  final secret = await _ecdh.sharedSecretKey(
    keyPair: priv,
    remotePublicKey: remote,
  );
  return Uint8List.fromList(await secret.extractBytes());
}

bool _bytesEqual(List<int>? a, List<int>? b) {
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ─────────────────────────────────────────────────────────────
// Header / wire envelope
// ─────────────────────────────────────────────────────────────

/// JSON-encoded header then base64. Must stay byte-compatible with JS because
/// it doubles as the AES-GCM AAD — a single byte drift and decryption fails.
String encodeHeader({
  required List<int> dhPubSpki,
  required int n,
  required int pn,
}) {
  final obj = {
    'dh': bytesToBase64(Uint8List.fromList(dhPubSpki)),
    'n': n,
    'pn': pn,
  };
  return bytesToBase64(Uint8List.fromList(utf8.encode(jsonEncode(obj))));
}

/// Decoded header fields pulled off the wire.
typedef RatchetHeader = ({Uint8List dhPubSpki, int n, int pn});

RatchetHeader decodeHeader(String b64) {
  final obj = jsonDecode(utf8.decode(base64ToBytes(b64)));
  if (obj is! Map) {
    throw const FormatException('ratchet: header is not a JSON object');
  }
  final dhB64 = obj['dh'];
  if (dhB64 is! String) {
    throw const FormatException('ratchet: header.dh missing');
  }
  final dhPubSpki = base64ToBytes(dhB64);
  if (dhPubSpki.length != p256SpkiLength) {
    throw FormatException(
      'ratchet: header.dh must be 91-byte SPKI, got ${dhPubSpki.length}',
    );
  }
  final n = obj['n'] is num ? (obj['n'] as num).toInt() : 0;
  final pn = obj['pn'] is num ? (obj['pn'] as num).toInt() : 0;
  return (dhPubSpki: dhPubSpki, n: n, pn: pn);
}

/// Wire envelope — matches the JS `{ headerB64, ivB64, ctB64 }` shape.
class RatchetEnvelope {
  RatchetEnvelope({required this.headerB64, required this.ivB64, required this.ctB64});
  final String headerB64;
  final String ivB64;
  final String ctB64;
}

String encodeWire(RatchetEnvelope env) =>
    '$wireVersion:${env.headerB64}:${env.ivB64}:${env.ctB64}';

RatchetEnvelope? decodeWire(String? str) {
  final s = str ?? '';
  if (!s.startsWith('$wireVersion:')) return null;
  final parts = s.split(':');
  if (parts.length != 4) return null;
  return RatchetEnvelope(headerB64: parts[1], ivB64: parts[2], ctB64: parts[3]);
}

bool isWireCiphertext(Object? value) =>
    value is String && value.startsWith('$wireVersion:');

// ─────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────

/// Ratchet state — mirrors the JS object field-for-field. Mutable; callers
/// checkpoint by reading the fields out (the ratchet itself never persists).
class RatchetState {
  RatchetState({
    required this.rootKey,
    required this.dhKeyPair,
    required this.dhPubSpki,
    this.sendCk,
    this.recvCk,
    this.remoteDhPub,
    this.ns = 0,
    this.nr = 0,
    this.pn = 0,
    Map<String, Uint8List>? skipped,
  }) : skipped = skipped ?? <String, Uint8List>{};

  Uint8List rootKey;
  Uint8List? sendCk;
  Uint8List? recvCk;
  EcKeyPair dhKeyPair;
  Uint8List dhPubSpki;
  Uint8List? remoteDhPub;
  int ns;
  int nr;
  int pn;
  /// "<b64spki>|<n>" → 32-byte message key. Bounded by [maxSkipped].
  final Map<String, Uint8List> skipped;
}

// ─────────────────────────────────────────────────────────────
// Init (Alice / Bob)
// ─────────────────────────────────────────────────────────────

/// Alice initialises knowing Bob's initial DH public key up front, so she can
/// derive a sending chain immediately and encrypt her first message.
Future<RatchetState> ratchetInitAlice({
  required List<int> sharedSecret,
  required List<int> remoteDhPubSpki,
}) async {
  final dhKeyPair = await generateDhKeyPair();
  final dhPubSpki = await exportSpkiBytes(dhKeyPair);
  final dhOut = await _dhShared(dhKeyPair, remoteDhPubSpki);
  final rk = await kdfRk(rootKey: sharedSecret, dhOutput: dhOut);
  return RatchetState(
    rootKey: rk.rootKey,
    sendCk: rk.chainKey,
    dhKeyPair: dhKeyPair,
    dhPubSpki: dhPubSpki,
    remoteDhPub: Uint8List.fromList(remoteDhPubSpki),
  );
}

/// Bob initialises with his own DH key pair already known to Alice. His first
/// receive triggers a DH ratchet step and derives his first receive chain.
Future<RatchetState> ratchetInitBob({
  required List<int> sharedSecret,
  required EcKeyPair dhKeyPair,
  required List<int> dhPubSpki,
}) async {
  return RatchetState(
    rootKey: Uint8List.fromList(sharedSecret),
    dhKeyPair: dhKeyPair,
    dhPubSpki: Uint8List.fromList(dhPubSpki),
  );
}

// ─────────────────────────────────────────────────────────────
// DH ratchet step
// ─────────────────────────────────────────────────────────────

Future<void> _dhRatchetStep(
  RatchetState state,
  List<int> newRemoteDhPubSpki,
) async {
  final prevPn = state.ns;

  final dhRecv = await _dhShared(state.dhKeyPair, newRemoteDhPubSpki);
  final a = await kdfRk(rootKey: state.rootKey, dhOutput: dhRecv);

  final newDhKeyPair = await generateDhKeyPair();
  final newDhPubSpki = await exportSpkiBytes(newDhKeyPair);
  final dhSend = await _dhShared(newDhKeyPair, newRemoteDhPubSpki);
  final b = await kdfRk(rootKey: a.rootKey, dhOutput: dhSend);

  state.rootKey = b.rootKey;
  state.recvCk = a.chainKey;
  state.sendCk = b.chainKey;
  state.dhKeyPair = newDhKeyPair;
  state.dhPubSpki = newDhPubSpki;
  state.remoteDhPub = Uint8List.fromList(newRemoteDhPubSpki);
  state.ns = 0;
  state.nr = 0;
  state.pn = prevPn;
}

// ─────────────────────────────────────────────────────────────
// Skipped-message bookkeeping
// ─────────────────────────────────────────────────────────────

void _trimSkipped(RatchetState state) {
  while (state.skipped.length > maxSkipped) {
    final firstKey = state.skipped.keys.first;
    state.skipped.remove(firstKey);
  }
}

Future<void> _skipRecvKeys(RatchetState state, int until,
    {int maxGap = maxSkipPerStep}) async {
  if (state.recvCk == null) return;
  final gap = until - state.nr;
  if (gap < 0) {
    throw StateError('ratchet: header.n is behind Nr — possible replay');
  }
  if (gap > maxGap) {
    throw StateError('ratchet: too many skipped messages in one step');
  }
  final remoteKey =
      state.remoteDhPub != null ? bytesToBase64(state.remoteDhPub!) : '';
  var ck = state.recvCk!;
  while (state.nr < until) {
    final step = await kdfCk(ck);
    state.skipped['$remoteKey|${state.nr}'] = step.messageKey;
    ck = step.chainKey;
    state.nr += 1;
    if (state.skipped.length > maxSkipped) _trimSkipped(state);
  }
  state.recvCk = ck;
}

// ─────────────────────────────────────────────────────────────
// AES-GCM message key helpers
// ─────────────────────────────────────────────────────────────

Future<Uint8List> _aesGcmEncrypt({
  required List<int> messageKey,
  required List<int> iv,
  required List<int> plaintext,
  required List<int> aad,
}) async {
  final box = await _aes.encrypt(
    plaintext,
    secretKey: SecretKey(messageKey),
    nonce: iv,
    aad: aad,
  );
  // JS puts the 16-byte tag inside the ciphertext blob. Mirror that layout so
  // the wire format stays identical.
  final out = Uint8List(box.cipherText.length + box.mac.bytes.length)
    ..setRange(0, box.cipherText.length, box.cipherText)
    ..setRange(
      box.cipherText.length,
      box.cipherText.length + box.mac.bytes.length,
      box.mac.bytes,
    );
  return out;
}

Future<Uint8List> _aesGcmDecrypt({
  required List<int> messageKey,
  required List<int> iv,
  required List<int> ctPlusTag,
  required List<int> aad,
}) async {
  if (ctPlusTag.length < 16) {
    throw const FormatException('ratchet: ciphertext too short');
  }
  final ctLen = ctPlusTag.length - 16;
  final ct = ctPlusTag.sublist(0, ctLen);
  final mac = Mac(ctPlusTag.sublist(ctLen));
  final box = SecretBox(ct, nonce: iv, mac: mac);
  final pt = await _aes.decrypt(box, secretKey: SecretKey(messageKey), aad: aad);
  return Uint8List.fromList(pt);
}

// ─────────────────────────────────────────────────────────────
// Encrypt / decrypt
// ─────────────────────────────────────────────────────────────

/// Encrypt one message. Mutates [state] (sendCk advance, Ns bump) and returns
/// the wire envelope. Plaintext is encoded as UTF-8 if given as a String.
Future<RatchetEnvelope> ratchetEncrypt(
  RatchetState state,
  Object plaintext,
) async {
  if (state.sendCk == null) {
    throw StateError('ratchet: sendCk missing — need a DH ratchet step first');
  }
  final step = await kdfCk(state.sendCk!);
  state.sendCk = step.chainKey;
  final messageN = state.ns;
  state.ns += 1;

  final headerB64 = encodeHeader(
    dhPubSpki: state.dhPubSpki,
    n: messageN,
    pn: state.pn,
  );

  final iv = _aes.newNonce();
  final pt = plaintext is List<int>
      ? plaintext
      : utf8.encode(plaintext.toString());
  final aad = utf8.encode(headerB64);
  final ct = await _aesGcmEncrypt(
    messageKey: step.messageKey,
    iv: iv,
    plaintext: pt,
    aad: aad,
  );
  return RatchetEnvelope(
    headerB64: headerB64,
    ivB64: bytesToBase64(Uint8List.fromList(iv)),
    ctB64: bytesToBase64(ct),
  );
}

/// Decrypt one wire envelope. Mutates [state] and returns the plaintext bytes.
/// Throws on tamper, replay, or too-many-skipped.
Future<Uint8List> ratchetDecrypt(
  RatchetState state,
  RatchetEnvelope envelope,
) async {
  final header = decodeHeader(envelope.headerB64);
  final iv = base64ToBytes(envelope.ivB64);
  final ctPlusTag = base64ToBytes(envelope.ctB64);
  final aad = utf8.encode(envelope.headerB64);

  // 1. Out-of-order message from an older chain.
  final remoteKey = bytesToBase64(header.dhPubSpki);
  final skKey = '$remoteKey|${header.n}';
  final cachedMk = state.skipped.remove(skKey);
  if (cachedMk != null) {
    return _aesGcmDecrypt(
      messageKey: cachedMk,
      iv: iv,
      ctPlusTag: ctPlusTag,
      aad: aad,
    );
  }

  // 2. If the sender's DH pub changed, run a DH ratchet step. Before stepping
  //    we must capture any skipped tail of the outgoing receive chain up to
  //    header.pn so late-arrivals under the old chain still decrypt.
  if (!_bytesEqual(state.remoteDhPub, header.dhPubSpki)) {
    if (state.recvCk != null) {
      // The previous sending chain can legitimately carry more than a single
      // intra-chain step's worth of messages, so bound this catch-up by the
      // skipped-key cache size rather than the per-step limit — otherwise a
      // peer that sent >maxSkipPerStep messages before ratcheting wedges
      // decryption permanently.
      await _skipRecvKeys(state, header.pn, maxGap: maxSkipped);
    }
    await _dhRatchetStep(state, header.dhPubSpki);
  }

  // 3. Skip forward within the current receive chain up to header.n.
  await _skipRecvKeys(state, header.n);

  // 4. Derive the expected message key and advance the chain.
  if (state.recvCk == null) {
    throw StateError('ratchet: recvCk missing after DH step');
  }
  final step = await kdfCk(state.recvCk!);
  state.recvCk = step.chainKey;
  state.nr += 1;

  return _aesGcmDecrypt(
    messageKey: step.messageKey,
    iv: iv,
    ctPlusTag: ctPlusTag,
    aad: aad,
  );
}

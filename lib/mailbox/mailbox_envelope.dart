// Outer mailbox wrap. Storage sees only the sealed blob.
// AD = "orbits-mailbox-v1" || queueId. Inner ratchet ciphertext stays
// inside. A contact holding envelopeKey could label `from` as another
// contact; the inner ratchet then fails to decrypt under that session
// so nothing persists. A blocked contact still cannot get through as
// itself — drain tombstones before onPacket.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'mailbox_capability.dart';

const String kMailboxEnvelopeAdPrefix = 'orbits-mailbox-v1';
const int kMailboxEnvelopeVersion = 1;
const int kMailboxEnvelopeNonceBytes = 24;
const int kMailboxEnvelopeTagBytes = 16;

final _aead = Xchacha20.poly1305Aead().toSync();

class MailboxEnvelopeError implements Exception {
  MailboxEnvelopeError(this.message);
  final String message;
  @override
  String toString() => 'MailboxEnvelopeError: $message';
}

class MailboxOpenedEnvelope {
  const MailboxOpenedEnvelope({
    required this.fromPeerId,
    required this.deviceId,
    required this.innerCiphertext,
  });

  final String fromPeerId;
  final String deviceId;
  final List<int> innerCiphertext;
}

Uint8List mailboxEnvelopeAd(String queueId) {
  return Uint8List.fromList(utf8.encode('$kMailboxEnvelopeAdPrefix$queueId'));
}

/// `version(1) || nonce(24) || ciphertext || tag(16)`.
Uint8List sealMailboxEnvelope({
  required List<int> envelopeKey,
  required String queueId,
  required String fromPeerId,
  required String deviceId,
  required List<int> innerCiphertext,
}) {
  if (envelopeKey.length != kMailboxCapBytes) {
    throw MailboxEnvelopeError('envelopeKey length');
  }
  if (!mailboxCapStringIsSafe(queueId)) {
    throw MailboxEnvelopeError('unsafe queueId');
  }
  if (fromPeerId.contains('://') || deviceId.contains('://')) {
    throw MailboxEnvelopeError('unsafe identity field');
  }
  final body = utf8.encode(
    jsonEncode(<String, Object?>{
      'v': kMailboxEnvelopeVersion,
      'from': fromPeerId,
      'deviceId': deviceId,
      'envelope': base64Encode(innerCiphertext),
    }),
  );
  final nonce = Uint8List(kMailboxEnvelopeNonceBytes);
  final rng = Random.secure();
  for (var i = 0; i < nonce.length; i++) {
    nonce[i] = rng.nextInt(256);
  }
  final secret = SecretKeyData(envelopeKey);
  final box = _aead.encryptSync(
    body,
    secretKey: secret,
    nonce: nonce,
    aad: mailboxEnvelopeAd(queueId),
  );
  final out = BytesBuilder(copy: false);
  out.addByte(kMailboxEnvelopeVersion);
  out.add(nonce);
  out.add(box.cipherText);
  out.add(box.mac.bytes);
  return out.toBytes();
}

MailboxOpenedEnvelope openMailboxEnvelope({
  required List<int> envelopeKey,
  required String queueId,
  required List<int> sealed,
}) {
  if (envelopeKey.length != kMailboxCapBytes) {
    throw MailboxEnvelopeError('envelopeKey length');
  }
  if (sealed.length <
      1 + kMailboxEnvelopeNonceBytes + kMailboxEnvelopeTagBytes) {
    throw MailboxEnvelopeError('short envelope');
  }
  if (sealed[0] != kMailboxEnvelopeVersion) {
    throw MailboxEnvelopeError('version');
  }
  final nonce = sealed.sublist(1, 1 + kMailboxEnvelopeNonceBytes);
  final rest = sealed.sublist(1 + kMailboxEnvelopeNonceBytes);
  if (rest.length < kMailboxEnvelopeTagBytes) {
    throw MailboxEnvelopeError('short tag');
  }
  final ct = rest.sublist(0, rest.length - kMailboxEnvelopeTagBytes);
  final tag = rest.sublist(rest.length - kMailboxEnvelopeTagBytes);
  final secret = SecretKeyData(envelopeKey);
  final List<int> clear;
  try {
    clear = _aead.decryptSync(
      SecretBox(ct, nonce: nonce, mac: Mac(tag)),
      secretKey: secret,
      aad: mailboxEnvelopeAd(queueId),
    );
  } catch (err) {
    throw MailboxEnvelopeError('auth $err');
  }
  final decoded = jsonDecode(utf8.decode(clear));
  if (decoded is! Map) throw MailboxEnvelopeError('payload');
  final from = decoded['from'] as String? ?? '';
  final deviceId = decoded['deviceId'] as String? ?? '';
  final env = decoded['envelope'] as String? ?? '';
  if (from.isEmpty || from.contains('://') || deviceId.contains('://')) {
    throw MailboxEnvelopeError('identity');
  }
  return MailboxOpenedEnvelope(
    fromPeerId: from,
    deviceId: deviceId,
    innerCiphertext: base64Decode(env),
  );
}

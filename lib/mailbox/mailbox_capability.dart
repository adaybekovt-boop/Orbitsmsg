// Recipient mailbox capabilities. Storage sees only queueId and
// sha256(cap) hashes — never peerId, envelopeKey, or plaintext.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';

const int kMailboxSecretBytes = 32;
const int kMailboxCapBytes = 32;
const int kMailboxMaxTtlMs = 30 * 24 * 3600 * 1000;
const String kMailboxQueueInfo = 'orbits-mailbox-queue-v1';
const String kMailboxReadInfo = 'orbits-mailbox-read-v1';
const String kMailboxDepositInfo = 'orbits-mailbox-deposit-v1';
const String kMailboxEnvelopeInfo = 'orbits-mailbox-envelope-v1';
const String kMailboxGrantWireType = 'mailboxGrant';

final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: kMailboxCapBytes);

List<int> generateMailboxRootSecret() {
  final rng = Random.secure();
  return List<int>.generate(kMailboxSecretBytes, (_) => rng.nextInt(256));
}

String mailboxBytesToHex(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

List<int>? mailboxHexToBytes(String hex) {
  if (hex.isEmpty || hex.length.isOdd || hex.contains('://')) return null;
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}

bool mailboxConstantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var mismatch = 0;
  for (var i = 0; i < a.length; i++) {
    mismatch |= a[i] ^ b[i];
  }
  return mismatch == 0;
}

List<int> mailboxSha256(List<int> bytes) => sha256.convert(bytes).bytes;

String sha256HexOf(List<int> bytes) => mailboxBytesToHex(mailboxSha256(bytes));

String bytesToMailboxHex(List<int> bytes) => mailboxBytesToHex(bytes);

bool constantTimeEqualsHex(String a, String b) {
  final left = mailboxHexToBytes(a.toLowerCase());
  final right = mailboxHexToBytes(b.toLowerCase());
  if (left == null || right == null) return false;
  return mailboxConstantTimeEquals(left, right);
}

const String kMailboxAdminHeader = 'X-Orbits-Admin-Token';

/// Opaque hex / capability string. Never a URL or a secret-field name.
bool mailboxCapStringIsSafe(String value) {
  if (value.isEmpty) return false;
  if (value.contains('://')) return false;
  if (value.contains('peerId')) return false;
  if (value.contains('fileKey')) return false;
  if (value.contains('rootKey')) return false;
  if (value.contains('discoverySecret')) return false;
  if (value.contains('writerKey')) return false;
  return true;
}

class DerivedMailboxCaps {
  const DerivedMailboxCaps({
    required this.queueId,
    required this.readCap,
    required this.depositCap,
    required this.envelopeKey,
  });

  /// Storage-visible address. Hex of 32 HKDF bytes — not a peer id.
  final String queueId;
  final List<int> readCap;
  final List<int> depositCap;
  final List<int> envelopeKey;

  List<int> get readCapHash => mailboxSha256(readCap);
  List<int> get depositCapHash => mailboxSha256(depositCap);

  String get readCapHashHex => mailboxBytesToHex(readCapHash);
  String get depositCapHashHex => mailboxBytesToHex(depositCapHash);
}

Future<List<int>> _hkdf32(List<int> root, String info) async {
  final derived = await _hkdf.deriveKey(
    secretKey: SecretKey(root),
    nonce: Uint8List(0),
    info: utf8.encode(info),
  );
  return List<int>.from(await derived.extractBytes());
}

Future<DerivedMailboxCaps> deriveMailboxCaps(List<int> rootSecret) async {
  if (rootSecret.length != kMailboxSecretBytes) {
    throw ArgumentError('mailbox root must be $kMailboxSecretBytes bytes');
  }
  final queue = await _hkdf32(rootSecret, kMailboxQueueInfo);
  final read = await _hkdf32(rootSecret, kMailboxReadInfo);
  final deposit = await _hkdf32(rootSecret, kMailboxDepositInfo);
  final envelope = await _hkdf32(rootSecret, kMailboxEnvelopeInfo);
  return DerivedMailboxCaps(
    queueId: mailboxBytesToHex(queue),
    readCap: read,
    depositCap: deposit,
    envelopeKey: envelope,
  );
}

/// Storage-visible queue registration. Hex hashes only — no raw caps.
class MailboxCapability {
  const MailboxCapability({
    required this.queueId,
    required this.readCapHash,
    required this.depositCapHash,
    required this.quotaBytes,
    required this.retentionMs,
    required this.expiresAt,
  });

  final String queueId;
  final String readCapHash;
  final String depositCapHash;
  final int quotaBytes;
  final int retentionMs;
  final int expiresAt;

  bool isExpiredAt(int nowMs) => nowMs >= expiresAt;
}

class MailboxGrant {
  const MailboxGrant({
    required this.queueId,
    required this.depositCap,
    required this.envelopeKey,
    this.storagePeerHint,
  });

  final String queueId;
  final List<int> depositCap;
  final List<int> envelopeKey;
  final String? storagePeerHint;

  Map<String, Object?> toWire() => <String, Object?>{
    'type': kMailboxGrantWireType,
    'queueId': queueId,
    'depositCap': mailboxBytesToHex(depositCap),
    'envelopeKey': mailboxBytesToHex(envelopeKey),
    if (storagePeerHint != null && storagePeerHint!.isNotEmpty)
      'storagePeerHint': storagePeerHint,
  };

  static MailboxGrant? fromWire(Map<String, Object?> packet) {
    if (packet['type'] != kMailboxGrantWireType) return null;
    final queueId = packet['queueId'] as String? ?? '';
    final deposit = mailboxHexToBytes(packet['depositCap'] as String? ?? '');
    final envelope = mailboxHexToBytes(packet['envelopeKey'] as String? ?? '');
    final hint = packet['storagePeerHint'] as String?;
    if (!mailboxCapStringIsSafe(queueId) ||
        deposit == null ||
        deposit.length != kMailboxCapBytes ||
        envelope == null ||
        envelope.length != kMailboxCapBytes) {
      return null;
    }
    if (hint != null &&
        (hint.contains('://') || !mailboxCapStringIsSafe(hint))) {
      return null;
    }
    return MailboxGrant(
      queueId: queueId,
      depositCap: deposit,
      envelopeKey: envelope,
      storagePeerHint: hint,
    );
  }
}

// Versioned blind-mailbox HTTP schema. Storage peers see ciphertext
// only. Authorization is a mailbox-scoped HMAC capability — not the
// identity key, not the Hyperswarm Noise key, and not a raw peer ID.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../transport/layers.dart';

const String kMailboxHttpVersion = 'orbits-mailbox-http-v1';
const String kMailboxCapabilityInfo = 'orbits-mailbox-cap-v1';
const int kOpaqueEnvelopeVersion = 1;
const int kOpaqueEnvelopeAlgRatchetV2 = 1;
const List<int> kOpaqueEnvelopeMagic = <int>[0x4F, 0x45, 0x31, 0x01];
const int kOpaqueEnvelopeHeaderBytes = 4 + 1 + 32 + 4;
const String kMailboxTombstoneInfo = 'orbits-mailbox-tombstone-v1';
const List<int> kMailboxTombstoneMagic = <int>[0x4F, 0x54, 0x31, 0x01];
const int kMailboxTombstoneVersion = 1;

/// Chat-sized envelope cap. Attachments use the Phase 9 path/descriptor
/// pipeline and must not be copied through this HTTP body.
const int kMailboxMaxBodyBytes = 12 * 1024 * 1024;
const int kMailboxMaxEnvelopeBytes = 12 * 1024 * 1024;
const int kMailboxMaxRequestIdLength = 128;
const int kMailboxMaxEnvelopeIdLength = 128;
const int kMailboxClockSkewMs = 5 * 60 * 1000;
const int kMailboxReplayTtlMs = 30 * 60 * 1000;

const Set<String> kMailboxForbiddenKeys = {
  ...kForbiddenReplicationFields,
  'text',
  'body',
  'peerId',
};

const Set<String> kMailboxRequestKeys = {
  'v',
  'op',
  'requestId',
  'issuedAt',
  'capability',
  'mailboxId',
  'envelopeId',
  'ciphertextB64',
  'fromSeq',
};

const Set<String> kMailboxCapabilityKeys = {
  'v',
  'tokenId',
  'mailboxId',
  'scopes',
  'issuedAt',
  'notBefore',
  'expiresAt',
  'quotaBytes',
  'retentionMs',
  'mac',
};

enum MailboxScope {
  deposit,
  drain,
  ack,
  delete;

  static MailboxScope? fromName(String name) {
    for (final value in MailboxScope.values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

enum MailboxOp {
  deposit,
  drain,
  ack,
  delete;

  static MailboxOp? fromName(String name) {
    for (final value in MailboxOp.values) {
      if (value.name == name) return value;
    }
    return null;
  }

  MailboxScope get requiredScope {
    switch (this) {
      case MailboxOp.deposit:
        return MailboxScope.deposit;
      case MailboxOp.drain:
        return MailboxScope.drain;
      case MailboxOp.ack:
        return MailboxScope.ack;
      case MailboxOp.delete:
        return MailboxScope.delete;
    }
  }
}

class MailboxProtocolException implements Exception {
  MailboxProtocolException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'MailboxProtocolException($code)';
}

/// Self-contained HMAC capability. The MAC key is the storage peer's
/// grant secret — never an identity or Noise scalar.
class SignedMailboxCapability {
  const SignedMailboxCapability({
    required this.tokenId,
    required this.mailboxId,
    required this.scopes,
    required this.issuedAt,
    required this.notBefore,
    required this.expiresAt,
    required this.quotaBytes,
    required this.retentionMs,
    required this.mac,
  });

  final String tokenId;
  final String mailboxId;
  final Set<MailboxScope> scopes;
  final int issuedAt;
  final int notBefore;
  final int expiresAt;
  final int quotaBytes;
  final int retentionMs;
  final Uint8List mac;

  List<int> canonicalPayload() {
    final scopeNames = scopes.map((s) => s.name).toList()..sort();
    return utf8.encode(
      [
        kMailboxCapabilityInfo,
        tokenId,
        mailboxId,
        scopeNames.join(','),
        issuedAt.toString(),
        notBefore.toString(),
        expiresAt.toString(),
        quotaBytes.toString(),
        retentionMs.toString(),
      ].join('\n'),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': kMailboxCapabilityInfo,
    'tokenId': tokenId,
    'mailboxId': mailboxId,
    'scopes': (scopes.map((s) => s.name).toList()..sort()),
    'issuedAt': issuedAt,
    'notBefore': notBefore,
    'expiresAt': expiresAt,
    'quotaBytes': quotaBytes,
    'retentionMs': retentionMs,
    'mac': base64Encode(mac),
  };

  static SignedMailboxCapability parse(Object? raw) {
    if (raw is! Map) {
      throw MailboxProtocolException(
        'malformed',
        'capability is not an object',
      );
    }
    final json = Map<String, Object?>.from(raw);
    _rejectForbiddenDeep(json);
    _rejectUnknownKeys(json.keys, kMailboxCapabilityKeys, 'capability');
    if (json['v'] != kMailboxCapabilityInfo) {
      throw MailboxProtocolException(
        'malformed',
        'unsupported capability version',
      );
    }
    final tokenId = json['tokenId'];
    final mailboxId = json['mailboxId'];
    if (tokenId is! String || tokenId.isEmpty) {
      throw MailboxProtocolException(
        'anonymous',
        'capability token is required',
      );
    }
    if (mailboxId is! String || mailboxId.isEmpty) {
      throw MailboxProtocolException('malformed', 'mailbox id is required');
    }
    final scopes = <MailboxScope>{};
    final listed = json['scopes'];
    if (listed is! List || listed.isEmpty) {
      throw MailboxProtocolException('malformed', 'scopes are required');
    }
    for (final item in listed) {
      if (item is! String) {
        throw MailboxProtocolException('malformed', 'scope type');
      }
      final scope = MailboxScope.fromName(item);
      if (scope == null) {
        throw MailboxProtocolException('malformed', 'unknown scope');
      }
      scopes.add(scope);
    }
    final macB64 = json['mac'];
    if (macB64 is! String || macB64.isEmpty) {
      throw MailboxProtocolException('invalid-mac', 'capability mac missing');
    }
    return SignedMailboxCapability(
      tokenId: tokenId,
      mailboxId: mailboxId,
      scopes: scopes,
      issuedAt: _requireInt(json, 'issuedAt'),
      notBefore: _requireInt(json, 'notBefore'),
      expiresAt: _requireInt(json, 'expiresAt'),
      quotaBytes: _requireInt(json, 'quotaBytes'),
      retentionMs: _requireInt(json, 'retentionMs'),
      mac: _decodeB64(macB64, 'mac'),
    );
  }
}

class MailboxHttpRequest {
  const MailboxHttpRequest({
    required this.op,
    required this.requestId,
    required this.issuedAt,
    required this.capability,
    this.mailboxId,
    this.envelopeId,
    this.ciphertext,
    this.fromSeq = 0,
  });

  final MailboxOp op;
  final String requestId;
  final int issuedAt;
  final SignedMailboxCapability capability;
  final String? mailboxId;
  final String? envelopeId;
  final Uint8List? ciphertext;
  final int fromSeq;

  String get effectiveMailboxId => mailboxId ?? capability.mailboxId;

  Map<String, Object?> toJson() => <String, Object?>{
    'v': kMailboxHttpVersion,
    'op': op.name,
    'requestId': requestId,
    'issuedAt': issuedAt,
    'capability': capability.toJson(),
    if (mailboxId != null) 'mailboxId': mailboxId,
    if (envelopeId != null) 'envelopeId': envelopeId,
    if (ciphertext != null) 'ciphertextB64': base64Encode(ciphertext!),
    if (op == MailboxOp.drain) 'fromSeq': fromSeq,
  };

  static MailboxHttpRequest parse(Object? raw, {required int bodyBytes}) {
    if (bodyBytes > kMailboxMaxBodyBytes) {
      throw MailboxProtocolException('oversized', 'request body exceeds cap');
    }
    if (raw is! Map) {
      throw MailboxProtocolException('malformed', 'request is not an object');
    }
    final json = Map<String, Object?>.from(raw);
    _rejectForbiddenDeep(json);
    _rejectUnknownKeys(json.keys, kMailboxRequestKeys, 'request');
    if (json['v'] != kMailboxHttpVersion) {
      throw MailboxProtocolException(
        'malformed',
        'unsupported request version',
      );
    }
    final opName = json['op'];
    if (opName is! String) {
      throw MailboxProtocolException('malformed', 'op is required');
    }
    final op = MailboxOp.fromName(opName);
    if (op == null) {
      throw MailboxProtocolException('malformed', 'unknown op');
    }
    final requestId = json['requestId'];
    if (requestId is! String ||
        requestId.isEmpty ||
        requestId.length > kMailboxMaxRequestIdLength) {
      throw MailboxProtocolException('malformed', 'requestId is invalid');
    }
    final capability = SignedMailboxCapability.parse(json['capability']);
    String? envelopeId;
    final rawEnvelopeId = json['envelopeId'];
    if (rawEnvelopeId != null) {
      if (rawEnvelopeId is! String ||
          rawEnvelopeId.isEmpty ||
          rawEnvelopeId.length > kMailboxMaxEnvelopeIdLength) {
        throw MailboxProtocolException('malformed', 'envelopeId is invalid');
      }
      envelopeId = rawEnvelopeId;
    }
    Uint8List? ciphertext;
    final rawCt = json['ciphertextB64'];
    if (rawCt != null) {
      if (rawCt is! String) {
        throw MailboxProtocolException('malformed', 'ciphertext type');
      }
      ciphertext = _decodeB64(rawCt, 'ciphertextB64');
      if (ciphertext.length > kMailboxMaxEnvelopeBytes) {
        throw MailboxProtocolException('oversized', 'envelope exceeds cap');
      }
      rejectPlaintextEnvelope(ciphertext);
    }
    if (op == MailboxOp.deposit) {
      if (envelopeId == null) {
        throw MailboxProtocolException('malformed', 'deposit needs envelopeId');
      }
      if (ciphertext == null || ciphertext.isEmpty) {
        throw MailboxProtocolException('malformed', 'deposit needs ciphertext');
      }
    }
    if ((op == MailboxOp.ack || op == MailboxOp.delete) && envelopeId == null) {
      throw MailboxProtocolException(
        'malformed',
        '${op.name} needs envelopeId',
      );
    }
    final mailboxId = json['mailboxId'];
    if (mailboxId != null && mailboxId is! String) {
      throw MailboxProtocolException('malformed', 'mailboxId type');
    }
    return MailboxHttpRequest(
      op: op,
      requestId: requestId,
      issuedAt: _requireInt(json, 'issuedAt'),
      capability: capability,
      mailboxId: mailboxId as String?,
      envelopeId: envelopeId,
      ciphertext: ciphertext,
      fromSeq: json.containsKey('fromSeq') ? _requireInt(json, 'fromSeq') : 0,
    );
  }
}

class MailboxHttpResponse {
  const MailboxHttpResponse({
    required this.ok,
    this.error,
    this.duplicate = false,
    this.envelopes = const <Map<String, Object?>>[],
  });

  final bool ok;
  final String? error;
  final bool duplicate;
  final List<Map<String, Object?>> envelopes;

  Map<String, Object?> toJson() => <String, Object?>{
    'v': kMailboxHttpVersion,
    'ok': ok,
    if (error != null) 'error': error,
    if (duplicate) 'duplicate': true,
    if (envelopes.isNotEmpty) 'envelopes': envelopes,
  };
}

SignedMailboxCapability issueMailboxCapability({
  required List<int> grantSecret,
  required String tokenId,
  required String mailboxId,
  required Set<MailboxScope> scopes,
  required int issuedAt,
  required int notBefore,
  required int expiresAt,
  required int quotaBytes,
  required int retentionMs,
}) {
  if (tokenId.isEmpty) {
    throw MailboxProtocolException(
      'anonymous',
      'anonymous writes are rejected',
    );
  }
  if (mailboxId.isEmpty) {
    throw MailboxProtocolException('malformed', 'mailbox id is required');
  }
  if (grantSecret.length < 16) {
    throw MailboxProtocolException('invalid-mac', 'grant secret is too short');
  }
  final draft = SignedMailboxCapability(
    tokenId: tokenId,
    mailboxId: mailboxId,
    scopes: scopes,
    issuedAt: issuedAt,
    notBefore: notBefore,
    expiresAt: expiresAt,
    quotaBytes: quotaBytes,
    retentionMs: retentionMs,
    mac: Uint8List(0),
  );
  return SignedMailboxCapability(
    tokenId: tokenId,
    mailboxId: mailboxId,
    scopes: scopes,
    issuedAt: issuedAt,
    notBefore: notBefore,
    expiresAt: expiresAt,
    quotaBytes: quotaBytes,
    retentionMs: retentionMs,
    mac: hmacSha256(grantSecret, draft.canonicalPayload()),
  );
}

void verifyMailboxCapability(
  SignedMailboxCapability capability, {
  required List<int> grantSecret,
  required MailboxScope scope,
  required String mailboxId,
  required int nowMs,
}) {
  final expected = hmacSha256(grantSecret, capability.canonicalPayload());
  if (!_constantTimeEquals(expected, capability.mac)) {
    throw MailboxProtocolException('invalid-mac', 'capability mac mismatch');
  }
  if (!capability.scopes.contains(scope)) {
    throw MailboxProtocolException('unauthorized', 'scope is not granted');
  }
  if (capability.mailboxId != mailboxId) {
    throw MailboxProtocolException(
      'wrong-recipient',
      'capability mailbox mismatch',
    );
  }
  if (capability.issuedAt > nowMs + kMailboxClockSkewMs) {
    throw MailboxProtocolException(
      'not-yet-valid',
      'capability issued in the future',
    );
  }
  if (nowMs + kMailboxClockSkewMs < capability.notBefore) {
    throw MailboxProtocolException(
      'not-yet-valid',
      'capability is not yet valid',
    );
  }
  if (nowMs > capability.expiresAt) {
    throw MailboxProtocolException('expired', 'capability has expired');
  }
  if (capability.expiresAt <= capability.issuedAt) {
    throw MailboxProtocolException(
      'malformed',
      'capability expiry precedes issue',
    );
  }
}

void verifyMailboxRequest(
  MailboxHttpRequest request, {
  required List<int> grantSecret,
  required int nowMs,
}) {
  if (request.issuedAt > nowMs + kMailboxClockSkewMs) {
    throw MailboxProtocolException(
      'not-yet-valid',
      'request issued in the future',
    );
  }
  if (request.issuedAt + kMailboxReplayTtlMs < nowMs) {
    throw MailboxProtocolException('expired', 'request is too old');
  }
  verifyMailboxCapability(
    request.capability,
    grantSecret: grantSecret,
    scope: request.op.requiredScope,
    mailboxId: request.effectiveMailboxId,
    nowMs: nowMs,
  );
}

Uint8List wrapOpaqueEnvelope(
  List<int> ciphertext, {
  int alg = kOpaqueEnvelopeAlgRatchetV2,
}) {
  if (ciphertext.isEmpty) {
    throw MailboxProtocolException('plaintext', 'empty envelope');
  }
  final digest = sha256.convert(ciphertext).bytes;
  final out = BytesBuilder(copy: false);
  out.add(kOpaqueEnvelopeMagic);
  out.addByte(alg);
  out.add(digest);
  final len = ByteData(4)..setUint32(0, ciphertext.length);
  out.add(len.buffer.asUint8List());
  out.add(ciphertext);
  return out.toBytes();
}

Uint8List requireOpaqueEnvelope(List<int> bytes) {
  if (bytes.length < kOpaqueEnvelopeHeaderBytes) {
    throw MailboxProtocolException('plaintext', 'envelope frame too short');
  }
  for (var i = 0; i < kOpaqueEnvelopeMagic.length; i++) {
    if (bytes[i] != kOpaqueEnvelopeMagic[i]) {
      throw MailboxProtocolException('plaintext', 'envelope magic mismatch');
    }
  }
  final alg = bytes[4];
  if (alg != kOpaqueEnvelopeAlgRatchetV2) {
    throw MailboxProtocolException('malformed', 'unsupported envelope alg');
  }
  final declared = ByteData.sublistView(
    Uint8List.fromList(bytes.sublist(37, 41)),
  ).getUint32(0);
  final ciphertext = bytes.sublist(41);
  if (ciphertext.length != declared) {
    throw MailboxProtocolException('malformed', 'envelope length mismatch');
  }
  final actual = sha256.convert(ciphertext).bytes;
  final expected = bytes.sublist(5, 37);
  var diff = 0;
  for (var i = 0; i < 32; i++) {
    diff |= actual[i] ^ expected[i];
  }
  if (diff != 0) {
    throw MailboxProtocolException('malformed', 'envelope hash mismatch');
  }
  return Uint8List.fromList(ciphertext);
}

void rejectPlaintextEnvelope(List<int> bytes) {
  requireOpaqueEnvelope(bytes);
}

class MailboxTombstone {
  const MailboxTombstone({
    required this.id,
    required this.deletedAt,
    this.version = kMailboxTombstoneVersion,
  });

  final String id;
  final int deletedAt;
  final int version;
}

bool isMailboxTombstone(List<int> bytes) {
  if (bytes.length < kMailboxTombstoneMagic.length) return false;
  for (var i = 0; i < kMailboxTombstoneMagic.length; i++) {
    if (bytes[i] != kMailboxTombstoneMagic[i]) return false;
  }
  return true;
}

Uint8List encodeMailboxTombstone({
  required String id,
  required int deletedAt,
  int version = kMailboxTombstoneVersion,
}) {
  if (id.isEmpty) {
    throw MailboxProtocolException('malformed', 'tombstone id required');
  }
  final body = utf8.encode(
    jsonEncode(<String, Object?>{
      'v': kMailboxTombstoneInfo,
      'id': id,
      'deleted': true,
      'deletedAt': deletedAt,
      'version': version,
    }),
  );
  final digest = sha256.convert(body).bytes;
  final out = BytesBuilder(copy: false);
  out.add(kMailboxTombstoneMagic);
  out.add(digest);
  out.add(body);
  return out.toBytes();
}

MailboxTombstone requireMailboxTombstone(List<int> bytes) {
  if (!isMailboxTombstone(bytes)) {
    throw MailboxProtocolException('malformed', 'not a mailbox tombstone');
  }
  if (bytes.length < kMailboxTombstoneMagic.length + 32) {
    throw MailboxProtocolException('malformed', 'tombstone too short');
  }
  final expected = bytes.sublist(
    kMailboxTombstoneMagic.length,
    kMailboxTombstoneMagic.length + 32,
  );
  final body = bytes.sublist(kMailboxTombstoneMagic.length + 32);
  if (body.isEmpty) {
    throw MailboxProtocolException('malformed', 'tombstone body empty');
  }
  final actual = sha256.convert(body).bytes;
  var diff = 0;
  for (var i = 0; i < 32; i++) {
    diff |= actual[i] ^ expected[i];
  }
  if (diff != 0) {
    throw MailboxProtocolException('malformed', 'tombstone hash mismatch');
  }
  late final Object decoded;
  try {
    decoded = jsonDecode(utf8.decode(body));
  } catch (_) {
    throw MailboxProtocolException('malformed', 'tombstone json');
  }
  if (decoded is! Map) {
    throw MailboxProtocolException('malformed', 'tombstone not an object');
  }
  final json = Map<String, Object?>.from(decoded);
  if (json['v'] != kMailboxTombstoneInfo || json['deleted'] != true) {
    throw MailboxProtocolException('malformed', 'tombstone marker missing');
  }
  final id = json['id'] as String? ?? '';
  if (id.isEmpty) {
    throw MailboxProtocolException('malformed', 'tombstone id required');
  }
  return MailboxTombstone(
    id: id,
    deletedAt: _requireInt(json, 'deletedAt'),
    version: json['version'] is int
        ? json['version'] as int
        : kMailboxTombstoneVersion,
  );
}

bool mailboxBodyKeysAreSafe(Iterable<Object?> keys) {
  for (final key in keys) {
    if (key is String && kMailboxForbiddenKeys.contains(key)) return false;
  }
  return true;
}

Uint8List hmacSha256(List<int> key, List<int> data) {
  return Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);
}

void _rejectForbiddenKeys(Iterable<Object?> keys) {
  for (final key in keys) {
    if (key is String && kMailboxForbiddenKeys.contains(key)) {
      throw MailboxProtocolException('plaintext', 'forbidden field');
    }
  }
}

int _requireInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw MailboxProtocolException('malformed', '$key must be an integer');
}

Uint8List _decodeB64(String value, String field) {
  if (value.contains(RegExp(r'\s'))) {
    throw MailboxProtocolException('malformed', '$field is not valid base64');
  }
  try {
    final bytes = base64Decode(value);
    if (base64Encode(bytes) != value) {
      throw MailboxProtocolException(
        'malformed',
        '$field is not canonical base64',
      );
    }
    return Uint8List.fromList(bytes);
  } on MailboxProtocolException {
    rethrow;
  } catch (_) {
    throw MailboxProtocolException('malformed', '$field is not valid base64');
  }
}

void _rejectUnknownKeys(
  Iterable<Object?> keys,
  Set<String> allowed,
  String where,
) {
  for (final key in keys) {
    if (key is String && !allowed.contains(key)) {
      throw MailboxProtocolException(
        'malformed',
        'unknown field in $where: $key',
      );
    }
  }
}

void _rejectForbiddenDeep(Object? value, {int depth = 0}) {
  if (depth > 8) {
    throw MailboxProtocolException('malformed', 'nested object is too deep');
  }
  if (value is Map) {
    _rejectForbiddenKeys(value.keys);
    for (final entry in value.entries) {
      if (entry.key == 'ciphertextB64' || entry.key == 'mac') continue;
      _rejectForbiddenDeep(entry.value, depth: depth + 1);
    }
  } else if (value is List) {
    for (final item in value) {
      _rejectForbiddenDeep(item, depth: depth + 1);
    }
  }
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

// Versioned blind-mailbox HTTP schema. Storage peers see ciphertext
// only. Authorization is a mailbox-scoped HMAC capability — not the
// identity key, not the Hyperswarm Noise key, and not a raw peer ID.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../transport/layers.dart';

const String kMailboxHttpVersion = 'orbits-mailbox-http-v1';
const String kMailboxCapabilityInfo = 'orbits-mailbox-cap-v1';

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
    _rejectForbiddenKeys(json.keys);
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
    _rejectForbiddenKeys(json.keys);
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

void rejectPlaintextEnvelope(List<int> bytes) {
  if (bytes.isEmpty) {
    throw MailboxProtocolException('plaintext', 'empty envelope');
  }
  try {
    final text = utf8.decode(bytes);
    if (text.startsWith('v2:')) return;
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      _rejectForbiddenKeys(decoded.keys.map((k) => k.toString()));
    }
  } on MailboxProtocolException {
    rethrow;
  } catch (_) {
    // Non-JSON opaque bytes are acceptable ciphertext.
  }
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
  try {
    return Uint8List.fromList(base64Decode(value));
  } catch (_) {
    throw MailboxProtocolException('malformed', '$field is not valid base64');
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

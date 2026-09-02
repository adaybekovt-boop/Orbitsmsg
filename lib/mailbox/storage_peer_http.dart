// Local HTTP blind storage peer. Capability hashes + sealed blobs.
// Not a public fleet — use this for desktop mailbox / CI.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../transport/fleet_status.dart';
import 'blind_store.dart';
import 'mailbox_capability.dart';
import 'storage_peer_client.dart';

class StoragePeerHttp {
  StoragePeerHttp(
    this.store, {
    this.maxBodyBytes = kMailboxHttpMaxBodyBytes,
    this.rateLimit = kMailboxHttpRateLimit,
    this.rateWindowMs = kMailboxHttpRateWindowMs,
    this.adminToken,
  });

  final BlindMailboxStore store;
  final int maxBodyBytes;
  final int rateLimit;
  final int rateWindowMs;
  final String? adminToken;
  HttpServer? _server;
  final Map<String, _MailboxRateWindow> _rate = <String, _MailboxRateWindow>{};

  int get port => _server?.port ?? 0;
  String get origin => 'http://127.0.0.1:$port';

  bool _adminOk(HttpRequest req) {
    final expected = adminToken;
    if (expected == null || expected.isEmpty) return false;
    final got = req.headers.value(kMailboxAdminHeader) ??
        req.headers.value(kMailboxAdminHeader.toLowerCase()) ??
        '';
    return got.isNotEmpty &&
        mailboxConstantTimeEquals(utf8.encode(got), utf8.encode(expected));
  }

  Future<void> start({int port = 0}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_onRequest);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  int _statusFor(Object error) {
    final text = '$error';
    if (text.contains('rate limited')) return 429;
    if (text.contains('replay')) return 409;
    if (text.contains('too large')) return 413;
    if (text.contains('rejected') ||
        text.contains('expired') ||
        text.contains('admin') ||
        text.contains('readCap') ||
        text.contains('unknown mailbox')) {
      return 403;
    }
    return 400;
  }

  Future<void> _onRequest(HttpRequest req) async {
    try {
      if (req.method == 'GET' && req.uri.path == '/health') {
        _json(req, {'ok': true, 'role': 'storage', 'plaintext': false});
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/v1/grant') {
        final map = await _readJson(req);
        if (!storagePeerGrantIsSafe(map)) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        final readCapHex = map['readCap'] as String?;
        store.grant(
          queueId: (map['queueId'] as String).toLowerCase(),
          readCapHash: (map['readCapHash'] as String).toLowerCase(),
          depositCapHash: (map['depositCapHash'] as String).toLowerCase(),
          quotaBytes: (map['quotaBytes'] as num?)?.toInt(),
          retentionMs: (map['retentionMs'] as num?)?.toInt(),
          expiresAt: (map['expiresAt'] as num?)?.toInt(),
          readCap: readCapHex == null ? null : mailboxHexToBytes(readCapHex),
          adminOk: _adminOk(req),
        );
        _json(req, {'ok': true});
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/v1/blocks') {
        final map = await _readJson(req);
        if (!storagePeerBodyIsSafe(map)) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        final queueId = (map['queueId'] as String).toLowerCase();
        if (!_rateOk(queueId) || !_rateOk(map['depositCap'] as String)) {
          req.response.statusCode = 429;
          await req.response.close();
          return;
        }
        final block = Map<String, Object?>.from(map['block'] as Map);
        final bytes = base64Decode(
          (block['bytes'] as String?) ?? (block['b64'] as String?) ?? '',
        );
        final stored = store.put(
          queueId: queueId,
          depositCap: mailboxHexToBytes(map['depositCap'] as String) ??
              const <int>[],
          bytes: Uint8List.fromList(bytes),
          blockHash: (block['blockHash'] as String).toLowerCase(),
        );
        _json(req, {'ok': true, 'seq': stored.seq});
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/v1/tombstone') {
        final map = await _readJson(req);
        if (!storagePeerKeysAreSafe(map) ||
            map.containsKey('token') ||
            map.containsKey('writerKey')) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        final queueId = map['queueId'] as String? ?? '';
        final readCap = map['readCap'] as String? ?? '';
        final seq = (map['seq'] as num?)?.toInt();
        if (!storagePeerReadQueryIsSafe(queueId: queueId, readCap: readCap) ||
            seq == null) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        store.tombstone(
          queueId: queueId.toLowerCase(),
          readCap: mailboxHexToBytes(readCap) ?? const <int>[],
          seq: seq,
        );
        _json(req, {'ok': true});
        return;
      }
      if (req.method == 'GET' && req.uri.path == '/v1/stats') {
        final queueId = req.uri.queryParameters['queueId'] ?? '';
        final readCap = req.uri.queryParameters['readCap'] ?? '';
        if (!storagePeerReadQueryIsSafe(queueId: queueId, readCap: readCap)) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        final raw = store.stats(
          queueId: queueId.toLowerCase(),
          readCap: mailboxHexToBytes(readCap) ?? const <int>[],
        );
        _json(req, {
          ...raw,
          'usedBytes': raw['bytes'],
          'pendingCount': raw['blocks'],
        });
        return;
      }
      if (req.method == 'GET' && req.uri.path == '/v1/blocks') {
        final queueId = req.uri.queryParameters['queueId'] ?? '';
        final readCap = req.uri.queryParameters['readCap'] ?? '';
        final from =
            int.tryParse(req.uri.queryParameters['fromSeq'] ?? '') ?? 0;
        if (!storagePeerReadQueryIsSafe(queueId: queueId, readCap: readCap)) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        final blocks = store.get(
          queueId: queueId.toLowerCase(),
          readCap: mailboxHexToBytes(readCap) ?? const <int>[],
          fromSeq: from,
        );
        _json(req, {
          'blocks': [
            for (final b in blocks)
              {
                'seq': b.seq,
                'bytes': base64Encode(b.bytes),
                'blockHash': b.blockHash,
                'createdAt': b.createdAt,
              },
          ],
        });
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    } on _MailboxHttpTooLarge {
      req.response.statusCode = 413;
      await req.response.close();
    } catch (err) {
      req.response.statusCode = _statusFor(err);
      await req.response.close();
    }
  }

  /// Returns null after writing 413. Throws on malformed JSON.
  Future<Map<String, Object?>> _readJson(HttpRequest req) async {
    if (req.contentLength > maxBodyBytes) {
      await req.drain();
      throw const _MailboxHttpTooLarge();
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in req) {
      builder.add(chunk);
      if (builder.length > maxBodyBytes) {
        throw const _MailboxHttpTooLarge();
      }
    }
    final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
    if (decoded is! Map) {
      throw const FormatException('mailbox json');
    }
    return Map<String, Object?>.from(decoded);
  }

  bool _rateOk(String key) {
    if (key.isEmpty) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final hit = _rate[key];
    if (hit == null || now - hit.windowStart >= rateWindowMs) {
      _rate[key] = _MailboxRateWindow(windowStart: now, count: 1);
      return true;
    }
    if (hit.count >= rateLimit) return false;
    hit.count += 1;
    return true;
  }

  void _json(HttpRequest req, Map<String, Object?> body) {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    req.response.close();
  }
}

class _MailboxRateWindow {
  _MailboxRateWindow({required this.windowStart, required this.count});
  final int windowStart;
  int count;
}

class _MailboxHttpTooLarge implements Exception {
  const _MailboxHttpTooLarge();
}

/// True only for loopback HTTP origins used by the local mailbox peer.
///
/// Allowed: `http://127.0.0.1`, `http://localhost`, `http://[::1]`
/// (any port). HTTPS, other schemes, and public hosts are false.
bool localStoragePeerOriginIsLoopback(String origin) {
  final uri = Uri.tryParse(origin);
  if (uri == null || uri.scheme != 'http' || !uri.hasAuthority) {
    return false;
  }
  final host = uri.host;
  return host == '127.0.0.1' || host == 'localhost' || host == '::1';
}

void _refusePublicMailboxOrigin(String origin) {
  if (!kLiveStorageFleet && !localStoragePeerOriginIsLoopback(origin)) {
    throw StateError(
      'mailbox HTTP refused: origin is not loopback while '
      'kLiveStorageFleet is false',
    );
  }
}

Future<int> _expectOk(HttpClientResponse res, String op) async {
  if (res.statusCode != 200) {
    throw StateError('storage peer $op ${res.statusCode}');
  }
  return res.statusCode;
}

StoragePeerClient httpStoragePeerClient(
  String origin, {
  String? adminToken,
}) {
  final defaultAdmin = adminToken;
  return StoragePeerClient(
    putRemote: ({
      required queueId,
      required depositCap,
      required bytes,
      required blockHash,
    }) async {
      _refusePublicMailboxOrigin(origin);
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse('$origin/v1/blocks'));
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'queueId': queueId,
            'depositCap': mailboxBytesToHex(depositCap),
            'block': {
              'bytes': base64Encode(bytes),
              'blockHash': blockHash,
            },
          }),
        );
        final res = await req.close();
        await _expectOk(res, 'put');
        final json = jsonDecode(await utf8.decodeStream(res));
        final seq = json is Map ? (json['seq'] as num?)?.toInt() ?? 0 : 0;
        return EncryptedBlock(
          seq: seq,
          bytes: bytes,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          blockHash: blockHash,
        );
      } finally {
        client.close(force: true);
      }
    },
    getRemote: ({
      required queueId,
      required readCap,
      fromSeq = 0,
    }) async {
      _refusePublicMailboxOrigin(origin);
      final client = HttpClient();
      try {
        final uri = Uri.parse(
          '$origin/v1/blocks?queueId=${Uri.encodeQueryComponent(queueId)}'
          '&readCap=${Uri.encodeQueryComponent(mailboxBytesToHex(readCap))}'
          '&fromSeq=$fromSeq',
        );
        final req = await client.getUrl(uri);
        final res = await req.close();
        await _expectOk(res, 'get');
        final text = await utf8.decodeStream(res);
        final json = jsonDecode(text) as Map<String, dynamic>;
        final list = json['blocks'] as List? ?? const [];
        return [
          for (final item in list)
            if (item is Map)
              EncryptedBlock(
                seq: (item['seq'] as num?)?.toInt() ?? 0,
                bytes: base64Decode(
                  (item['bytes'] as String?) ?? (item['b64'] as String?) ?? '',
                ),
                createdAt: (item['createdAt'] as num?)?.toInt() ??
                    (item['storedAt'] as num?)?.toInt() ??
                    0,
                blockHash: item['blockHash'] as String? ?? '',
              ),
        ];
      } finally {
        client.close(force: true);
      }
    },
    grantRemote: ({required cap, readCap, adminToken}) async {
      _refusePublicMailboxOrigin(origin);
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse('$origin/v1/grant'));
        req.headers.contentType = ContentType.json;
        final token = adminToken ?? defaultAdmin;
        if (token != null && token.isNotEmpty) {
          req.headers.set(kMailboxAdminHeader, token);
        }
        req.write(
          jsonEncode({
            'queueId': cap.queueId,
            'readCapHash': cap.readCapHash,
            'depositCapHash': cap.depositCapHash,
            'quotaBytes': cap.quotaBytes,
            'retentionMs': cap.retentionMs,
            'expiresAt': cap.expiresAt,
            if (readCap != null) 'readCap': mailboxBytesToHex(readCap),
          }),
        );
        final res = await req.close();
        await _expectOk(res, 'grant');
        await res.drain<void>();
      } finally {
        client.close(force: true);
      }
    },
    tombstoneRemote: ({
      required queueId,
      required readCap,
      required seq,
    }) async {
      _refusePublicMailboxOrigin(origin);
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse('$origin/v1/tombstone'));
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'queueId': queueId,
            'readCap': mailboxBytesToHex(readCap),
            'seq': seq,
          }),
        );
        final res = await req.close();
        await _expectOk(res, 'tombstone');
        await res.drain<void>();
      } finally {
        client.close(force: true);
      }
    },
    statsRemote: ({required queueId, required readCap}) async {
      _refusePublicMailboxOrigin(origin);
      final client = HttpClient();
      try {
        final uri = Uri.parse(
          '$origin/v1/stats?queueId=${Uri.encodeQueryComponent(queueId)}'
          '&readCap=${Uri.encodeQueryComponent(mailboxBytesToHex(readCap))}',
        );
        final req = await client.getUrl(uri);
        final res = await req.close();
        await _expectOk(res, 'stats');
        final json =
            jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
        return MailboxPeerStats(
          usedBytes: (json['usedBytes'] as num?)?.toInt() ??
              (json['bytes'] as num?)?.toInt() ??
              0,
          pendingCount: (json['pendingCount'] as num?)?.toInt() ??
              (json['blocks'] as num?)?.toInt() ??
              0,
        );
      } finally {
        client.close(force: true);
      }
    },
  );
}

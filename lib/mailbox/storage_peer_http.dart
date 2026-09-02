// Local HTTP blind storage peer. Encrypted blocks only.
// Not a public fleet — use this for desktop mailbox / CI.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'blind_store.dart';
import 'storage_peer_client.dart';

class StoragePeerHttp {
  StoragePeerHttp(
    this.store, {
    this.maxBodyBytes = kMailboxHttpMaxBodyBytes,
    this.rateLimit = kMailboxHttpRateLimit,
    this.rateWindowMs = kMailboxHttpRateWindowMs,
  });

  final BlindMailboxStore store;
  final int maxBodyBytes;
  final int rateLimit;
  final int rateWindowMs;
  HttpServer? _server;
  final Map<String, _MailboxRateWindow> _rate =
      <String, _MailboxRateWindow>{};

  int get port => _server?.port ?? 0;
  String get origin => 'http://127.0.0.1:$port';

  Future<void> start({int port = 0}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_onRequest);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  void grant(MailboxCapability cap) => store.grant(cap);

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
        store.grant(
          MailboxCapability(
            token: map['token'] as String,
            quotaBytes: (map['quotaBytes'] as num?)?.toInt() ?? 0,
            retentionMs: (map['retentionMs'] as num?)?.toInt() ?? 0,
            expiresAt: (map['expiresAt'] as num?)?.toInt() ?? 0,
          ),
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
        final token = map['token'] as String;
        if (!_rateOk(token)) {
          req.response.statusCode = 429;
          await req.response.close();
          return;
        }
        store.put(
          token: token,
          writerKey: map['writerKey'] as String,
          block: EncryptedBlock(
            seq: (map['seq'] as num?)?.toInt() ?? 0,
            bytes: base64Decode(map['b64'] as String? ?? ''),
            storedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        _json(req, {'ok': true});
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/v1/tombstone') {
        final map = await _readJson(req);
        if (!storagePeerKeysAreSafe(map)) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        final token = map['token'] as String? ?? '';
        final writer = map['writerKey'] as String? ?? '';
        final seq = (map['seq'] as num?)?.toInt();
        if (token.isEmpty || writer.isEmpty || seq == null) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        store.tombstone(token, writer, seq);
        _json(req, {'ok': true});
        return;
      }
      if (req.method == 'GET' && req.uri.path == '/v1/stats') {
        final token = req.uri.queryParameters['token'] ?? '';
        final writer = req.uri.queryParameters['writerKey'] ?? '';
        if (token.isEmpty || writer.isEmpty) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        try {
          store.get(token: token, writerKey: writer);
        } catch (_) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        _json(req, {
          'usedBytes': store.usedBytes(writer),
          'pendingCount': store.pendingCount(writer),
        });
        return;
      }
      if (req.method == 'GET' && req.uri.path == '/v1/blocks') {
        final token = req.uri.queryParameters['token'] ?? '';
        final writer = req.uri.queryParameters['writerKey'] ?? '';
        final from = int.tryParse(req.uri.queryParameters['fromSeq'] ?? '') ?? 0;
        if (token.isEmpty || writer.isEmpty) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        final blocks = store.get(
          token: token,
          writerKey: writer,
          fromSeq: from,
        );
        _json(req, {
          'blocks': [
            for (final b in blocks)
              {
                'seq': b.seq,
                'b64': base64Encode(b.bytes),
                'storedAt': b.storedAt,
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
    } catch (_) {
      req.response.statusCode = 400;
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

  bool _rateOk(String token) {
    if (token.isEmpty) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final hit = _rate[token];
    if (hit == null || now - hit.windowStart >= rateWindowMs) {
      _rate[token] = _MailboxRateWindow(windowStart: now, count: 1);
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

StoragePeerClient httpStoragePeerClient(String origin) {
  return StoragePeerClient(
    putRemote: ({
      required token,
      required writerKey,
      required block,
    }) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse('$origin/v1/blocks'));
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'token': token,
            'writerKey': writerKey,
            'seq': block.seq,
            'b64': base64Encode(block.bytes),
          }),
        );
        final res = await req.close();
        if (res.statusCode != 200) {
          throw StateError('storage peer put ${res.statusCode}');
        }
      } finally {
        client.close(force: true);
      }
    },
    getRemote: ({
      required token,
      required writerKey,
      fromSeq = 0,
    }) async {
      final client = HttpClient();
      try {
        final uri = Uri.parse(
          '$origin/v1/blocks?token=${Uri.encodeQueryComponent(token)}'
          '&writerKey=${Uri.encodeQueryComponent(writerKey)}'
          '&fromSeq=$fromSeq',
        );
        final req = await client.getUrl(uri);
        final res = await req.close();
        if (res.statusCode != 200) {
          throw StateError('storage peer get ${res.statusCode}');
        }
        final text = await utf8.decodeStream(res);
        final json = jsonDecode(text) as Map<String, dynamic>;
        final list = json['blocks'] as List? ?? const [];
        return [
          for (final item in list)
            if (item is Map)
              EncryptedBlock(
                seq: (item['seq'] as num?)?.toInt() ?? 0,
                bytes: base64Decode(item['b64'] as String? ?? ''),
                storedAt: (item['storedAt'] as num?)?.toInt() ?? 0,
              ),
        ];
      } finally {
        client.close(force: true);
      }
    },
    grantRemote: (cap) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse('$origin/v1/grant'));
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'token': cap.token,
            'quotaBytes': cap.quotaBytes,
            'retentionMs': cap.retentionMs,
            'expiresAt': cap.expiresAt,
          }),
        );
        final res = await req.close();
        if (res.statusCode != 200) {
          throw StateError('storage peer grant ${res.statusCode}');
        }
      } finally {
        client.close(force: true);
      }
    },
    tombstoneRemote: (token, writerKey, seq) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse('$origin/v1/tombstone'));
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'token': token,
            'writerKey': writerKey,
            'seq': seq,
          }),
        );
        final res = await req.close();
        if (res.statusCode != 200) {
          throw StateError('storage peer tombstone ${res.statusCode}');
        }
      } finally {
        client.close(force: true);
      }
    },
    statsRemote: ({required token, required writerKey}) async {
      final client = HttpClient();
      try {
        final uri = Uri.parse(
          '$origin/v1/stats?token=${Uri.encodeQueryComponent(token)}'
          '&writerKey=${Uri.encodeQueryComponent(writerKey)}',
        );
        final req = await client.getUrl(uri);
        final res = await req.close();
        if (res.statusCode != 200) {
          throw StateError('storage peer stats ${res.statusCode}');
        }
        final json = jsonDecode(await utf8.decodeStream(res))
            as Map<String, dynamic>;
        return MailboxPeerStats(
          usedBytes: (json['usedBytes'] as num?)?.toInt() ?? 0,
          pendingCount: (json['pendingCount'] as num?)?.toInt() ?? 0,
        );
      } finally {
        client.close(force: true);
      }
    },
  );
}

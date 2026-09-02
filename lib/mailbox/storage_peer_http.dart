// Local HTTP blind storage peer. Encrypted blocks only.
// Not a public fleet — use this for desktop mailbox / CI.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'blind_store.dart';
import 'mailbox_protocol.dart';
import 'storage_peer_client.dart';

class StoragePeerHttp {
  StoragePeerHttp(
    this.store, {
    required this.grantSecret,
    int Function()? nowMs,
    this.maxBodyBytes = kMailboxMaxBodyBytes,
  }) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final BlindMailboxStore store;
  final List<int> grantSecret;
  final int Function() nowMs;
  final int maxBodyBytes;
  HttpServer? _server;

  int get port => _server?.port ?? 0;
  String get origin => 'http://127.0.0.1:$port';

  Future<void> start({int port = 0}) async {
    await store.hydrate();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_onRequest);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _onRequest(HttpRequest req) async {
    try {
      if (req.method == 'GET' && req.uri.path == '/health') {
        _json(req, {'ok': true, 'role': 'storage', 'plaintext': false});
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/v1/mailbox') {
        await _onMailbox(req);
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/v1/blocks') {
        await _onLegacyPut(req);
        return;
      }
      if (req.method == 'GET' && req.uri.path == '/v1/blocks') {
        await _onLegacyGet(req);
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    } on MailboxProtocolException catch (err) {
      _error(req, err);
    } catch (_) {
      req.response.statusCode = 400;
      await req.response.close();
    }
  }

  Future<void> _onMailbox(HttpRequest req) async {
    final raw = await _readLimited(req);
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(raw));
    } catch (_) {
      throw MailboxProtocolException('malformed', 'json');
    }
    final request = MailboxHttpRequest.parse(decoded, bodyBytes: raw.length);
    verifyMailboxRequest(request, grantSecret: grantSecret, nowMs: nowMs());
    if (!store.rememberRequest(request.requestId)) {
      throw MailboxProtocolException('replay', 'request was already seen');
    }
    switch (request.op) {
      case MailboxOp.deposit:
        final existed = store.hasEnvelope(
          request.effectiveMailboxId,
          request.envelopeId!,
        );
        store.depositEnvelope(
          mailboxId: request.effectiveMailboxId,
          envelopeId: request.envelopeId!,
          bytes: request.ciphertext!,
          quotaBytes: request.capability.quotaBytes,
          retentionMs: request.capability.retentionMs,
        );
        await store.persist();
        _json(req, MailboxHttpResponse(ok: true, duplicate: existed).toJson());
      case MailboxOp.drain:
        final blocks = store.drainMailbox(
          mailboxId: request.effectiveMailboxId,
          retentionMs: request.capability.retentionMs,
          fromSeq: request.fromSeq,
        );
        _json(
          req,
          MailboxHttpResponse(
            ok: true,
            envelopes: [
              for (final block in blocks)
                {
                  'envelopeId': block.envelopeId,
                  'seq': block.seq,
                  'ciphertextB64': base64Encode(block.bytes),
                  'storedAt': block.storedAt,
                },
            ],
          ).toJson(),
        );
      case MailboxOp.ack:
        store.acknowledge(request.effectiveMailboxId, request.envelopeId!);
        await store.persist();
        _json(req, const MailboxHttpResponse(ok: true).toJson());
      case MailboxOp.delete:
        store.deleteEnvelope(request.effectiveMailboxId, request.envelopeId!);
        await store.persist();
        _json(req, const MailboxHttpResponse(ok: true).toJson());
    }
  }

  Future<void> _onLegacyPut(HttpRequest req) async {
    final raw = await _readLimited(req);
    final body = jsonDecode(utf8.decode(raw));
    if (body is! Map) {
      req.response.statusCode = 400;
      await req.response.close();
      return;
    }
    final map = Map<String, Object?>.from(body);
    if (!storagePeerBodyIsSafe(map)) {
      req.response.statusCode = 400;
      await req.response.close();
      return;
    }
    store.put(
      token: map['token'] as String? ?? '',
      writerKey: map['writerKey'] as String? ?? '',
      block: EncryptedBlock(
        seq: map['seq'] as int? ?? 0,
        bytes: base64Decode(map['b64'] as String? ?? ''),
        storedAt: nowMs(),
        envelopeId: map['envelopeId'] as String?,
      ),
    );
    _json(req, {'ok': true});
  }

  Future<void> _onLegacyGet(HttpRequest req) async {
    final token = req.uri.queryParameters['token'] ?? '';
    final writer = req.uri.queryParameters['writerKey'] ?? '';
    final from = int.tryParse(req.uri.queryParameters['fromSeq'] ?? '') ?? 0;
    final blocks = store.get(token: token, writerKey: writer, fromSeq: from);
    _json(req, {
      'blocks': [
        for (final b in blocks)
          {
            'seq': b.seq,
            'b64': base64Encode(b.bytes),
            'storedAt': b.storedAt,
            if (b.envelopeId != null) 'envelopeId': b.envelopeId,
          },
      ],
    });
  }

  Future<Uint8List> _readLimited(HttpRequest req) async {
    final declared = req.headers.contentLength;
    if (declared > maxBodyBytes) {
      throw MailboxProtocolException('oversized', 'content-length exceeds cap');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in req) {
      builder.add(chunk);
      if (builder.length > maxBodyBytes) {
        throw MailboxProtocolException('oversized', 'request body exceeds cap');
      }
    }
    return builder.takeBytes();
  }

  void _error(HttpRequest req, MailboxProtocolException err) {
    final status = switch (err.code) {
      'oversized' => 413,
      'unauthorized' ||
      'anonymous' ||
      'invalid-mac' ||
      'wrong-recipient' => 403,
      'expired' || 'not-yet-valid' || 'replay' => 401,
      'quota' => 429,
      'plaintext' => 400,
      _ => 400,
    };
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(
      jsonEncode(MailboxHttpResponse(ok: false, error: err.code).toJson()),
    );
    req.response.close();
  }

  void _json(HttpRequest req, Map<String, Object?> body) {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    req.response.close();
  }
}

StoragePeerClient httpStoragePeerClient(String origin) {
  Future<Map<String, Object?>> post(MailboxHttpRequest request) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$origin/v1/mailbox'));
      req.headers.contentType = ContentType.json;
      final encoded = utf8.encode(jsonEncode(request.toJson()));
      if (encoded.length > kMailboxMaxBodyBytes) {
        throw MailboxProtocolException('oversized', 'request body exceeds cap');
      }
      req.add(encoded);
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      Map<String, Object?> json;
      try {
        json = Map<String, Object?>.from(jsonDecode(text) as Map);
      } catch (_) {
        throw MailboxProtocolException('malformed', 'response json');
      }
      if (res.statusCode != 200) {
        throw MailboxProtocolException(
          json['error'] as String? ?? 'http-${res.statusCode}',
          'storage peer ${res.statusCode}',
        );
      }
      return json;
    } finally {
      client.close(force: true);
    }
  }

  return StoragePeerClient(
    putRemote: ({required token, required writerKey, required block}) async {
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
            if (block.envelopeId != null) 'envelopeId': block.envelopeId,
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
    getRemote: ({required token, required writerKey, fromSeq = 0}) async {
      final client = HttpClient();
      try {
        final uri = Uri.parse(
          '$origin/v1/blocks?token=${Uri.encodeQueryComponent(token)}'
          '&writerKey=${Uri.encodeQueryComponent(writerKey)}'
          '&fromSeq=$fromSeq',
        );
        final req = await client.getUrl(uri);
        final res = await req.close();
        final text = await utf8.decodeStream(res);
        final json = jsonDecode(text) as Map<String, dynamic>;
        final list = json['blocks'] as List? ?? const [];
        return [
          for (final item in list)
            if (item is Map)
              EncryptedBlock(
                seq: item['seq'] as int? ?? 0,
                bytes: base64Decode(item['b64'] as String? ?? ''),
                storedAt: item['storedAt'] as int? ?? 0,
                envelopeId: item['envelopeId'] as String?,
              ),
        ];
      } finally {
        client.close(force: true);
      }
    },
    depositRemote: (request) async {
      final json = await post(request);
      return MailboxDepositResult(duplicate: json['duplicate'] == true, seq: 0);
    },
    drainRemote: (request) async {
      final json = await post(request);
      final list = json['envelopes'] as List? ?? const [];
      return [
        for (final item in list)
          if (item is Map)
            EncryptedBlock(
              seq: item['seq'] as int? ?? 0,
              bytes: base64Decode(item['ciphertextB64'] as String? ?? ''),
              storedAt: item['storedAt'] as int? ?? 0,
              envelopeId: item['envelopeId'] as String?,
            ),
      ];
    },
    ackRemote: (request) async {
      await post(request);
    },
    deleteRemote: (request) async {
      await post(request);
    },
  );
}

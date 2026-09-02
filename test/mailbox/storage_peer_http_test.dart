import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/mailbox_protocol.dart';
import 'package:orbits_flutter/mailbox/storage_peer_client.dart';
import 'package:orbits_flutter/mailbox/storage_peer_http.dart';
import 'package:orbits_flutter/peer/room_disclaimer.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/layers.dart';

void main() {
  late List<int> grantSecret;
  late SignedMailboxCapability cap;

  setUp(() {
    grantSecret = List<int>.generate(32, (i) => i + 3);
    final now = DateTime.now().millisecondsSinceEpoch;
    cap = issueMailboxCapability(
      grantSecret: grantSecret,
      tokenId: 'tok-1',
      mailboxId: 'mb-alice-bob',
      scopes: MailboxScope.values.toSet(),
      issuedAt: now - 1000,
      notBefore: now - 1000,
      expiresAt: now + 60 * 1000,
      quotaBytes: 64 * 1024,
      retentionMs: 30 * 1000,
    );
  });

  test('capability payload is canonical and field-order independent', () {
    final a = utf8.decode(cap.canonicalPayload());
    expect(a, startsWith('$kMailboxCapabilityInfo\n'));
    expect(a, contains('ack,delete,deposit,drain'));
    final shuffled = SignedMailboxCapability.parse({
      'retentionMs': cap.retentionMs,
      'mac': base64Encode(cap.mac),
      'v': kMailboxCapabilityInfo,
      'quotaBytes': cap.quotaBytes,
      'expiresAt': cap.expiresAt,
      'notBefore': cap.notBefore,
      'issuedAt': cap.issuedAt,
      'scopes': ['drain', 'deposit', 'delete', 'ack'],
      'mailboxId': cap.mailboxId,
      'tokenId': cap.tokenId,
    });
    expect(shuffled.canonicalPayload(), cap.canonicalPayload());
    expect(hmacSha256(grantSecret, shuffled.canonicalPayload()), cap.mac);
  });

  test(
    'anonymous, expired, future, wrong-recipient, and bad MAC fail closed',
    () {
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(
        () => issueMailboxCapability(
          grantSecret: grantSecret,
          tokenId: '',
          mailboxId: 'mb',
          scopes: {MailboxScope.deposit},
          issuedAt: now,
          notBefore: now,
          expiresAt: now + 1,
          quotaBytes: 10,
          retentionMs: 10,
        ),
        throwsA(
          isA<MailboxProtocolException>().having(
            (e) => e.code,
            'code',
            'anonymous',
          ),
        ),
      );
      expect(
        () => verifyMailboxCapability(
          cap,
          grantSecret: grantSecret,
          scope: MailboxScope.deposit,
          mailboxId: 'other-mailbox',
          nowMs: now,
        ),
        throwsA(
          isA<MailboxProtocolException>().having(
            (e) => e.code,
            'code',
            'wrong-recipient',
          ),
        ),
      );
      expect(
        () => verifyMailboxCapability(
          cap,
          grantSecret: List<int>.filled(32, 9),
          scope: MailboxScope.deposit,
          mailboxId: cap.mailboxId,
          nowMs: now,
        ),
        throwsA(
          isA<MailboxProtocolException>().having(
            (e) => e.code,
            'code',
            'invalid-mac',
          ),
        ),
      );
      expect(
        () => verifyMailboxCapability(
          cap,
          grantSecret: grantSecret,
          scope: MailboxScope.deposit,
          mailboxId: cap.mailboxId,
          nowMs: cap.expiresAt + 1,
        ),
        throwsA(
          isA<MailboxProtocolException>().having(
            (e) => e.code,
            'code',
            'expired',
          ),
        ),
      );
      expect(
        () => verifyMailboxCapability(
          cap,
          grantSecret: grantSecret,
          scope: MailboxScope.deposit,
          mailboxId: cap.mailboxId,
          nowMs: cap.notBefore - kMailboxClockSkewMs - 1,
        ),
        throwsA(
          isA<MailboxProtocolException>().having(
            (e) => e.code,
            'code',
            'not-yet-valid',
          ),
        ),
      );
    },
  );

  test('plaintext and oversized envelopes are rejected before persist', () {
    expect(
      () => rejectPlaintextEnvelope(
        utf8.encode(jsonEncode({'plaintext': 'hello'})),
      ),
      throwsA(
        isA<MailboxProtocolException>().having(
          (e) => e.code,
          'code',
          'plaintext',
        ),
      ),
    );
    expect(
      () => MailboxHttpRequest.parse({
        'v': kMailboxHttpVersion,
        'op': 'deposit',
        'requestId': 'r1',
        'issuedAt': 1,
        'capability': cap.toJson(),
        'envelopeId': 'e1',
        'ciphertextB64': base64Encode(
          List<int>.filled(kMailboxMaxEnvelopeBytes + 1, 1),
        ),
      }, bodyBytes: 10),
      throwsA(
        isA<MailboxProtocolException>().having(
          (e) => e.code,
          'code',
          'oversized',
        ),
      ),
    );
    rejectPlaintextEnvelope(utf8.encode('v2:hdr:iv:ct'));
  });

  test(
    'sender deposits, shuts down; later recipient drains, projects once, acks',
    () async {
      final dir = await Directory.systemTemp.createTemp('orbits-mailbox-');
      final persist = File('${dir.path}/store.json');
      final store = BlindMailboxStore(persistFile: persist);
      final server = StoragePeerHttp(store, grantSecret: grantSecret);
      await server.start();
      addTearDown(() async {
        await server.stop();
        if (dir.existsSync()) await dir.delete(recursive: true);
      });

      final client = httpStoragePeerClient(server.origin);
      final secrets = DiscoverySecretStore();
      final senderPackets = <Object?>[];
      final sender = DualStackBridge(
        transport: LoopbackOrbitsTransport(),
        journal: MemoryJournal('sender-device'),
        selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
        selfDeviceId: 'sender-device',
        secrets: secrets,
        isBlocked: (_) => false,
        storagePeer: client,
        mailboxCapability: cap,
        onPacket: (_, data) async => senderPackets.add(data),
      )..attach();

      const envelope = 'v2:hdr:iv:ciphertext-bytes';
      expect(
        await sender.depositMailboxRemote(
          utf8.encode(envelope),
          envelopeId: 'env-1',
        ),
        isTrue,
      );
      await sender.detach();

      final seen = <Object?>[];
      final recipient = DualStackBridge(
        transport: LoopbackOrbitsTransport(),
        journal: MemoryJournal('recipient-device'),
        selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
        selfDeviceId: 'recipient-device',
        secrets: secrets,
        isBlocked: (_) => false,
        storagePeer: client,
        mailboxCapability: cap,
        onPacket: (_, data) async => seen.add(data),
      )..attach();

      final n = await recipient.drainMailbox();
      expect(n, 1);
      expect(seen, ['v2:hdr:iv:ciphertext-bytes']);
      expect(recipient.journal.length, 1);
      expect(
        recipient.journal.records.every(replicationFieldsAreSafeFromRecord),
        isTrue,
      );

      final again = await recipient.drainMailbox();
      expect(again, 0);
      expect(seen, hasLength(1));
      await recipient.detach();
      expect(kRoomsApplicationE2eImplemented, isFalse);
      expect(kCompletedMigrationPhase, 0);
    },
  );

  test(
    'duplicate deposit is idempotent and drain then ack hides the envelope',
    () async {
      final server = StoragePeerHttp(
        BlindMailboxStore(),
        grantSecret: grantSecret,
      );
      await server.start();
      addTearDown(server.stop);
      final client = httpStoragePeerClient(server.origin);
      final first = await client.deposit(
        depositRequest(
          capability: cap,
          envelopeId: 'dup-1',
          ciphertext: utf8.encode('v2:a:b:c'),
          requestId: 'dep-a',
        ),
      );
      expect(first.duplicate, isFalse);
      final second = await client.deposit(
        depositRequest(
          capability: cap,
          envelopeId: 'dup-1',
          ciphertext: utf8.encode('v2:a:b:c'),
          requestId: 'dep-b',
        ),
      );
      expect(second.duplicate, isTrue);
      final drained = await client.drain(
        drainRequest(capability: cap, requestId: 'drn-1'),
      );
      expect(drained, hasLength(1));
      await client.ack(
        ackRequest(capability: cap, envelopeId: 'dup-1', requestId: 'ack-1'),
      );
      final afterAck = await client.drain(
        drainRequest(capability: cap, requestId: 'drn-2'),
      );
      expect(afterAck, isEmpty);
    },
  );

  test('replayed request id is rejected', () async {
    final server = StoragePeerHttp(
      BlindMailboxStore(),
      grantSecret: grantSecret,
    );
    await server.start();
    addTearDown(server.stop);
    final client = httpStoragePeerClient(server.origin);
    final req = depositRequest(
      capability: cap,
      envelopeId: 'rplay',
      ciphertext: utf8.encode('v2:a:b:c'),
      requestId: 'same-id',
    );
    await client.deposit(req);
    await expectLater(
      client.deposit(req),
      throwsA(
        isA<MailboxProtocolException>().having((e) => e.code, 'code', 'replay'),
      ),
    );
  });

  test(
    'restart persistence restores envelopes; corrupt records are skipped',
    () async {
      final dir = await Directory.systemTemp.createTemp('orbits-mailbox-rs-');
      final persist = File('${dir.path}/store.json');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      final first = StoragePeerHttp(
        BlindMailboxStore(persistFile: persist),
        grantSecret: grantSecret,
      );
      await first.start();
      final client = httpStoragePeerClient(first.origin);
      await client.deposit(
        depositRequest(
          capability: cap,
          envelopeId: 'persist-1',
          ciphertext: utf8.encode('v2:keep:this:one'),
          requestId: 'p1',
        ),
      );
      await first.stop();

      final raw =
          jsonDecode(await persist.readAsString()) as Map<String, dynamic>;
      final cores = raw['cores'] as Map<String, dynamic>;
      final list = List<dynamic>.from(cores[cap.mailboxId] as List);
      list.add({'seq': 99, 'b64': '!!!not-base64!!!', 'plaintext': 'leak'});
      cores[cap.mailboxId] = list;
      await persist.writeAsString(jsonEncode(raw));

      final second = StoragePeerHttp(
        BlindMailboxStore(persistFile: persist),
        grantSecret: grantSecret,
      );
      await second.start();
      addTearDown(second.stop);
      final restored = httpStoragePeerClient(second.origin);
      final drained = await restored.drain(
        drainRequest(capability: cap, requestId: 'p-drain'),
      );
      expect(drained, hasLength(1));
      expect(utf8.decode(drained.single.bytes), 'v2:keep:this:one');
    },
  );

  test(
    'HTTP rejects plaintext, oversized, expired, and wrong-recipient',
    () async {
      final server = StoragePeerHttp(
        BlindMailboxStore(),
        grantSecret: grantSecret,
      );
      await server.start();
      addTearDown(server.stop);
      final origin = server.origin;

      Future<int> post(Map<String, Object?> body) async {
        final http = HttpClient();
        try {
          final req = await http.postUrl(Uri.parse('$origin/v1/mailbox'));
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
          final res = await req.close();
          await res.drain<void>();
          return res.statusCode;
        } finally {
          http.close(force: true);
        }
      }

      expect(
        await post({
          'v': kMailboxHttpVersion,
          'op': 'deposit',
          'requestId': 'plain-1',
          'issuedAt': DateTime.now().millisecondsSinceEpoch,
          'capability': cap.toJson(),
          'mailboxId': cap.mailboxId,
          'envelopeId': 'p',
          'ciphertextB64': base64Encode(
            utf8.encode(jsonEncode({'plaintext': 'nope'})),
          ),
        }),
        400,
      );

      final expired = issueMailboxCapability(
        grantSecret: grantSecret,
        tokenId: 'tok-exp',
        mailboxId: cap.mailboxId,
        scopes: MailboxScope.values.toSet(),
        issuedAt: 1,
        notBefore: 1,
        expiresAt: 2,
        quotaBytes: 100,
        retentionMs: 100,
      );
      expect(
        await post({
          'v': kMailboxHttpVersion,
          'op': 'deposit',
          'requestId': 'exp-1',
          'issuedAt': DateTime.now().millisecondsSinceEpoch,
          'capability': expired.toJson(),
          'mailboxId': cap.mailboxId,
          'envelopeId': 'e',
          'ciphertextB64': base64Encode(utf8.encode('v2:a:b:c')),
        }),
        401,
      );

      expect(
        await post({
          'v': kMailboxHttpVersion,
          'op': 'deposit',
          'requestId': 'wrong-1',
          'issuedAt': DateTime.now().millisecondsSinceEpoch,
          'capability': cap.toJson(),
          'mailboxId': 'someone-else',
          'envelopeId': 'e2',
          'ciphertextB64': base64Encode(utf8.encode('v2:a:b:c')),
        }),
        403,
      );

      expect(
        await post({
          'v': kMailboxHttpVersion,
          'op': 'deposit',
          'requestId': 'big-1',
          'issuedAt': DateTime.now().millisecondsSinceEpoch,
          'capability': cap.toJson(),
          'mailboxId': cap.mailboxId,
          'envelopeId': 'big',
          'ciphertextB64': base64Encode(
            List<int>.filled(cap.quotaBytes + 8, 7),
          ),
        }),
        429,
      );

      final huge = StoragePeerHttp(
        BlindMailboxStore(),
        grantSecret: grantSecret,
        maxBodyBytes: 64,
      );
      await huge.start();
      addTearDown(huge.stop);
      final http = HttpClient();
      try {
        final req = await http.postUrl(Uri.parse('${huge.origin}/v1/mailbox'));
        req.headers.contentType = ContentType.json;
        req.add(
          utf8.encode(
            jsonEncode({
              'v': kMailboxHttpVersion,
              'op': 'deposit',
              'requestId': 'oversize-body',
              'issuedAt': DateTime.now().millisecondsSinceEpoch,
              'capability': cap.toJson(),
              'envelopeId': 'x',
              'ciphertextB64': base64Encode(utf8.encode('v2:a:b:c')),
              'pad': 'x' * 200,
            }),
          ),
        );
        final res = await req.close();
        await res.drain<void>();
        expect(res.statusCode, 413);
      } finally {
        http.close(force: true);
      }
    },
  );

  test('malformed JSON and binary frames are rejected', () async {
    final server = StoragePeerHttp(
      BlindMailboxStore(),
      grantSecret: grantSecret,
    );
    await server.start();
    addTearDown(server.stop);
    final http = HttpClient();
    try {
      final req = await http.postUrl(Uri.parse('${server.origin}/v1/mailbox'));
      req.headers.contentType = ContentType.json;
      req.add(Uint8List.fromList(const [0, 1, 2, 255]));
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 400);
    } finally {
      http.close(force: true);
    }
  });

  test('health endpoint never advertises a public fleet', () async {
    final server = StoragePeerHttp(
      BlindMailboxStore(),
      grantSecret: grantSecret,
    );
    await server.start();
    addTearDown(server.stop);
    final http = HttpClient();
    try {
      final req = await http.getUrl(Uri.parse('${server.origin}/health'));
      final res = await req.close();
      final body = jsonDecode(await utf8.decodeStream(res)) as Map;
      expect(res.statusCode, 200);
      expect(body['role'], 'storage');
      expect(body['plaintext'], isFalse);
      expect(body.containsKey('fleet'), isFalse);
      expect(body.containsKey('apns'), isFalse);
    } finally {
      http.close(force: true);
    }
  });
}

bool replicationFieldsAreSafeFromRecord(dynamic record) {
  final fields = (record.fields as Map).keys.map((k) => k.toString());
  return replicationFieldsAreSafe(fields);
}

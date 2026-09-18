import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/mailbox_protocol.dart';

void main() {
  test('save, delete, persist, hydrate does not resurrect the envelope', () async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}orbits-mailbox-tombstone.json',
    );
    if (file.existsSync()) file.deleteSync();
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    final first = BlindMailboxStore(persistFile: file);
    first.grant(
      MailboxCapability(
        token: 'cap-1',
        quotaBytes: 1024,
        retentionMs: 60 * 1000,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
      ),
    );
    first.depositEnvelope(
      mailboxId: 'box',
      envelopeId: 'env-1',
      bytes: wrapOpaqueEnvelope(const [1, 2, 3]),
      quotaBytes: 1024,
      retentionMs: 60 * 1000,
    );
    expect(first.hasEnvelope('box', 'env-1'), isTrue);
    first.deleteEnvelope('box', 'env-1');
    expect(first.hasEnvelope('box', 'env-1'), isFalse);
    first.deleteEnvelope('box', 'env-1');
    await first.persist();

    final second = BlindMailboxStore(persistFile: file);
    await second.hydrate();
    expect(second.hasEnvelope('box', 'env-1'), isFalse);
    expect(second.drainMailbox(mailboxId: 'box', retentionMs: 60 * 1000), isEmpty);
  });

  test('malformed tombstone is rejected on hydrate', () async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}orbits-mailbox-bad-tombstone.json',
    );
    file.writeAsStringSync(
      '{"v":"orbits-mailbox-http-v1","cores":{"box":[{"seq":0,"b64":"T1QxAQ==","storedAt":1,"envelopeId":"e","acked":false,"tombstoned":true}]},"seq":{},"requests":{}}',
    );
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    final store = BlindMailboxStore(persistFile: file);
    expect(store.hydrate, throwsA(isA<MailboxProtocolException>()));
  });

  test('legacy empty tombstone hydrates without decrypt', () async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}orbits-mailbox-legacy-tombstone.json',
    );
    file.writeAsStringSync(
      '{"v":"orbits-mailbox-http-v1","cores":{"box":[{"seq":0,"b64":"","storedAt":1,"envelopeId":"e","acked":false,"tombstoned":true}]},"seq":{},"requests":{}}',
    );
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    final store = BlindMailboxStore(persistFile: file);
    await store.hydrate();
    expect(store.hasEnvelope('box', 'e'), isFalse);
  });

  test('tombstone is not a valid ciphertext envelope', () {
    final tomb = encodeMailboxTombstone(id: 'env-1', deletedAt: 1);
    expect(isMailboxTombstone(tomb), isTrue);
    expect(() => rejectPlaintextEnvelope(tomb), throwsA(isA<MailboxProtocolException>()));
    expect(requireMailboxTombstone(tomb).id, 'env-1');
  });
}

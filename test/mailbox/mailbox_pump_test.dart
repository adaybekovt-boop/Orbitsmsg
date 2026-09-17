import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/mailbox_pump.dart';
import 'package:orbits_flutter/mailbox/storage_peer_client.dart';

MailboxCapability _cap(String token) {
  return MailboxCapability(
    token: token,
    quotaBytes: 1024,
    retentionMs: 30 * 24 * 3600 * 1000,
    expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
  );
}

void main() {
  test('mailboxPumpTokenIsSafe rejects empty, URLs, and secret fragments', () {
    expect(mailboxPumpTokenIsSafe('cap-1'), isTrue);
    expect(mailboxPumpTokenIsSafe(''), isFalse);
    expect(mailboxPumpTokenIsSafe('https://evil/tok'), isFalse);
    expect(mailboxPumpTokenIsSafe('ftp://x'), isFalse);
    expect(mailboxPumpTokenIsSafe('file:///t'), isFalse);
    expect(mailboxPumpTokenIsSafe('cap-peerId'), isFalse);
    expect(mailboxPumpTokenIsSafe('x-fileKey-y'), isFalse);
    expect(mailboxPumpTokenIsSafe('x-rootKey-y'), isFalse);
    expect(mailboxPumpTokenIsSafe('x-discoverySecret-y'), isFalse);
  });

  test('safe token deposits ciphertext and collect returns one block', () {
    final store = BlindMailboxStore()..grant(_cap('cap-1'));
    final pump = MailboxPump();
    const envelope = <int>[9, 8, 7, 6];
    pump.deposit(
      store: store,
      token: 'cap-1',
      writerKey: 'writer-a',
      encryptedEnvelope: envelope,
    );
    final blocks = pump.collect(
      store: store,
      token: 'cap-1',
      writerKey: 'writer-a',
    );
    expect(blocks, hasLength(1));
    expect(blocks.single.bytes, envelope);
    expect(store.pendingCount('writer-a'), 1);
  });

  test('URL and peerId tokens are refused and the store stays empty', () {
    final store = BlindMailboxStore();
    final pump = MailboxPump();
    for (final token in <String>[
      'https://evil/tok',
      'ftp://x',
      'file:///t',
      'cap-peerId',
    ]) {
      store.grant(_cap(token));
      expect(
        () => pump.deposit(
          store: store,
          token: token,
          writerKey: 'writer-a',
          encryptedEnvelope: const [1, 2, 3],
        ),
        throwsStateError,
      );
      expect(store.pendingCount('writer-a'), 0);
    }
  });

  test('empty envelope throws and does not put a block', () {
    final store = BlindMailboxStore()..grant(_cap('cap-1'));
    final pump = MailboxPump();
    expect(
      () => pump.deposit(
        store: store,
        token: 'cap-1',
        writerKey: 'writer-a',
        encryptedEnvelope: const [],
      ),
      throwsStateError,
    );
    expect(store.pendingCount('writer-a'), 0);
  });

  test('empty writer throws and does not put a block', () {
    final store = BlindMailboxStore()..grant(_cap('cap-1'));
    final pump = MailboxPump();
    expect(
      () => pump.deposit(
        store: store,
        token: 'cap-1',
        writerKey: '',
        encryptedEnvelope: const [1],
      ),
      throwsStateError,
    );
    expect(store.pendingCount(''), 0);
    expect(store.pendingCount('writer-a'), 0);
  });

  test('collect with a URL token throws', () {
    final store = BlindMailboxStore()..grant(_cap('https://evil/tok'));
    final pump = MailboxPump();
    expect(
      () => pump.collect(
        store: store,
        token: 'https://evil/tok',
        writerKey: 'writer-a',
      ),
      throwsStateError,
    );
  });

  test('safe path stores ciphertext bytes only', () {
    final store = BlindMailboxStore()..grant(_cap('cap-1'));
    final pump = MailboxPump();
    const ciphertext = <int>[0xab, 0xcd, 0xef];
    pump.deposit(
      store: store,
      token: 'cap-1',
      writerKey: 'writer-a',
      encryptedEnvelope: ciphertext,
    );
    final blocks = pump.collect(
      store: store,
      token: 'cap-1',
      writerKey: 'writer-a',
    );
    expect(blocks.single.bytes, ciphertext);
    expect(store.usedBytes('writer-a'), ciphertext.length);
    expect(blocks.single, isA<EncryptedBlock>());
    expect(blocks.single.bytes, isNot(equals('plaintext'.codeUnits)));
  });

  test('depositClient and collectClient honor the same token rules', () async {
    final store = BlindMailboxStore()..grant(_cap('cap-1'));
    final client = StoragePeerClient.local(store);
    final pump = MailboxPump();
    await pump.depositClient(
      client: client,
      token: 'cap-1',
      writerKey: 'writer-a',
      encryptedEnvelope: const [4, 5],
    );
    final blocks = await pump.collectClient(
      client: client,
      token: 'cap-1',
      writerKey: 'writer-a',
    );
    expect(blocks, hasLength(1));
    expect(blocks.single.bytes, [4, 5]);

    expect(
      () => pump.depositClient(
        client: client,
        token: 'https://evil/tok',
        writerKey: 'writer-a',
        encryptedEnvelope: const [1],
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      () => pump.collectClient(
        client: client,
        token: 'ftp://x',
        writerKey: 'writer-a',
      ),
      throwsA(isA<StateError>()),
    );
  });
}

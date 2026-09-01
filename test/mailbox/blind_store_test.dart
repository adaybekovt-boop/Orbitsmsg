import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';

void main() {
  test('recipient can fetch after the sender is gone', () {
    final store = BlindMailboxStore();
    store.grant(
      MailboxCapability(
        token: 'cap-1',
        quotaBytes: 1024,
        retentionMs: 30 * 24 * 3600 * 1000,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
      ),
    );
    store.put(
      token: 'cap-1',
      writerKey: 'writer-a',
      block: EncryptedBlock(
        seq: 0,
        bytes: const [1, 2, 3],
        storedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    final blocks = store.get(token: 'cap-1', writerKey: 'writer-a');
    expect(blocks, hasLength(1));
    expect(blocks.first.bytes, [1, 2, 3]);
  });

  test('anonymous and over-quota writes are rejected', () {
    final store = BlindMailboxStore();
    expect(
      () => store.grant(
        const MailboxCapability(
          token: '',
          quotaBytes: 10,
          retentionMs: 1,
          expiresAt: 1,
        ),
      ),
      throwsArgumentError,
    );
    store.grant(
      MailboxCapability(
        token: 'cap-1',
        quotaBytes: 2,
        retentionMs: 1000,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
      ),
    );
    expect(
      () => store.put(
        token: 'cap-1',
        writerKey: 'w',
        block: EncryptedBlock(
          seq: 0,
          bytes: const [1, 2, 3],
          storedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ),
      throwsStateError,
    );
  });

  test('tombstone removes ciphertext', () {
    final store = BlindMailboxStore();
    store.grant(
      MailboxCapability(
        token: 'cap-1',
        quotaBytes: 100,
        retentionMs: 100000,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
      ),
    );
    store.put(
      token: 'cap-1',
      writerKey: 'w',
      block: EncryptedBlock(
        seq: 3,
        bytes: const [9],
        storedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    store.tombstone('cap-1', 'w', 3);
    expect(store.get(token: 'cap-1', writerKey: 'w'), isEmpty);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/mailbox_pump.dart';
import 'package:orbits_flutter/mailbox/storage_peer_client.dart';

import 'mailbox_test_support.dart';

void main() {
  test('pump deposits sealed bytes and recipient collects them', () async {
    final store = BlindMailboxStore();
    final owner = await deriveFreshMailbox();
    registerCaps(store, owner.caps);
    final pump = MailboxPump();
    pump.deposit(
      store: store,
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      sealedEnvelope: const [1, 2, 3, 4],
    );
    expect(store.pendingCount(owner.caps.queueId), 1);
    final got = pump.collect(
      store: store,
      queueId: owner.caps.queueId,
      readCap: owner.caps.readCap,
    );
    expect(got, hasLength(1));
    expect(got.first.bytes, [1, 2, 3, 4]);
  });

  test('pump client deposit then collect via local client', () async {
    final store = BlindMailboxStore();
    final owner = await deriveFreshMailbox();
    registerCaps(store, owner.caps);
    final client = StoragePeerClient.local(store);
    final pump = MailboxPump();
    await pump.depositClient(
      client: client,
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      sealedEnvelope: const [9, 8, 7],
    );
    final got = await pump.collectClient(
      client: client,
      queueId: owner.caps.queueId,
      readCap: owner.caps.readCap,
    );
    expect(got.single.bytes, [9, 8, 7]);
  });

  test('pump refuses unsafe queue ids and empty envelopes', () {
    final store = BlindMailboxStore();
    final pump = MailboxPump();
    expect(
      () => pump.deposit(
        store: store,
        queueId: 'https://evil/tok',
        depositCap: List<int>.filled(32, 1),
        sealedEnvelope: const [1],
      ),
      throwsStateError,
    );
    expect(
      () => pump.deposit(
        store: store,
        queueId: 'aa' * 32,
        depositCap: List<int>.filled(32, 1),
        sealedEnvelope: const [],
      ),
      throwsStateError,
    );
  });

  test('usedBytes counts ciphertext only', () async {
    final store = BlindMailboxStore();
    final owner = await deriveFreshMailbox();
    registerCaps(store, owner.caps);
    const ciphertext = [10, 11, 12, 13, 14];
    MailboxPump().deposit(
      store: store,
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      sealedEnvelope: ciphertext,
    );
    expect(store.usedBytes(owner.caps.queueId), ciphertext.length);
  });
}

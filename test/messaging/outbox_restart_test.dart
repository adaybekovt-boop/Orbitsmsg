// R06 — outbound rows left in `sent`/`inflight` must re-enter the retry
// queue after a process restart (no in-memory timer).

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

void main() {
  late OrbitsDatabase database;
  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 3 + 5) & 0xff));
  });
  tearDown(() async {
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  test('sent-without-ACK is recovered as pending and then delivered', () async {
    const msgId = 'self:4000:dddd4444';
    await db.saveMessage({
      'id': msgId,
      'peerId': 'ORBIT-PEER04',
      'timestamp': 4000,
      'direction': 'out',
      'status': 'sent',
      'payload': {'type': 'text', 'text': 'after crash'},
    });

    // Simulate process death: in-memory SentAckGuard is gone.
    expect(
      (await db.getPendingMessages(peerId: 'ORBIT-PEER04'))
          .map((r) => r['id']),
      contains(msgId),
      reason: 'sent-without-ACK must stay in the unconfirmed outbox',
    );

    final recovered = await db.recoverUnconfirmedOutbound();
    expect(recovered, 1);
    expect((await db.getMessageById(msgId))!['status'], 'pending');

    // Restarted send succeeds and receiver ACKs.
    await db.updateMessageStatus(msgId, 'inflight');
    await db.updateMessageStatus(msgId, 'delivered');
    expect((await db.getMessageById(msgId))!['status'], 'delivered');
    expect(await db.getPendingMessages(peerId: 'ORBIT-PEER04'), isEmpty);
  });
}

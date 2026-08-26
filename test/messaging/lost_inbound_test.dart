// Round 5 B.5 — a locked vault must not silently swallow inbound messages.
//
// Contract:
//   1. db.saveMessage under a LOCKED vault fails closed (throws) — the
//      precondition that used to vanish into _persistBestEffort's swallow.
//   2. LostInboundLedger records the drop AND emits a structured payload via
//      error_reporter (registerSink capture works in release semantics —
//      no kDebugMode gating).
//   3. MessagingState carries lostInboundCount so the UI can show the loss.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/error_reporter.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/messaging/lost_inbound_ledger.dart';
import 'package:orbits_flutter/state/messaging_notifier.dart';
import 'package:drift/native.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

void main() {
  late OrbitsDatabase database;
  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => i * 17 & 0xff));
  });
  tearDown(() async {
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  test('locked vault → saveMessage fails closed (no plaintext fallback)',
      () async {
    clearVaultKek();
    await expectLater(
      db.saveMessage({
        'id': 'm-locked',
        'peerId': 'ORBIT-11AA22BB33CC44DD',
        'timestamp': 123,
        'direction': 'in',
        'status': 'delivered',
        'payload': {'type': 'text', 'text': 'while locked'},
      }),
      throwsStateError,
    );
  });

  test('LostInboundLedger reports every drop through error_reporter',
      () async {
    final captured = <Map<String, Object?>>[];
    final unsub = registerSink((payload, error) {
      captured.add(payload);
    });

    final ledger = LostInboundLedger();
    ledger.recordDrop(
      msgId: 'm-1',
      fromPeer: 'ORBIT-11AA22BB33CC44DD',
      error: StateError('vault locked'),
    );
    ledger.recordDrop(
      msgId: 'm-2',
      fromPeer: 'ORBIT-11AA22BB33CC44DD',
      error: StateError('vault locked'),
    );

    expect(ledger.drops, 2);
    expect(captured, hasLength(2));
    expect(captured.first['source'], 'messaging.inbound.drop');
    expect(captured.first['msgId'], 'm-1');
    // The message text must never ride the report (only metadata).
    expect(captured.first.toString().contains('while locked'), isFalse,
        reason: 'reports carry ids, not content');

    ledger.reset();
    expect(ledger.drops, 0);
    unsub();
  });

  test('MessagingState.lostInboundCount survives copyWith of typing state',
      () {
    const s = MessagingState();
    final bumped = s.copyWith(lostInboundCount: s.lostInboundCount + 1);
    expect(bumped.lostInboundCount, 1);

    final typingChanged = bumped.copyWith(typingByPeer: {'X': true});
    expect(typingChanged.lostInboundCount, 1,
        reason: 'typing updates must not reset the loss counter');
  });
}

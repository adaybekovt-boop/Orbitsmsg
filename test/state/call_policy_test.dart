// R6-06 — incoming 1:1 calls from a blocked peer must not ring.
// Block is persisted on the peer row, so a restart still declines.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/state/call_policy.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

void main() {
  group('decideIncomingCall', () {
    test('accepts a free 1:1 call from an unblocked peer', () {
      expect(
        decideIncomingCall(
          metadata: const <String, Object?>{},
          busy: false,
          blocked: false,
        ),
        IncomingCallDecision.accept,
      );
    });

    test('ignores room-voice (RoomManager owns those)', () {
      expect(
        decideIncomingCall(
          metadata: const <String, Object?>{'channel': 'room-voice'},
          busy: false,
          blocked: false,
        ),
        IncomingCallDecision.ignoreRoomVoice,
      );
    });

    test('declines when already in a call', () {
      expect(
        decideIncomingCall(
          metadata: const <String, Object?>{},
          busy: true,
          blocked: false,
        ),
        IncomingCallDecision.declineBusy,
      );
    });

    test('declines a blocked peer before ringing', () {
      expect(
        decideIncomingCall(
          metadata: const <String, Object?>{},
          busy: false,
          blocked: true,
        ),
        IncomingCallDecision.declineBlocked,
      );
    });
  });

  test('mid-call block hangs up only the matching peer', () {
    expect(
      shouldEndCallForBlockedPeer(
        remotePeerId: 'ORBIT-EVIL01',
        isActive: true,
        blockedPeerId: 'ORBIT-EVIL01',
      ),
      isTrue,
    );
    expect(
      shouldEndCallForBlockedPeer(
        remotePeerId: 'ORBIT-EVIL01',
        isActive: true,
        blockedPeerId: 'ORBIT-OTHER1',
      ),
      isFalse,
    );
    expect(
      shouldEndCallForBlockedPeer(
        remotePeerId: 'ORBIT-EVIL01',
        isActive: false,
        blockedPeerId: 'ORBIT-EVIL01',
      ),
      isFalse,
    );
  });

  test('blocked flag survives restart and still declines the call', () async {
    final database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i + 11) & 0xff));
    addTearDown(() async {
      clearVaultKek();
      await closeOrbitsDatabase();
    });

    const peer = 'ORBIT-EVIL01';
    await db.savePeer({'id': peer, 'displayName': 'Mallory'});
    await db.setPeerBlocked(peer, true);

    // "Restart": new process reads the same persisted row.
    final row = await db.getPeer(peer);
    expect(row, isNotNull);
    final blocked = row!['blocked'] == true ||
        (row['blocked'] is num && (row['blocked'] as num).toInt() == 1);
    expect(blocked, isTrue, reason: 'block must persist across restart');
    expect(
      decideIncomingCall(
        metadata: const <String, Object?>{},
        busy: false,
        blocked: blocked,
      ),
      IncomingCallDecision.declineBlocked,
    );
  });
}

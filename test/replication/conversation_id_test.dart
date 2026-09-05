import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/replication/conversation_id.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/replication/replication_authorization.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
const carol = 'ORBIT-CCCCCCCCCCCCCCCC';

void main() {
  test('conversation id is order-independent and domain-separated', () {
    final ab = conversationIdForPeers(alice, bob);
    final ba = conversationIdForPeers(bob, alice);
    final ac = conversationIdForPeers(alice, carol);
    expect(ab, ba);
    expect(ab, isNot(ac));
    expect(ab, hasLength(64));
    expect(ab, isNot(alice));
    expect(ab, isNot(bob));
  });

  test('A→B and B→A records are accepted; Carol is rejected', () {
    final cid = conversationIdForPeers(alice, bob);
    final record = JournalRecord(
      seq: 1,
      writerDeviceId: 'dev-a',
      kind: ReplicationEventKind.messageEnvelopeCreated,
      fields: <String, Object?>{
        'conversationId': cid,
        'encryptedEnvelope': <int>[1],
      },
    );
    expect(
      recordMayReplicateTo(
        record,
        authenticatedPeerId: bob,
        selfPeerId: alice,
        peerIsOwnDevice: false,
      ),
      isTrue,
    );
    expect(
      recordMayReplicateTo(
        record,
        authenticatedPeerId: alice,
        selfPeerId: bob,
        peerIsOwnDevice: false,
      ),
      isTrue,
    );
    expect(
      recordMayReplicateTo(
        record,
        authenticatedPeerId: carol,
        selfPeerId: alice,
        peerIsOwnDevice: false,
      ),
      isFalse,
    );
  });

  test('cross-conversation replay is rejected', () {
    final other = conversationIdForPeers(alice, carol);
    expect(
      frameMayAcceptFrom(
        ReplicationEventKind.messageEnvelopeCreated,
        <String, Object?>{'conversationId': other},
        authenticatedPeerId: bob,
        selfPeerId: alice,
        peerIsOwnDevice: false,
      ),
      isFalse,
    );
  });

  test('owner multi-device does not open a contact conversation', () {
    final device = JournalRecord(
      seq: 1,
      writerDeviceId: 'phone-2',
      kind: ReplicationEventKind.deviceAuthorized,
      fields: <String, Object?>{
        'deviceId': 'phone-2',
        'ownerPeerId': alice,
      },
    );
    expect(
      recordMayReplicateTo(
        device,
        authenticatedPeerId: bob,
        selfPeerId: alice,
        peerIsOwnDevice: false,
      ),
      isFalse,
    );
    expect(
      recordMayReplicateTo(
        device,
        authenticatedPeerId: 'alice-phone-2',
        selfPeerId: alice,
        peerIsOwnDevice: true,
      ),
      isTrue,
    );
  });
}

// Phase 10 leftover: UI authorize must journal via ConnectionsNotifier
// → DualStackBridge.authorizeDevice. transportPeerId is derived locally
// from the Noise public key; the QR signed payload is unchanged.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/devices/device_link.dart';

void main() {
  test('connections_notifier.dart defines authorizeLinkedDevice', () {
    final src = File('lib/state/connections_notifier.dart').readAsStringSync();
    expect(src, contains('authorizeLinkedDevice'));
  });

  test('authorizeLinkedDevice journals via authorizeDevice and derives id', () {
    final src = File('lib/state/connections_notifier.dart').readAsStringSync();
    final body = src
        .split('void authorizeLinkedDevice')[1]
        .split('Future<int> restoreReadModelFromJournal')[0];
    expect(body, contains('authorizeDevice'));
    expect(body, contains('transportPeerIdFromPublicKey'));
    expect(body, contains('://'));
  });

  test('device_link_page routes authorize through ConnectionsNotifier', () {
    final src = File('lib/ui/profile/device_link_page.dart').readAsStringSync();
    expect(src, contains('authorizeLinkedDevice'));
    expect(src, isNot(contains('deviceRegistry.authorize')));
  });

  test('_persistProjectedNonMessage refuses URL-shaped ids', () {
    final src = File('lib/state/connections_notifier.dart').readAsStringSync();
    expect(src, contains('_persistProjectedNonMessage'));
    final persist = src
        .split('Future<void> _persistProjectedNonMessage')[1]
        .split('Future<void> setPeerBlockedAndJournal')[0];

    final contactBlocked = persist
        .split('ReplicationEventKind.contactBlocked')[1]
        .split('ReplicationEventKind.attachmentPublished')[0];
    expect(contactBlocked, contains('://'));

    final expired = persist
        .split('ReplicationEventKind.attachmentExpired')[1]
        .split('ReplicationEventKind.roomMembershipChanged')[0];
    expect(expired, contains('://'));

    final room = persist
        .split('ReplicationEventKind.roomMembershipChanged')[1]
        .split('ReplicationEventKind.messageEnvelopeCreated')[0];
    expect(room, contains('://'));
  });

  test('transportPeerIdFromPublicKey does not need a Riverpod widget', () {
    final id = transportPeerIdFromPublicKey(List<int>.filled(32, 3));
    expect(id, matches(RegExp(r'^ORBIT-[0-9A-F]{16}$')));
    expect(id.contains('://'), isFalse);
    expect(
      () => transportPeerIdFromPublicKey(const <int>[]),
      throwsArgumentError,
    );
  });
}

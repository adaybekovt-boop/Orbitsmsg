// P1-4: the 1:1 native-attachment jail lookup is keyed by the
// AUTHENTICATED transport peer (remoteId), never the spoofable payload
// `from`. A sender-less legacy layout is not resolved at all.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/incoming_paths.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/messaging/message_protocol.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

ReliableInboundCtx _ctx({
  required List<JsonMap> persisted,
  required List<JsonMap> acks,
}) {
  return ReliableInboundCtx(
    selfPeerId: 'ORBIT-SELFSELFSELFSELF',
    localProfile: () => null,
    seenMsgIds: <String>{},
    processingMsgIds: <String>{},
    persistInbound: (_, msg) async {
      persisted.add(msg);
      return InboundPersistResult.committed;
    },
    pushMessage: (_, msg) async {
      persisted.add(msg);
      return InboundPersistResult.committed;
    },
    updateMessage: (_, __, ___) {},
    setProfilesByPeer: (_) {},
    setMessagesByPeer: (_) {},
    upsertPeer: (_, __) {},
    queueAckStatus: (_, __) {},
    sendEncrypted: acks.add,
    notifyNewMessage:
        ({required String from, required String text, required String tag}) {},
    hapticMessage: () {},
    playReceiveSound: () {},
    isAppInForeground: () => false,
  );
}

void main() {
  late OrbitsDatabase database;

  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 3 + 7) & 0xff));
  });

  tearDown(() async {
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  test('B cannot bind a native attachment to A jail via payload from',
      () async {
    const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
    const localId = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
    final base = Directory.systemTemp;
    final aliceDir = resolveIncomingDir(
      base: base,
      trustedSenderId: alice,
      localTransferId: localId,
    );
    aliceDir.createSync(recursive: true);
    addTearDown(() {
      if (aliceDir.existsSync()) aliceDir.deleteSync(recursive: true);
    });
    blobFile(aliceDir).writeAsBytesSync(const [1, 2, 3]);
    metaFile(aliceDir).writeAsStringSync(
      jsonEncode({
        'trustedSender': trustedSenderDirName(alice),
        'externalTransferId': localId,
        'localTransferId': localId,
        'fileName': 'secret.jpg',
      }),
    );

    final persisted = <JsonMap>[];
    final acks = <JsonMap>[];
    final ctx = _ctx(persisted: persisted, acks: acks);

    await dispatchReliablePlaintext(
      {
        'type': 'msg',
        'id': 'msg-spoof-1',
        'from': alice,
        'text': '',
        'msgType': 'file',
        'ts': 1,
        'attachment': {
          'native': true,
          'transferId': localId,
          'name': 'secret.jpg',
          'mime': 'image/jpeg',
          'kind': 'image',
        },
      },
      (_) {},
      bob,
      ctx,
    );

    expect(persisted, hasLength(1));
    expect(persisted.single['from'], bob);
    final attachment = persisted.single['attachment'] as Map;
    expect(attachment['missing'], isTrue);
    expect(attachment.containsKey('path'), isFalse);
    expect(await db.getFileBlob('msg-spoof-1'), isNull);
  });
}

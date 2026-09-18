import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/incoming_paths.dart';
import 'package:orbits_flutter/attachments/temp_attachment_io.dart';

void main() {
  test('readIncomingTransfer finds native blob by colon chat msgId', () async {
    final base = Directory.systemTemp.createTempSync('orbits-read-colon-');
    addTearDown(() {
      if (base.existsSync()) base.deleteSync(recursive: true);
    });
    const sender = 'ORBIT-AAAAAAAAAAAAAAAA';
    const localId = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
    const chatMsgId = 'ORBIT-AAAAAAAAAAAAAAAA:1700000000000:xy';
    final dir = resolveIncomingDir(
      base: base,
      trustedSenderId: sender,
      localTransferId: localId,
    );
    dir.createSync(recursive: true);
    blobFile(dir).writeAsBytesSync(const [7, 8, 9]);
    metaFile(dir).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'trustedSender': trustedSenderDirName(sender),
        'externalTransferId': sanitizeTransferId(chatMsgId),
        'localTransferId': localId,
        'fileName': 'photo.jpg',
      }),
    );

    final bytes = await readIncomingTransfer(
      transferId: chatMsgId,
      name: 'photo.jpg',
      trustedSenderId: sender,
      base: base,
    );
    expect(bytes, const [7, 8, 9]);
  });

  test('readIncomingTransfer still finds an already-safe local id', () async {
    final base = Directory.systemTemp.createTempSync('orbits-read-local-');
    addTearDown(() {
      if (base.existsSync()) base.deleteSync(recursive: true);
    });
    const sender = 'ORBIT-AAAAAAAAAAAAAAAA';
    const localId = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
    final dir = resolveIncomingDir(
      base: base,
      trustedSenderId: sender,
      localTransferId: localId,
    );
    dir.createSync(recursive: true);
    blobFile(dir).writeAsBytesSync(const [1]);

    final bytes = await readIncomingTransfer(
      transferId: localId,
      name: 'blob',
      trustedSenderId: sender,
      base: base,
    );
    expect(bytes, const [1]);
  });
}

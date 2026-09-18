import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/incoming_paths.dart';

void main() {
  test('rejects traversal, absolute, drive, encoded, and NUL fragments', () {
    expect(() => assertSafePathFragment('../x', label: 'id'), throwsStateError);
    expect(
      () => assertSafePathFragment('..\\x', label: 'id'),
      throwsStateError,
    );
    expect(
      () => assertSafePathFragment('/tmp/x', label: 'id'),
      throwsStateError,
    );
    expect(
      () => assertSafePathFragment('C:\\Windows', label: 'id'),
      throwsStateError,
    );
    expect(() => assertSafePathFragment('a/b', label: 'id'), throwsStateError);
    expect(
      () => assertSafePathFragment('%2e%2e', label: 'id'),
      throwsStateError,
    );
    expect(
      () => assertSafePathFragment('x\u0000y', label: 'id'),
      throwsStateError,
    );
  });

  test('resolved incoming dir stays inside the incoming root', () {
    final base = Directory.systemTemp.createTempSync('orbits-path-');
    addTearDown(() {
      if (base.existsSync()) base.deleteSync(recursive: true);
    });
    final dir = resolveIncomingDir(
      base: base,
      trustedSenderId: 'ORBIT-AAAAAAAAAAAAAAAA',
      localTransferId: 'localid01',
    );
    assertInsideRoot(incomingRoot(base), dir);
    expect(dir.path.contains('orbits-incoming'), isTrue);
    expect(dir.path.contains('..'), isFalse);
  });

  test('lookupIncomingBlob finds canonical, meta, and legacy layouts', () {
    final base = Directory.systemTemp.createTempSync('orbits-lookup-');
    addTearDown(() {
      if (base.existsSync()) base.deleteSync(recursive: true);
    });
    const sender = 'ORBIT-AAAAAAAAAAAAAAAA';
    const localId = 'localid01';
    const externalId = 'ext-transfer-1';
    final canonical = resolveIncomingDir(
      base: base,
      trustedSenderId: sender,
      localTransferId: localId,
    );
    canonical.createSync(recursive: true);
    blobFile(canonical).writeAsBytesSync(const [1, 2, 3]);
    metaFile(canonical).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'trustedSender': trustedSenderDirName(sender),
        'externalTransferId': externalId,
        'localTransferId': localId,
      }),
    );

    expect(
      lookupIncomingBlob(
        base: base,
        trustedSenderId: sender,
        localTransferId: localId,
      )?.readAsBytesSync(),
      const [1, 2, 3],
    );
    expect(
      lookupIncomingBlob(
        base: base,
        trustedSenderId: sender,
        externalTransferId: externalId,
      )?.readAsBytesSync(),
      const [1, 2, 3],
    );

    final legacyDir = Directory(
      '${incomingRoot(base).path}${Platform.pathSeparator}legacyid01',
    );
    legacyDir.createSync(recursive: true);
    File(
      '${legacyDir.path}${Platform.pathSeparator}photo.jpg',
    ).writeAsBytesSync(const [9, 8, 7]);
    // The sender-less legacy layout is no longer resolved: a remote
    // peer must not reach another sender's jail through it.
    expect(
      lookupIncomingBlob(
        base: base,
        trustedSenderId: sender,
        externalTransferId: 'legacyid01',
      ),
      isNull,
    );
    expect(
      lookupIncomingBlob(
        base: base,
        externalTransferId: 'legacyid01',
      ),
      isNull,
    );
  });

  test('colon chat msgId finds canonical blob via sanitized external id', () {
    final base = Directory.systemTemp.createTempSync('orbits-lookup-colon-');
    addTearDown(() {
      if (base.existsSync()) base.deleteSync(recursive: true);
    });
    const sender = 'ORBIT-AAAAAAAAAAAAAAAA';
    const localId = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
    const chatMsgId = 'ORBIT-AAAAAAAAAAAAAAAA:1700000000000:abcd';
    final canonical = resolveIncomingDir(
      base: base,
      trustedSenderId: sender,
      localTransferId: localId,
    );
    canonical.createSync(recursive: true);
    blobFile(canonical).writeAsBytesSync(const [4, 5, 6]);
    metaFile(canonical).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'trustedSender': trustedSenderDirName(sender),
        'externalTransferId': sanitizeTransferId(chatMsgId),
        'localTransferId': localId,
      }),
    );

    expect(sanitizeTransferId(chatMsgId), isNot(contains(':')));
    expect(
      lookupIncomingBlob(
        base: base,
        trustedSenderId: sender,
        localTransferId: chatMsgId,
      ),
      isNull,
    );
    expect(
      lookupIncomingBlob(
        base: base,
        trustedSenderId: sender,
        externalTransferId: chatMsgId,
      )?.readAsBytesSync(),
      const [4, 5, 6],
    );
    expect(
      lookupIncomingBlob(
        base: base,
        trustedSenderId: sender,
        externalTransferId: sanitizeTransferId(chatMsgId),
      )?.readAsBytesSync(),
      const [4, 5, 6],
    );
  });

  test('lookupIncomingBlob refuses traversal and directory aliases', () {
    final base = Directory.systemTemp.createTempSync('orbits-lookup-bad-');
    addTearDown(() {
      if (base.existsSync()) base.deleteSync(recursive: true);
    });
    expect(
      lookupIncomingBlob(
        base: base,
        trustedSenderId: '../escape',
        localTransferId: 'localid01',
      ),
      isNull,
    );
    expect(
      lookupIncomingBlob(
        base: base,
        trustedSenderId: 'ORBIT-AAAAAAAAAAAAAAAA',
        externalTransferId: '../escape',
      ),
      isNull,
    );
    expect(
      lookupIncomingBlob(
        base: base,
        trustedSenderId: 'ORBIT-AAAAAAAAAAAAAAAA',
        externalTransferId: 'safeid01',
      ),
      isNull,
    );
  });
}

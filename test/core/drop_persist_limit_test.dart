// R6-04 — Drop advertised limit matches saveFileBlob (12 MiB).
// A 13 MiB transfer must not ACK / persist / complete.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbits_flutter/core/base64_helpers.dart';
import 'package:orbits_flutter/core/file_limits.dart';
import 'package:orbits_flutter/core/orbits_drop.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/state/drop_provider.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

void main() {
  late OrbitsDatabase database;

  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i + 3) & 0xff));
  });

  tearDown(() async {
    clearVaultKek();
    await closeOrbitsDatabase();
  });

  test('Drop and chat advertise the same 12 MiB raw cap', () {
    expect(kMaxDropFileBytes, kMaxFileRawBytes);
    expect(kMaxFileRawBytes, 12 * 1024 * 1024);
  });

  test('13 MiB file-start is rejected and never ACKs', () async {
    final replies = <Object>[];
    var started = false;
    String? failure;
    final receiver = DropEngine(
      persistIncoming: (_, __) async => true,
      onIncomingStart: (_) => started = true,
      onFailed: (_, __, reason) => failure = reason,
      onReply: (_, pkt) => replies.add(pkt),
    );
    await receiver.handleInbound(
      <String, Object?>{
        'type': 'file-start',
        'fileId': bytesToBase64(Uint8List(16)),
        'name': 'huge.bin',
        'size': 13 * 1024 * 1024,
      },
      peerId: 'ORBIT-ALICE',
    );
    expect(started, isFalse);
    expect(receiver.incomingTransferCount, 0);
    expect(replies, isNotEmpty, reason: 'oversize start must NACK (R6-10)');
    expect((replies.first as Map)['type'], 'file-nack');
    expect(failure, isNotNull);
  });

  test('saveFileBlob refuses 13 MiB and stores nothing', () async {
    final bytes = Uint8List(13 * 1024 * 1024);
    expect(await db.saveFileBlob('drop-too-big', bytes), isFalse);
    expect(await db.getFileBlob('drop-too-big'), isNull);
  });

  test('persistIncomingDropFile of 13 MiB is false and leaves no blob',
      () async {
    const fileId = 'aabbccddeeff00112233445566778899';
    const meta = DropFileMeta(
      fileId: fileId,
      name: 'huge.bin',
      size: 13 * 1024 * 1024,
      mime: 'application/octet-stream',
      hash: '',
      totalChunks: 1,
    );
    final ok = await persistIncomingDropFile(
      meta,
      Uint8List(13 * 1024 * 1024),
    );
    expect(ok, isFalse);
    expect(await db.getFileBlob(dropBlobId(fileId)), isNull);
  });

  test('saveFileBlob under the 12 MiB cap is kept', () async {
    final bytes = Uint8List(64 * 1024);
    bytes[0] = 0xab;
    expect(await db.saveFileBlob('drop-ok', bytes), isTrue);
    final got = await db.getFileBlob('drop-ok');
    expect(got, isNotNull);
    expect((got!['blob'] as List<int>).length, 64 * 1024);
    expect((got['blob'] as List<int>).first, 0xab);
  });
}

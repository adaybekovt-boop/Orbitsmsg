import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/attachment_keys.dart';
import 'package:orbits_flutter/attachments/file_transfer_session.dart';
import 'package:orbits_flutter/attachments/incoming_paths.dart';
import 'package:orbits_flutter/attachments/resumable_blob.dart';
import 'package:orbits_flutter/transport/transport_api.dart';

void _wire(FileTransferCoordinator a, FileTransferCoordinator b) {
  a.send = (peer, bytes) async => b.handleInbound('alice', bytes);
  b.send = (peer, bytes) async => a.handleInbound('bob', bytes);
  a.announceKey = (peer, id, key, meta) async {
    b.keys!.accept('alice', id, key);
  };
  b.announceKey = (peer, id, key, meta) async {
    a.keys!.accept('bob', id, key);
  };
}

Future<(File, String)> _tempFile(int size, {int seed = 7}) async {
  final dir = await Directory.systemTemp.createTemp('orbits-att-');
  final bytes = Uint8List.fromList(
    List<int>.generate(size, (i) => (i * seed) % 251),
  );
  final file = File('${dir.path}/payload.bin');
  await file.writeAsBytes(bytes, flush: true);
  return (file, sha256.convert(bytes).toString());
}

void main() {
  test('A and B share a random attachment key, not the discovery secret', () {
    final secretsA = List<int>.generate(32, (i) => i + 1);
    final secretsB = List<int>.generate(32, (i) => 32 - i);
    expect(secretsA, isNot(secretsB));
    final storeA = AttachmentKeyStore();
    final storeB = AttachmentKeyStore();
    final key = storeA.issue('bob', 'xfer-1');
    storeB.accept('alice', 'xfer-1', key);
    expect(storeA.require('bob', 'xfer-1'), key);
    expect(storeB.require('alice', 'xfer-1'), key);
    expect(key, isNot(secretsA));
    expect(key, isNot(secretsB));
    expect(key.length, 32);
  });

  test('C cannot decrypt a file keyed for B', () {
    final store = AttachmentKeyStore();
    final key = store.issue('bob', 'xfer-1');
    store.issue('carol', 'xfer-1');
    final sealed = encryptAttachmentChunk(
      utf8.encode('secret-file'),
      key,
      0,
      fileId: 'xfer-1',
      totalBytes: 11,
    );
    expect(
      () => decryptAttachmentChunk(
        sealed,
        store.require('carol', 'xfer-1'),
        0,
        fileId: 'xfer-1',
        totalBytes: 11,
      ),
      throwsStateError,
    );
  });

  test('chunk swap, reorder, replay, and wrong transferId fail closed', () {
    final key = List<int>.generate(32, (i) => i + 3);
    final a = encryptAttachmentChunk(
      utf8.encode('aaaa'),
      key,
      0,
      fileId: 't1',
      totalBytes: 8,
    );
    final b = encryptAttachmentChunk(
      utf8.encode('bbbb'),
      key,
      1,
      fileId: 't1',
      totalBytes: 8,
      offset: 4,
    );
    expect(
      () => decryptAttachmentChunk(b, key, 0, fileId: 't1', totalBytes: 8),
      throwsStateError,
    );
    expect(
      () => decryptAttachmentChunk(a, key, 1, fileId: 't1', totalBytes: 8, offset: 4),
      throwsStateError,
    );
    expect(
      decryptAttachmentChunk(a, key, 0, fileId: 't1', totalBytes: 8),
      utf8.encode('aaaa'),
    );
    expect(
      () => decryptAttachmentChunk(a, key, 0, fileId: 'other', totalBytes: 8),
      throwsStateError,
    );
    final mutated = Uint8List.fromList(b);
    mutated[0] ^= 0x01;
    expect(
      () => decryptAttachmentChunk(
        mutated,
        key,
        1,
        fileId: 't1',
        totalBytes: 8,
        offset: 4,
      ),
      throwsStateError,
    );
  });

  test('wrong sender on attachment-key message is ignored', () {
    final store = AttachmentKeyStore();
    final key = List<int>.filled(32, 9);
    final ok = tryAcceptAttachmentKeyMessage(
      store,
      'bob',
      attachmentKeyMessage(
        transferId: 't1',
        key: key,
        sender: 'carol',
        receiver: 'alice',
        name: 'x',
        size: 1,
        sha256hex: 'aa',
      ),
    );
    expect(ok, isFalse);
    expect(() => store.require('bob', 't1'), throwsStateError);
  });

  test('waiter is registered before emit so a sync response is not lost', () async {
    final a = FileTransferCoordinator()..keys = AttachmentKeyStore();
    final b = FileTransferCoordinator()
      ..keys = AttachmentKeyStore()
      ..incomingBase = Directory.systemTemp.createTempSync('orbits-in-');
    addTearDown(() {
      if (b.incomingBase.existsSync()) {
        b.incomingBase.deleteSync(recursive: true);
      }
    });
    a.fileKeyFor = (peer, id) => a.keys!.require(peer, id);
    b.fileKeyFor = (peer, id) => b.keys!.require(peer, id);
    _wire(a, b);
    final (src, digest) = await _tempFile(128);
    addTearDown(() => src.parent.deleteSync(recursive: true));
    await a.sendPath(
      'bob',
      TransportFileDescriptor(
        path: src.path,
        sizeBytes: 128,
        fileName: 'payload.bin',
        transferId: 'syncwait01',
      ),
    );
    expect(b.keys!.has('alice', 'syncwait01'), isTrue);
  });

  test('Alice and Carol with the same transferId stay isolated', () async {
    final incoming = Directory.systemTemp.createTempSync('orbits-iso-');
    addTearDown(() {
      if (incoming.existsSync()) incoming.deleteSync(recursive: true);
    });
    late final FileTransferCoordinator recv;
    recv = FileTransferCoordinator();
    recv.keys = AttachmentKeyStore();
    recv.incomingBase = incoming;
    recv.fileKeyFor = (peer, id) => recv.keys!.require(peer, id);
    recv.send = (_, __) async {};
    final aliceKey = recv.keys!.issue('alice', 'same-id');
    final carolKey = recv.keys!.issue('carol', 'same-id');
    expect(aliceKey, isNot(carolKey));

    recv.handleInbound(
      'alice',
      utf8.encode(
        jsonEncode({
          'type': 'file-offer',
          'protocol': kFileTransferProtocol,
          'transferId': 'same-id',
          'name': 'photo.jpg',
          'size': 4,
          'sha256': sha256.convert(utf8.encode('AAAA')).toString(),
        }),
      ),
    );
    recv.handleInbound(
      'carol',
      utf8.encode(
        jsonEncode({
          'type': 'file-offer',
          'protocol': kFileTransferProtocol,
          'transferId': 'same-id',
          'name': 'photo.jpg',
          'size': 8,
          'sha256': sha256.convert(utf8.encode('CCCCCCCC')).toString(),
        }),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final aliceDir = Directory(
      '${incomingRoot(incoming).path}${Platform.pathSeparator}${trustedSenderDirName('alice')}',
    );
    final carolDir = Directory(
      '${incomingRoot(incoming).path}${Platform.pathSeparator}${trustedSenderDirName('carol')}',
    );
    expect(aliceDir.existsSync(), isTrue);
    expect(carolDir.existsSync(), isTrue);
    expect(aliceDir.listSync(), hasLength(1));
    expect(carolDir.listSync(), hasLength(1));
    expect(aliceDir.path, isNot(carolDir.path));
  });

  test('10 MiB transfer SHA-256 matches', () async {
    final incoming = Directory.systemTemp.createTempSync('orbits-10m-');
    addTearDown(() {
      if (incoming.existsSync()) incoming.deleteSync(recursive: true);
    });
    final a = FileTransferCoordinator()..keys = AttachmentKeyStore();
    final b = FileTransferCoordinator()
      ..keys = AttachmentKeyStore()
      ..incomingBase = incoming;
    a.fileKeyFor = (peer, id) => a.keys!.require(peer, id);
    b.fileKeyFor = (peer, id) => b.keys!.require(peer, id);
    _wire(a, b);
    final dropped = <Map<String, Object?>>[];
    b.onDrop = (peer, packet) {
      if (packet is Map) dropped.add(Map<String, Object?>.from(packet));
    };
    final (src, digest) = await _tempFile(10 * 1024 * 1024, seed: 11);
    addTearDown(() => src.parent.deleteSync(recursive: true));
    await a.sendPath(
      'bob',
      TransportFileDescriptor(
        path: src.path,
        sizeBytes: 10 * 1024 * 1024,
        fileName: 'ten.bin',
        transferId: 'tenmegfile00001',
      ),
    );
    expect(dropped.single['sha256'], digest);
    expect(dropped.single['size'], 10 * 1024 * 1024);
    expect(File(dropped.single['path'] as String).existsSync(), isTrue);
  });

  test('50 MiB transfer SHA-256 matches', () async {
    final incoming = Directory.systemTemp.createTempSync('orbits-50m-');
    addTearDown(() {
      if (incoming.existsSync()) incoming.deleteSync(recursive: true);
    });
    final a = FileTransferCoordinator()..keys = AttachmentKeyStore();
    final b = FileTransferCoordinator()
      ..keys = AttachmentKeyStore()
      ..incomingBase = incoming;
    a.fileKeyFor = (peer, id) => a.keys!.require(peer, id);
    b.fileKeyFor = (peer, id) => b.keys!.require(peer, id);
    _wire(a, b);
    final dropped = <Map<String, Object?>>[];
    b.onDrop = (peer, packet) {
      if (packet is Map) dropped.add(Map<String, Object?>.from(packet));
    };
    final (src, digest) = await _tempFile(50 * 1024 * 1024, seed: 13);
    addTearDown(() => src.parent.deleteSync(recursive: true));
    await a.sendPath(
      'bob',
      TransportFileDescriptor(
        path: src.path,
        sizeBytes: 50 * 1024 * 1024,
        fileName: 'fifty.bin',
        transferId: 'fiftymegfile0001',
      ),
    );
    expect(dropped.single['sha256'], digest);
    expect(dropped.single['size'], 50 * 1024 * 1024);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

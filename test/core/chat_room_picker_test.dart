import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/path_byte_stream.dart';
import 'package:orbits_flutter/core/path_byte_stream_stub.dart' as pathStub;
import 'package:orbits_flutter/core/read_picked_bytes.dart';
import 'package:orbits_flutter/core/read_picked_bytes_stub.dart' as stub;

void main() {
  test('chat and room native pickers do not force picker bytes', () {
    final chat = File('lib/pages/chat_view_page.dart').readAsStringSync();
    expect(chat, contains('withData: kIsWeb'));
    expect(chat, isNot(contains('withData: true')));
    expect(chat, contains('readPickedBytes'));
    expect(chat, contains('sendFileFromPath'));
    expect(chat, contains('kMaxNativeAttachBytes'));
    expect(chat, contains('kMaxPeerJsFileRawBytes'));
    expect(chat, contains('canUseNative'));
    expect(chat, contains('materializePickedLocalPath'));
    expect(chat, contains('withReadStream: !kIsWeb'));
    expect(chat, isNot(contains('localPathLength')));
    expect(chat, isNot(contains("File(pf.path!).readAsBytes")));
    expect(chat, isNot(contains("import 'dart:io'")));

    final room = File('lib/pages/room_chat_page.dart').readAsStringSync();
    expect(room, contains('withData: kIsWeb'));
    expect(room, isNot(contains('withData: true')));
    expect(room, contains('readPickedBytes'));
    expect(room, contains('materializePickedLocalPath'));
    expect(room, contains('withReadStream: !kIsWeb'));
    expect(room, contains('sendRoomFileFromPath'));
    expect(room, isNot(contains('localPathLength')));
    expect(room, isNot(contains("import 'dart:io'")));
    expect(room, isNot(contains('room_crypto.dart')));

    final io = File('lib/core/read_picked_bytes_io.dart').readAsStringSync();
    expect(io, contains('RandomAccessFile'));
    expect(io, contains('.length()'));
    expect(io, isNot(contains('readAsBytes')));

    expect(
      File('lib/core/path_byte_stream.dart').readAsStringSync(),
      contains('openLocalPathByteStream'),
    );
    expect(
      File('lib/core/path_byte_stream_io.dart').readAsStringSync(),
      contains('openRead'),
    );
    expect(
      File('lib/core/path_byte_stream_io.dart').readAsStringSync(),
      isNot(contains('readAsBytes')),
    );
    expect(
      File('lib/state/messaging_notifier.dart').readAsStringSync(),
      contains('_readyToShip'),
    );
    expect(
      File('lib/state/messaging_notifier.dart').readAsStringSync(),
      contains('hasReliable'),
    );
    expect(
      File('lib/state/messaging_notifier.dart').readAsStringSync(),
      contains('sendChatAttachmentFromPath'),
    );
    expect(
      File('lib/state/messaging_notifier.dart').readAsStringSync(),
      contains('writeBytesToTempPath'),
    );
    expect(
      File('lib/state/messaging_notifier.dart').readAsStringSync(),
      contains('_flushChunkedNativeVoice'),
    );
    expect(
      File('lib/core/path_byte_stream.dart').readAsStringSync(),
      contains('writeBytesToTempPath'),
    );
    expect(
      File('lib/core/path_byte_stream.dart').readAsStringSync(),
      contains('openInboundCipherPath'),
    );
    expect(
      File('lib/messaging/message_protocol.dart').readAsStringSync(),
      contains('_assembleChunkedVoice'),
    );
    expect(
      File('lib/state/messaging_notifier.dart').readAsStringSync(),
      contains('saveFileBlobFromPath'),
    );
    expect(
      File('lib/state/messaging_notifier.dart').readAsStringSync(),
      contains('nativeAttachFileKeyFromPayload'),
    );
    expect(
      File('lib/storage/db.dart').readAsStringSync(),
      contains('saveFileBlobFromPath'),
    );
    expect(
      File('lib/storage/db.dart').readAsStringSync(),
      contains('kMaxNativeAttachBytes'),
    );
    expect(
      File('lib/core/path_byte_stream.dart').readAsStringSync(),
      contains('xorCipherPathToPlaintextFile'),
    );
    expect(
      File('lib/core/path_byte_stream.dart').readAsStringSync(),
      contains('copyLocalPathToStableFile'),
    );
    expect(
      File('lib/core/attachment_store.dart').readAsStringSync(),
      contains('persistLocalAttachmentPath'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('decryptInboundAttachmentPath'),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('decryptInboundAttachmentPath'),
    );
    expect(
      File('lib/messaging/message_protocol.dart').readAsStringSync(),
      contains('assembleNativeAttachmentPath'),
    );
    expect(
      File('lib/ui/chat/file_tile.dart').readAsStringSync(),
      contains('_loadLocalPath'),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('xorPlaintextPathToCipherFile'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('sendAttachmentCipherPath'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      isNot(contains("import 'dart:io'")),
    );
    expect(
      File('lib/ui/profile/profile_edit_page.dart').readAsStringSync(),
      contains('withData: kIsWeb'),
    );
    expect(
      File('lib/ui/profile/profile_edit_page.dart').readAsStringSync(),
      isNot(contains('withData: true')),
    );
    expect(
      File('lib/ui/profile/profile_edit_page.dart').readAsStringSync(),
      contains('readPickedBytes'),
    );
    expect(
      File('lib/ui/profile/profile_edit_page.dart').readAsStringSync(),
      isNot(contains("import 'dart:io'")),
    );
  });

  test('native path read stats size before loading bytes', () async {
    final dir = Directory.systemTemp.createTempSync('orbits-pick-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final small = File('${dir.path}${Platform.pathSeparator}ok.bin')
      ..writeAsBytesSync(const <int>[1, 2, 3, 4]);
    final huge = File('${dir.path}${Platform.pathSeparator}huge.bin')
      ..writeAsBytesSync(List<int>.filled(64, 9));

    final ok = await readPickedBytes(
      PlatformFile(name: 'ok.bin', size: 4, path: small.path),
      maxRawBytes: 16,
    );
    expect(ok.tooLarge, isFalse);
    expect(ok.bytes, Uint8List.fromList(const [1, 2, 3, 4]));

    final refused = await readPickedBytes(
      PlatformFile(name: 'huge.bin', size: 64, path: huge.path),
      maxRawBytes: 16,
    );
    expect(refused.tooLarge, isTrue);
    expect(refused.bytes, isNull);
    expect(refused.sizeBytes, 64);
  });

  test('web stub uses picker bytes and still enforces the cap', () async {
    final ok = await stub.readPickedBytes(
      PlatformFile(
        name: 'a.bin',
        size: 2,
        bytes: Uint8List.fromList(const [9, 8]),
      ),
      maxRawBytes: 16,
    );
    expect(ok.bytes, Uint8List.fromList(const [9, 8]));

    final refused = await stub.readPickedBytes(
      PlatformFile(
        name: 'b.bin',
        size: 8,
        bytes: Uint8List.fromList(List<int>.filled(8, 1)),
      ),
      maxRawBytes: 4,
    );
    expect(refused.tooLarge, isTrue);
    expect(refused.bytes, isNull);
  });

  test('materializePickedLocalPath reuses a real path and writes bytes',
      () async {
    final existing = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}orbits-pick-src.bin',
    );
    await existing.writeAsBytes(const [1, 2, 3, 4], flush: true);
    addTearDown(() async {
      try {
        await existing.delete();
      } catch (_) {}
    });
    final fromPath = await materializePickedLocalPath(
      PlatformFile(name: 'src.bin', size: 4, path: existing.path),
      maxBytes: 16,
    );
    expect(fromPath.tooLarge, isFalse);
    expect(fromPath.path, existing.path);
    expect(fromPath.sizeBytes, 4);

    final fromBytes = await materializePickedLocalPath(
      PlatformFile(
        name: 'mem.bin',
        size: 2,
        bytes: Uint8List.fromList(const [9, 8]),
      ),
      maxBytes: 16,
    );
    expect(fromBytes.tooLarge, isFalse);
    expect(fromBytes.path, isNotNull);
    expect(fromBytes.path!.contains('://'), isFalse);
    expect(File(fromBytes.path!).readAsBytesSync(), [9, 8]);

    final over = await materializePickedLocalPath(
      PlatformFile(
        name: 'big.bin',
        size: 8,
        bytes: Uint8List.fromList(List<int>.filled(8, 1)),
      ),
      maxBytes: 4,
    );
    expect(over.tooLarge, isTrue);
    expect(over.path, isNull);

    expect(
      await stub.materializePickedLocalPath(
        PlatformFile(
          name: 'w.bin',
          size: 2,
          bytes: Uint8List.fromList(const [1, 2]),
        ),
        maxBytes: 16,
      ),
      isA<MaterializedPick>(),
    );
    expect(
      (await stub.materializePickedLocalPath(
        PlatformFile(
          name: 'w.bin',
          size: 2,
          bytes: Uint8List.fromList(const [1, 2]),
        ),
        maxBytes: 16,
      ))
          .path,
      isNull,
    );
  });

  test('writeBytesToTempPath and inbound cipher chunks stay on disk', () async {
    final path = await writeBytesToTempPath(
      const <int>[1, 2, 3, 4],
      fileName: 'voice.bin',
      maxBytes: 16,
    );
    expect(path, isNotNull);
    expect(path!.contains('://'), isFalse);
    expect(File(path).readAsBytesSync(), [1, 2, 3, 4]);
    expect(await writeBytesToTempPath(const <int>[1], maxBytes: 0), isNull);
    expect(
      await writeBytesToTempPath(const <int>[1], fileName: 'fileKey.bin'),
      isNull,
    );

    const fileId = 'voice-chunk-1';
    final cipherPath = await openInboundCipherPath(fileId);
    expect(cipherPath, isNotNull);
    expect(cipherPath!.contains('://'), isFalse);
    expect(await writeInboundCipherChunk(fileId, 0, const <int>[9, 8, 7]), isTrue);
    expect(File(cipherPath).readAsBytesSync().sublist(0, 3), [9, 8, 7]);
    expect(await openInboundCipherPath('https://evil'), isNull);
    expect(await writeInboundCipherChunk('https://evil', 0, const <int>[1]), isFalse);
    expect(await pathStub.openInboundCipherPath('x'), isNull);
    expect(await pathStub.writeInboundCipherChunk('x', 0, const <int>[1]), isFalse);
    expect(await pathStub.writeBytesToTempPath(const <int>[1]), isNull);
  });
}

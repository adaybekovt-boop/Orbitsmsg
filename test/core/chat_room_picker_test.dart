import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/read_picked_bytes.dart';
import 'package:orbits_flutter/core/read_picked_bytes_stub.dart' as stub;

void main() {
  test('chat and room native pickers do not force picker bytes', () {
    final chat = File('lib/pages/chat_view_page.dart').readAsStringSync();
    expect(chat, contains('withData: kIsWeb'));
    expect(chat, isNot(contains('withData: true')));
    expect(chat, contains('readPickedBytes'));
    expect(chat, contains('sendFileFromPath'));
    expect(chat, contains('canUseNative'));
    expect(chat, contains('localPathLength'));
    expect(chat, isNot(contains("File(pf.path!).readAsBytes")));
    expect(chat, isNot(contains("import 'dart:io'")));

    final room = File('lib/pages/room_chat_page.dart').readAsStringSync();
    expect(room, contains('withData: kIsWeb'));
    expect(room, isNot(contains('withData: true')));
    expect(room, contains('readPickedBytes'));
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
}

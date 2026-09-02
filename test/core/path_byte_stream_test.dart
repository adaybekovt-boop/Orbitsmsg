import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/path_byte_stream.dart';
import 'package:orbits_flutter/core/path_byte_stream_stub.dart' as stub;

void main() {
  test('native path stream refuses URLs and yields file bytes', () async {
    expect(localPathLength('https://evil.example/x'), isNull);
    expect(openLocalPathByteStream('https://evil.example/x'), isNull);
    expect(localPathLength('file://tmp/x'), isNull);
    expect(openLocalPathByteStream(''), isNull);

    final dir = Directory.systemTemp.createTempSync('orbits-path-stream-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final file = File('${dir.path}${Platform.pathSeparator}blob.bin')
      ..writeAsBytesSync(const <int>[7, 8, 9]);
    expect(localPathLength(file.path), 3);
    final stream = openLocalPathByteStream(file.path);
    expect(stream, isNotNull);
    final collected = <int>[];
    await for (final piece in stream!) {
      collected.addAll(piece);
    }
    expect(collected, const <int>[7, 8, 9]);
  });

  test('web stub never opens a path', () {
    expect(stub.localPathLength('/tmp/x'), isNull);
    expect(stub.openLocalPathByteStream('/tmp/x'), isNull);
  });
}

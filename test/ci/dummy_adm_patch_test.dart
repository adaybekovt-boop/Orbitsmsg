import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('libwebrtc dummy-ADM patcher rewrites a fixture blob', () async {
    final script = File('tool/ci/patch_libwebrtc_dummy_adm.py');
    expect(script.existsSync(), isTrue);
    final original = _hex(
      '554889e553504889fb488d7df0e8de2adfff'
      '488b45f04889034889d84883c4085b5dc3',
    );
    final padded = Uint8List(original.length + 8)
      ..setAll(0, original)
      ..fillRange(original.length, original.length + 8, 0xCC);
    final dir = Directory.systemTemp.createTempSync('orbits-adm-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final so = File('${dir.path}/libwebrtc.so');
    await so.writeAsBytes(padded, flush: true);
    final result = await Process.run('python3', [script.path, so.path]);
    expect(result.exitCode, 0, reason: '${result.stderr}\n${result.stdout}');
    final patched = await so.readAsBytes();
    expect(
      patched.sublist(9, 14),
      [0xba, 0x0a, 0x00, 0x00, 0x00],
      reason: 'must insert mov \$0xa, %edx (kDummyAudio) after mov %rdi, %rbx',
    );
    expect(patched, isNot(equals(padded)));
  });
}

Uint8List _hex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

final _originalHex =
    '554889e553504889fb488d7df0e8de2adfff'
    '488b45f04889034889d84883c4085b5dc3';

void main() {
  test('libwebrtc dummy-ADM patcher rewrites a fixture blob in place', () async {
    final script = File('tool/ci/patch_libwebrtc_dummy_adm.py');
    expect(script.existsSync(), isTrue);
    final original = _hex(_originalHex);
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
      patched.length,
      padded.length,
      reason: 'in-place rewrite must not shift ELF offsets',
    );
    expect(
      patched.sublist(9, 14),
      [0xba, 0x0a, 0x00, 0x00, 0x00],
      reason: 'must insert mov \$0xa, %edx (kDummyAudio) after mov %rdi, %rbx',
    );
    expect(patched, isNot(equals(padded)));
    expect(_indexOf(_hex(_originalHex), patched), -1);
  });

  test('libwebrtc dummy-ADM patcher refuses a blob without padding', () async {
    final script = File('tool/ci/patch_libwebrtc_dummy_adm.py');
    final original = _hex(_originalHex);
    final dir = Directory.systemTemp.createTempSync('orbits-adm-nopad-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final so = File('${dir.path}/libwebrtc.so');
    await so.writeAsBytes(original, flush: true);
    final result = await Process.run('python3', [script.path, so.path]);
    expect(result.exitCode, isNot(0));
    expect(await so.readAsBytes(), original);
  });

  final officialZip = _firstExisting(<String>[
    '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev/'
        'flutter_webrtc-1.4.1/third_party/downloads/libwebrtc.zip',
  ]);
  if (officialZip != null) {
    test('official flutter-webrtc 1.4.0 linux-x64 zip Dummy-ADM rewrite', () async {
      final script = File('tool/ci/patch_libwebrtc_dummy_adm.py');
      final dir = Directory.systemTemp.createTempSync('orbits-adm-real-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final unzip = await Process.run('unzip', [
        '-p',
        officialZip.path,
        'libwebrtc/lib/linux-x64/libwebrtc.so',
      ], stdoutEncoding: null);
      expect(unzip.exitCode, 0, reason: '${unzip.stderr}');
      final raw = unzip.stdout;
      expect(raw, isA<List<int>>());
      final bytes = raw as List<int>;
      expect(bytes.length, greaterThan(1 << 20));
      final copy = File('${dir.path}/libwebrtc.so');
      await copy.writeAsBytes(bytes, flush: true);
      final sizeBefore = copy.lengthSync();
      final first = await Process.run('python3', [script.path, copy.path]);
      expect(first.exitCode, 0, reason: '${first.stderr}\n${first.stdout}');
      expect(first.stdout.toString(), contains('in-place'));
      expect(copy.lengthSync(), sizeBefore);
      final verify = await Process.run(
        'python3',
        [script.path, '--verify-only', copy.path],
      );
      expect(verify.exitCode, 0, reason: '${verify.stderr}\n${verify.stdout}');
      final again = await Process.run('python3', [script.path, copy.path]);
      expect(again.exitCode, 0);
      expect(again.stdout.toString(), contains('already patched'));
    });
  }
}

File? _firstExisting(List<String> paths) {
  for (final path in paths) {
    final f = File(path);
    if (f.existsSync() && f.lengthSync() > 1 << 20) return f;
  }
  return null;
}

int _indexOf(List<int> needle, List<int> haystack) {
  if (needle.isEmpty || needle.length > haystack.length) return -1;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

Uint8List _hex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/attachment_store.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/core/peer_pins.dart';
import 'package:orbits_flutter/transport/bare_ipc_client.dart';
import 'package:orbits_flutter/transport/bare_runtime.dart';
import 'package:orbits_flutter/transport/bare_stdlib.dart';
import 'package:orbits_flutter/transport/ipc_codec.dart';
import 'package:orbits_flutter/transport/native_transport_host.dart';

class _MissingPinStore implements KeyStore {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw StateError('pin store missing');
  }
}

void main() {
  test(
    'persistLocalAttachmentPath deletes orbits-att-pt temp after copy',
    () async {
      final tmp = Directory.systemTemp.createTempSync('orbits-att-pt-');
      final src = File('${tmp.path}${Platform.pathSeparator}plain.bin')
        ..writeAsBytesSync(const [1, 2, 3, 4]);
      final store = Directory.systemTemp.createTempSync('orbits-store-');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        if (store.existsSync()) store.deleteSync(recursive: true);
      });
      final dest = await persistLocalAttachmentPath(
        src.path,
        storeDir: store.path,
      );
      expect(File(dest).existsSync(), isTrue);
      expect(File(dest).readAsBytesSync(), [1, 2, 3, 4]);
      expect(tmp.existsSync(), isFalse);
    },
  );

  test('wrong-hash Bare binary fixture is refused', () {
    final dir = Directory.systemTemp.createTempSync('bare-hash-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bin = File('${dir.path}${Platform.pathSeparator}bare')
      ..writeAsStringSync('not-the-shipped-binary');
    expect(bin.existsSync(), isTrue);
    expect(bareBinaryAcceptedForSpawn(bin, expectedSha256: '0' * 64), isFalse);
    final honest = sha256.convert(bin.readAsBytesSync()).toString();
    expect(bareBinaryAcceptedForSpawn(bin, expectedSha256: honest), isTrue);
    expect(File('tool/bare/linux-x64/bare').existsSync(), isFalse);
    expect(kBareBinaryShipped, isFalse);
  });

  test('wrong-hash bare_stdlib.zip fixture is refused', () {
    final dir = Directory.systemTemp.createTempSync('stdlib-hash-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final zip = File('${dir.path}${Platform.pathSeparator}bare_stdlib.zip')
      ..writeAsStringSync('not-a-zip');
    expect(
      bareStdlibZipAcceptedForExtract(zip, expectedSha256: '1' * 64),
      isFalse,
    );
  });

  test('IPC codec rejects an oversized declared payload', () {
    expect(kMaxIpcFrameBytes, 4 * 1024 * 1024);
    final header = ByteData(10);
    header.setUint32(0, kOrbitsIpcMagic);
    header.setUint8(4, kOrbitsIpcVersion);
    header.setUint8(5, kIpcRequest);
    header.setUint32(6, kMaxIpcFrameBytes + 1);
    expect(
      () => OrbitsIpcCodec().add(header.buffer.asUint8List()),
      throwsA(isA<FormatException>()),
    );
  });

  test('IPC codec drops a pending buffer that exceeds the cap', () {
    final codec = OrbitsIpcCodec();
    final huge = Uint8List(kMaxIpcFrameBytes + 32);
    expect(() => codec.add(huge), throwsA(isA<FormatException>()));
    final ok = OrbitsIpcCodec.encode(
      const OrbitsIpcMessage(type: kIpcRequest, body: {'id': 1, 'method': 'x'}),
    );
    expect(codec.add(ok), hasLength(1));
  });

  test(
    'BareIpcClient.request times out so ensureStarted cannot stall',
    () async {
      final client = BareIpcClient(write: (_) {});
      await expectLater(
        client.request('start', const {}, const Duration(milliseconds: 30)),
        throwsA(isA<TimeoutException>()),
      );
      await client.close();
    },
  );

  test('two concurrent ensureStarted share one in-flight open', () async {
    var opens = 0;
    final gate = ExclusiveAsync();
    Future<void> open() async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      opens += 1;
    }

    await Future.wait<void>([gate.run(open), gate.run(open)]);
    expect(opens, 1);
  });

  test('missing pin store is an error, not newPin', () async {
    final previous = keyStore();
    setKeyStore(_MissingPinStore());
    addTearDown(() => setKeyStore(previous));
    await expectLater(
      checkPin('ORBIT-AAAAAAAAAAAAAAAA', Uint8List(65)),
      throwsA(isA<StateError>()),
    );
  });
}

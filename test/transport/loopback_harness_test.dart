import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/transport_api.dart';

DeviceBinding _binding(String deviceId) {
  return DeviceBinding(
    version: kDeviceBindingVersion,
    identityPublicKey: Uint8List.fromList(const [1, 2, 3]),
    deviceId: deviceId,
    transportPublicKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
    hypercorePublicKey: Uint8List.fromList(List<int>.generate(32, (i) => 32 - i)),
    capabilities: const ['peerjs-v4'],
    createdAt: 1,
    expiresAt: 2,
    signatureByIdentityKey: Uint8List.fromList(const [9]),
  );
}

void main() {
  final secret = List<int>.generate(32, (i) => i + 3);

  Future<(LoopbackOrbitsTransport, LoopbackOrbitsTransport)> paired() async {
    final pair = loopbackPair();
    final a = pair.$1;
    final b = pair.$2;
    await a.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await b.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await a.publish(_binding('dev-a'));
    await b.publish(_binding('dev-b'));
    final auth = a.events
        .where((e) => e is TransportAuthenticated)
        .cast<TransportAuthenticated>()
        .first;
    await a.connect(
      PeerDescriptor(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await auth.timeout(const Duration(seconds: 2));
    return (a, b);
  }

  test('echoes text on the message channel', () async {
    final (a, b) = await paired();
    final reply = a.events
        .where((e) => e is TransportFrame)
        .cast<TransportFrame>()
        .firstWhere(
      (e) =>
          e.channel == TransportChannel.message &&
          decodeJsonPayload(e.bytes)['type'] == 'harness-echo-reply',
    );
    await a.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      jsonPayload({'type': 'harness-echo', 'id': '1', 'text': 'ping'}),
    );
    final frame = await reply.timeout(const Duration(seconds: 2));
    expect(decodeJsonPayload(frame.bytes)['text'], 'ping');
    await a.stop();
    await b.stop();
  });

  test('carries an opaque wire-v4 hello without parsing it', () async {
    final (a, b) = await paired();
    final seen = b.events
        .where((e) => e is TransportFrame)
        .cast<TransportFrame>()
        .firstWhere((e) => e.channel == TransportChannel.control);
    final hello = jsonPayload({
      'type': 'wireHello',
      'v': 4,
      'pub': 'AAAA',
      'idPub': 'BBBB',
      'sig': 'CCCC',
      'x3dhIk': 'DDDD',
      'x3dhIkSig': 'EEEE',
      'ek': 'FFFF',
      'spkId': 'spk-1',
    });
    await a.send('ORBIT-BBBBBBBBBBBBBBBB', TransportChannel.control, hello);
    final frame = await seen.timeout(const Duration(seconds: 2));
    expect(decodeJsonPayload(frame.bytes)['v'], 4);
    expect(decodeJsonPayload(frame.bytes)['type'], 'wireHello');
    await a.stop();
    await b.stop();
  });

  test('streams a file from a path and verifies the hash', () async {
    final (a, b) = await paired();
    final received = b.events
        .where((e) => e is TransportFrame)
        .cast<TransportFrame>()
        .firstWhere((e) {
      if (e.channel != TransportChannel.attachment) return false;
      return decodeJsonPayload(e.bytes)['type'] == 'harness-file-received';
    });
    final src = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}harness-src.bin',
    );
    await src.writeAsBytes(List<int>.generate(80 * 1024, (i) => i % 251));
    await a.sendFile(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportFileDescriptor(
        path: src.path,
        sizeBytes: src.lengthSync(),
        fileName: 'harness-src.bin',
      ),
    );
    final frame = await received.timeout(const Duration(seconds: 3));
    final body = decodeJsonPayload(frame.bytes);
    final out = File(body['path'] as String);
    expect(out.existsSync(), isTrue);
    expect(out.lengthSync(), src.lengthSync());
    expect(out.readAsBytesSync(), src.readAsBytesSync());
    await a.stop();
    await b.stop();
  });

  test('sendFile resumeOffset out of range is rejected', () async {
    final (a, b) = await paired();
    final src = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}harness-resume.bin',
    );
    await src.writeAsBytes(List<int>.filled(1024, 1));
    await expectLater(
      a.sendFile(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportFileDescriptor(
          path: src.path,
          sizeBytes: 1024,
          resumeOffset: 2048,
        ),
      ),
      throwsStateError,
    );
    await a.stop();
    await b.stop();
  });

  test('suspend blocks send and resume restores it', () async {
    final (a, b) = await paired();
    await a.suspend();
    expect(
      () => a.send(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportChannel.message,
        jsonPayload({'type': 'harness-echo', 'id': 'x', 'text': 'no'}),
      ),
      throwsStateError,
    );
    await a.resume();
    final reply = a.events
        .where((e) => e is TransportFrame)
        .cast<TransportFrame>()
        .firstWhere(
      (e) =>
          e.channel == TransportChannel.message &&
          decodeJsonPayload(e.bytes)['type'] == 'harness-echo-reply',
    );
    await a.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      jsonPayload({'type': 'harness-echo', 'id': 'y', 'text': 'yes'}),
    );
    expect(
      decodeJsonPayload(
        (await reply.timeout(const Duration(seconds: 2))).bytes,
      )['text'],
      'yes',
    );
    await a.stop();
    await b.stop();
  });

  test('path is direct and Noise key is not the identity key', () async {
    final pair = loopbackPair();
    final a = pair.$1;
    final b = pair.$2;
    await a.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await b.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await a.publish(_binding('dev-a'));
    await b.publish(_binding('dev-b'));
    final authFuture = a.events
        .where((e) => e is TransportAuthenticated)
        .cast<TransportAuthenticated>()
        .first;
    await a.connect(
      PeerDescriptor(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    final auth = await authFuture.timeout(const Duration(seconds: 2));
    expect(
      auth.binding.transportPublicKey,
      isNot(equals(auth.binding.identityPublicKey)),
    );
    expect(
      utf8.decode(auth.binding.transportPublicKey),
      isNot(contains('ORBIT-')),
    );
    await a.refreshNetwork();
    await a.stop();
    await b.stop();
  });
}

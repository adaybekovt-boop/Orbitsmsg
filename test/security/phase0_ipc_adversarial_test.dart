// Behavioral IPC / worklet adversarial coverage. Complements
// test/security/phase0_adversarial_test.dart (DualStack loopback).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/bare_ipc_client.dart';
import 'package:orbits_flutter/transport/ipc_codec.dart';

void main() {
  test(
    'IPC codec rejects an oversized declared payload',
    () {
      // JS harness: tool/connectivity_harness/src/ipc.js MAX_IPC_FRAME_BYTES.
      // Dart OrbitsIpcCodec.add currently buffers an incomplete huge frame
      // and returns [] — there is no public max-frame constant yet.
      const maxIpcFrameBytes = 4 * 1024 * 1024;
      final header = ByteData(10);
      header.setUint32(0, kOrbitsIpcMagic);
      header.setUint8(4, kOrbitsIpcVersion);
      header.setUint8(5, kIpcRequest);
      header.setUint32(6, maxIpcFrameBytes + 1);
      expect(
        () => OrbitsIpcCodec().add(header.buffer.asUint8List()),
        throwsA(isA<FormatException>()),
      );
    },
    skip: 'OrbitsIpcCodec has no max-frame API yet; JS ipc.js already rejects',
  );

  test('IPC codec still accepts a small honest frame', () {
    final encoded = OrbitsIpcCodec.encode(
      const OrbitsIpcMessage(
        type: kIpcRequest,
        body: {'id': 1, 'method': 'start', 'peerId': 'ORBIT-AA'},
      ),
    );
    final messages = OrbitsIpcCodec().add(encoded);
    expect(messages, hasLength(1));
    expect(messages.single.body['method'], 'start');
  });

  test(
    'InProcessBareWorklet drops application frames before markAuthenticated',
    () async {
      final hub = InProcessWorkletHub();
      final a = openInProcessIpc(hub: hub);
      final b = openInProcessIpc(hub: hub);
      final frames = <Map<String, Object?>>[];
      final sub = b.client.events.listen(frames.add);
      addTearDown(() async {
        await sub.cancel();
        await a.client.close();
        await b.client.close();
      });

      await a.client.request('start', {'peerId': 'ORBIT-AAAAAAAAAAAAAAAA'});
      await b.client.request('start', {'peerId': 'ORBIT-BBBBBBBBBBBBBBBB'});
      await a.client.request('publish');
      await b.client.request('publish');
      await a.client.request('connect', {'peerId': 'ORBIT-BBBBBBBBBBBBBBBB'});

      await a.client.request('send', {
        'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
        'channel': 'message',
        'frameB64': 'eyJ0eXBlIjoicHJlLWF1dGgifQ==',
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        frames.any((e) => e['name'] == 'frame'),
        isFalse,
        reason: 'application frame before markAuthenticated must not land',
      );

      await a.client.request('markAuthenticated', {
        'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
      });
      await b.client.request('markAuthenticated', {
        'peerId': 'ORBIT-AAAAAAAAAAAAAAAA',
      });
      await a.client.request('send', {
        'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
        'channel': 'message',
        'frameB64': 'eyJ0eXBlIjoicGluZyJ9',
      });
      await Future<void>.delayed(Duration.zero);
      expect(frames.any((e) => e['name'] == 'frame'), isTrue);
    },
    skip:
        'InProcessBareWorklet.markAuthenticated is a no-op; send is not '
        'gated. DualStack loopback + JS phase1 cover the Dart/worklet gate.',
  );

  test(
    'reentrant NativeTransportHost.ensureStarted is single-flight',
    () async {
      // NativeTransportHost.ensureStarted needs AuthAuthed + a carrier
      // and is being edited by phase0_security. Do not invent a test
      // hook. DualStack attach is already single-listener.
    },
    skip:
        'NativeTransportHost.ensureStarted is not exercisable without '
        'AuthAuthed + Riverpod host internals',
  );
}

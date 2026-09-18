// Behavioral IPC / worklet adversarial coverage. Complements
// test/security/phase0_adversarial_test.dart (DualStack loopback).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/bare_ipc_client.dart';
import 'package:orbits_flutter/transport/ipc_codec.dart';

void main() {
  test('IPC codec rejects an oversized declared payload', () {
    // Matches tool/connectivity_harness/src/ipc.js MAX_IPC_FRAME_BYTES.
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
  });

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
      // Placeholder: InProcessBareWorklet has no markAuthenticated.
      // DualStack loopback pre-auth is in phase0_adversarial_test.dart.
      // The JS worklet gate is tool/connectivity_harness/test/phase1_*.js.
      expect(InProcessBareWorklet, isNotNull);
    },
    skip:
        'InProcessBareWorklet has no markAuthenticated; '
        'see DualStack pre-auth in phase0_adversarial_test.dart',
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

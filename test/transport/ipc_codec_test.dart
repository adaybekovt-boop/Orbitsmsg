import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/ipc_codec.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/transport_api.dart';

void main() {
  test('IPC round-trips and reassembles split chunks', () {
    final encoded = OrbitsIpcCodec.encode(
      const OrbitsIpcMessage(
        type: kIpcRequest,
        body: {'id': 1, 'method': 'start', 'peerId': 'ORBIT-AA'},
      ),
    );
    final codec = OrbitsIpcCodec();
    expect(codec.add(encoded.sublist(0, 4)), isEmpty);
    final messages = codec.add(encoded.sublist(4));
    expect(messages, hasLength(1));
    expect(messages.first.type, kIpcRequest);
    expect(messages.first.body['method'], 'start');
  });

  test('IPC rejects a bad magic', () {
    final codec = OrbitsIpcCodec();
    expect(
      () => codec.add(Uint8List.fromList(List<int>.filled(16, 0))),
      throwsFormatException,
    );
  });

  test('mux frames split across packets', () {
    final frame = encodeMuxFrame(
      TransportChannel.message,
      jsonPayload({'type': 'harness-echo', 'text': 'hi'}),
    );
    final decoder = MuxDecoder();
    expect(decoder.add(frame.sublist(0, 3)), isEmpty);
    final out = decoder.add(frame.sublist(3));
    expect(out, hasLength(1));
    expect(out.first.$1, TransportChannel.message);
    expect(decodeJsonPayload(out.first.$2)['text'], 'hi');
  });
}

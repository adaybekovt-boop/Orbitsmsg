import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/bare_ipc_client.dart';
import 'package:orbits_flutter/transport/ipc_codec.dart';

void main() {
  test('request times out and does not hang', () async {
    final client = BareIpcClient(write: (_) {}, defaultTimeout: const Duration(milliseconds: 30));
    await expectLater(
      client.request('start'),
      throwsA(isA<TimeoutException>()),
    );
    await client.close();
  });

  test('stdout EOF fails every pending request', () async {
    final client = BareIpcClient(write: (_) {});
    final a = client.request('start');
    final b = client.request('publish');
    client.failAll(StateError('worklet stdout closed'));
    await expectLater(a, throwsStateError);
    await expectLater(b, throwsStateError);
    await expectLater(client.request('send'), throwsA(isA<StateError>()));
    await client.close();
  });

  test('malformed frame fails pending requests', () async {
    final client = BareIpcClient(write: (_) {});
    final pending = client.request('start');
    client.addBytes(const [1, 2, 3, 4]);
    await expectLater(pending, throwsStateError);
    await client.close();
  });

  test('process exit fails several pending requests without hanging', () async {
    final client = BareIpcClient(write: (_) {});
    final pending = List<Future<Map<String, Object?>>>.generate(
      5,
      (i) => client.request('m$i'),
    );
    client.failAll(StateError('worklet exited: 1'));
    for (final future in pending) {
      await expectLater(future, throwsStateError);
    }
    await expectLater(client.request('after'), throwsA(isA<StateError>()));
    await client.close();
  });

  test('stop timeout does not hang when the worklet never answers', () async {
    final client = BareIpcClient(
      write: (_) {},
      defaultTimeout: const Duration(milliseconds: 40),
    );
    await expectLater(
      client.request('stop', const {}, const Duration(milliseconds: 40)),
      throwsA(isA<TimeoutException>()),
    );
    await client.close();
  });

  test('close after failAll is idempotent', () async {
    final client = BareIpcClient(write: (_) {});
    client.failAll(StateError('stdout closed'));
    await client.close();
    await client.close();
    expect(client.isClosed, isTrue);
  });

  test('close is idempotent and rejects new requests', () async {
    final client = BareIpcClient(write: (_) {});
    await client.close();
    await client.close();
    await expectLater(client.request('stop'), throwsStateError);
    expect(client.isClosed, isTrue);
  });

  test('in-process worklet answers start and authorize', () async {
    final pair = openInProcessIpc();
    await pair.client.request('start', {'peerId': 'ORBIT-AA'});
    await pair.client.request('authorize', {'peerId': 'ORBIT-BB'});
    expect(pair.worklet.methods, containsAll(['start', 'authorize']));
    await pair.client.close();
  });

  test('encoded response completes the matching request', () async {
    late BareIpcClient client;
    client = BareIpcClient(
      write: (bytes) {
        final codec = OrbitsIpcCodec();
        for (final message in codec.add(Uint8List.fromList(bytes))) {
          client.addBytes(
            OrbitsIpcCodec.encode(
              OrbitsIpcMessage(
                type: kIpcResponse,
                body: <String, Object?>{
                  'id': message.body['id'],
                  'ok': true,
                  'result': {'pong': true},
                },
              ),
            ),
          );
        }
      },
    );
    final result = await client.request('ping');
    expect(result['pong'], isTrue);
    await client.close();
  });
}

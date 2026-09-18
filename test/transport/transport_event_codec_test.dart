import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/transport_event_codec.dart';

DeviceBinding _binding() {
  return DeviceBinding(
    version: kDeviceBindingVersion,
    identityPublicKey: Uint8List.fromList(List<int>.filled(32, 2)),
    deviceId: 'dev-a',
    transportPublicKey: Uint8List.fromList(List<int>.filled(32, 3)),
    hypercorePublicKey: Uint8List.fromList(List<int>.filled(32, 4)),
    capabilities: const ['hyperswarm-v1'],
    createdAt: 1,
    expiresAt: 2,
    signatureByIdentityKey: Uint8List.fromList(List<int>.filled(64, 5)),
    ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
  );
}

void main() {
  test('missing connectionNoisePublicKey is not invented from the binding', () {
    final binding = _binding();
    final pending = platformMapToTransportEvent(<String, Object?>{
      'name': 'identity-pending',
      'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
      'binding': deviceBindingToWire(binding),
    });
    expect(pending, isA<TransportIdentityPending>());
    expect(
      (pending as TransportIdentityPending).connectionNoisePublicKey,
      isNull,
    );
    expect(
      pending.binding.transportPublicKey,
      binding.transportPublicKey,
    );

    final authed = platformMapToTransportEvent(<String, Object?>{
      'name': 'authenticated',
      'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
      'binding': deviceBindingToWire(binding),
    });
    expect(
      (authed as TransportAuthenticated).connectionNoisePublicKey,
      isNull,
    );
  });

  test('present connectionNoisePublicKey is preserved through a round-trip', () {
    final binding = _binding();
    final noise = List<int>.filled(32, 9);
    final encoded = transportEventToPlatformMap(
      TransportIdentityPending(
        'ORBIT-BBBBBBBBBBBBBBBB',
        binding,
        connectionNoisePublicKey: noise,
      ),
    );
    expect(encoded['connectionNoisePublicKey'], noise);
    final decoded = platformMapToTransportEvent(encoded);
    expect(
      (decoded as TransportIdentityPending).connectionNoisePublicKey,
      noise,
    );
    expect(
      decoded.connectionNoisePublicKey,
      isNot(decoded.binding.transportPublicKey),
    );
  });

  test('unknown path stays unknown and frames accept bytes or frameB64', () {
    final path = platformMapToTransportEvent(<String, Object?>{
      'name': 'pathChanged',
      'peerId': 'p',
      'path': 'holepunch',
    });
    expect((path as TransportPathChanged).path, TransportPath.unknown);

    final fromBytes = platformMapToTransportEvent(<String, Object?>{
      'name': 'frame',
      'peerId': 'p',
      'channel': 'message',
      'bytes': <int>[1, 2, 3],
    });
    expect((fromBytes as TransportFrame).bytes, <int>[1, 2, 3]);

    final fromB64 = platformMapToTransportEvent(<String, Object?>{
      'name': 'frame',
      'peerId': 'p',
      'channel': 'message',
      'frameB64': 'cGluZw==',
    });
    expect(String.fromCharCodes((fromB64 as TransportFrame).bytes), 'ping');
  });

  test('unknown frame channel is dropped, not remapped to message', () {
    expect(
      platformMapToTransportEvent(<String, Object?>{
        'name': 'frame',
        'peerId': 'p',
        'channel': 'not-a-channel',
        'bytes': <int>[1],
      }),
      isNull,
    );
    expect(channelFromWire('message'), TransportChannel.message);
    expect(channelFromWire('nope'), isNull);
  });

  test('empty hypercore writer is not accepted from the wire', () {
    final raw = deviceBindingToWire(_binding());
    raw['hypercorePublicKeyB64'] = '';
    expect(deviceBindingFromWire(raw), isNull);
  });

  test('deviceBindingToWire round-trips owner and writer keys', () {
    final binding = _binding();
    final again = deviceBindingFromWire(deviceBindingToWire(binding));
    expect(again?.deviceId, 'dev-a');
    expect(again?.ownerPeerId, 'ORBIT-AAAAAAAAAAAAAAAA');
    expect(again?.hypercorePublicKey, binding.hypercorePublicKey);
  });
}

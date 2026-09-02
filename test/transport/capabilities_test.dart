import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/capabilities.dart';

void main() {
  const native = {
    TransportCapability.hyperswarmV1,
    TransportCapability.peerjsV4,
  };
  const peerjsOnly = {TransportCapability.peerjsV4};
  const pwa = {
    TransportCapability.peerjsV4,
    TransportCapability.webPwaV1,
  };

  test('native pair prefers Hyperswarm', () {
    expect(
      selectTransportRoute(local: native, remote: native),
      TransportRoute.hyperswarm,
    );
  });

  test('old native stays on PeerJS', () {
    expect(
      selectTransportRoute(local: native, remote: peerjsOnly),
      TransportRoute.peerjs,
    );
  });

  test('PWA never takes Hyperswarm', () {
    expect(
      selectTransportRoute(local: native, remote: pwa),
      TransportRoute.peerjs,
    );
    expect(
      selectTransportRoute(
        local: native,
        remote: native,
        localIsPwa: true,
      ),
      TransportRoute.peerjs,
    );
  });

  test('disabled fallback fails closed', () {
    expect(
      selectTransportRoute(
        local: native,
        remote: peerjsOnly,
        allowPeerjsFallback: false,
      ),
      TransportRoute.unavailable,
    );
  });

  test('Phase 0 defaults advertise PeerJS only', () {
    expect(defaultNativeCapabilities(), {TransportCapability.peerjsV4});
    expect(defaultPwaCapabilities(), {
      TransportCapability.peerjsV4,
      TransportCapability.webPwaV1,
    });
    expect(
      selectTransportRoute(
        local: defaultNativeCapabilities(),
        remote: defaultPwaCapabilities(),
      ),
      TransportRoute.peerjs,
    );
  });

  test('wire names stay stable', () {
    expect(TransportCapability.hyperswarmV1.wireName, 'hyperswarm-v1');
    expect(
      TransportCapability.fromWireName('multi-device-v1'),
      TransportCapability.multiDeviceV1,
    );
    expect(
      TransportCapability.fromWireName('room-voice-v1'),
      TransportCapability.roomVoiceV1,
    );
    expect(
      TransportCapability.fromWireName('call-v1'),
      TransportCapability.callV1,
    );
    expect(TransportCapability.fromWireName('nope'), isNull);
    expect(advertisesRoomVoiceV1(const ['hyperswarm-v1', 'peerjs-v4']), isFalse);
    expect(
      advertisesRoomVoiceV1(const ['hyperswarm-v1', 'room-voice-v1']),
      isTrue,
    );
    expect(advertisesCallV1(const ['hyperswarm-v1', 'peerjs-v4']), isFalse);
    expect(advertisesCallV1(const ['hyperswarm-v1', 'call-v1']), isTrue);
  });
}

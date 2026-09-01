import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/push/opaque_wake.dart';
import 'package:orbits_flutter/push/push_gateway.dart';
import 'package:orbits_flutter/push/wake_service.dart';

void main() {
  test('APNs and FCM gateways are not deployed', () {
    expect(kLiveApnsGateway, isFalse);
    expect(kLiveFcmGateway, isFalse);
    final gateway = PushGateway(OpaqueWakeService());
    expect(gateway.deployed, isFalse);
  });

  test('gateway rejects plaintext and accepts opaque wake', () async {
    final gateway = PushGateway(OpaqueWakeService());
    expect(
      (await gateway.ingestApns({
        'opaqueWakeToken': 'tok',
        'collapseId': 'c1',
        'protocolVersion': 1,
        'text': 'hi',
      }))
          .accepted,
      isFalse,
    );
    expect(
      (await gateway.ingestFcm({
        'opaqueWakeToken': 'tok',
        'collapseId': 'c1',
        'protocolVersion': 1,
        'peerId': 'ORBIT-AA',
      }))
          .accepted,
      isFalse,
    );
    const wake = OpaqueWake(
      opaqueWakeToken: 'tok',
      collapseId: 'c1',
      protocolVersion: 1,
    );
    expect((await gateway.ingestApns(wake.toJson())).accepted, isTrue);
    expect((await gateway.ingestFcm(wake.toJson())).accepted, isTrue);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/transport/layers.dart';
import 'package:orbits_flutter/transport/peerjs_window.dart';

void main() {
  test('PeerJS remains the default live path and isolation mode', () {
    expect(kPeerjsSupportWindowOpen, isTrue);
    expect(kPeerjsIsolationMode, 'default-live');
    expect(kCompletedMigrationPhase, 0);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
  });

  test(
    'native-only Holepunch sources are not imported from web entrypoints',
    () {
      final web = File('lib/transport/native_transport_host_stub.dart');
      expect(web.existsSync(), isTrue);
      final text = web.readAsStringSync();
      expect(text, isNot(contains('hyperswarm')));
      expect(text, isNot(contains('worklet_orbits_transport_io')));
    },
  );

  test('web stub worklet does not spawn a native process', () {
    final stub = File('lib/transport/worklet_orbits_transport_stub.dart');
    expect(stub.readAsStringSync(), contains('async =>'));
    expect(stub.readAsStringSync(), contains('null'));
  });
}

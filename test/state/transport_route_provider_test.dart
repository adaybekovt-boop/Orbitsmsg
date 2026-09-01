import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/state/transport_route_provider.dart';
import 'package:orbits_flutter/transport/capabilities.dart';

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('stock client reports PeerJS while rollout is off', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final decision = container.read(
      transportRouteProvider((remoteIsPwa: false, remoteHasHyperswarm: true)),
    );
    expect(decision.route, TransportRoute.peerjs);
    expect(describeTransportRoute(decision), contains('rollout=off'));
  });
}

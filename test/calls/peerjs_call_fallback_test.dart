import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/state/calls_provider.dart';

void main() {
  test('PeerJS media opens only as fallback after native failure', () {
    expect(
      shouldOpenPeerjsCallFallback(
        fallbackEnabled: true,
        peerAvailable: true,
      ),
      isTrue,
    );
    expect(
      shouldOpenPeerjsCallFallback(
        fallbackEnabled: false,
        peerAvailable: true,
      ),
      isFalse,
    );
    expect(
      shouldOpenPeerjsCallFallback(
        fallbackEnabled: true,
        peerAvailable: false,
      ),
      isFalse,
    );
  });
}

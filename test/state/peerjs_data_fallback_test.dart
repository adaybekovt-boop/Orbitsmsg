import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/state/connections_notifier.dart';

void main() {
  test('PeerJS data opens only as fallback after native is unusable', () {
    expect(
      shouldOpenPeerjsDataFallback(
        fallbackEnabled: true,
        failClosed: false,
        nativeUsable: false,
      ),
      isTrue,
    );
    expect(
      shouldOpenPeerjsDataFallback(
        fallbackEnabled: false,
        failClosed: false,
        nativeUsable: false,
      ),
      isFalse,
    );
    expect(
      shouldOpenPeerjsDataFallback(
        fallbackEnabled: true,
        failClosed: true,
        nativeUsable: false,
      ),
      isFalse,
    );
    expect(
      shouldOpenPeerjsDataFallback(
        fallbackEnabled: true,
        failClosed: false,
        nativeUsable: true,
      ),
      isFalse,
    );
    expect(
      shouldOpenPeerjsDataFallback(
        fallbackEnabled: true,
        failClosed: false,
        nativeUsable: false,
        nativeRejected: true,
      ),
      isFalse,
    );
    expect(
      shouldOpenPeerjsDataFallback(
        fallbackEnabled: true,
        failClosed: false,
        nativeUsable: false,
        nativePending: true,
      ),
      isFalse,
    );
  });
}

// Phase 3 — honest hosting capability. Desktop can run a (non-persistent,
// while-app-open) self-hosted room server; web and mobile CANNOT, and must not
// claim persistent hosting. `canHostSignalingServerOn` is the single source of
// truth the create-server UX reads.

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/room_signaling_host.dart';

void main() {
  group('canHostSignalingServerOn', () {
    test('desktop platforms can host', () {
      for (final p in const [
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        expect(canHostSignalingServerOn(isWeb: false, platform: p), isTrue,
            reason: '$p should be able to host');
      }
    });

    test('mobile platforms CANNOT host', () {
      for (final p in const [TargetPlatform.iOS, TargetPlatform.android]) {
        expect(canHostSignalingServerOn(isWeb: false, platform: p), isFalse,
            reason: '$p must not claim hosting');
      }
    });

    test('web CANNOT host regardless of platform value', () {
      // A browser can't bind a listening socket — never hostable, even if the
      // underlying OS is a desktop one.
      expect(
        canHostSignalingServerOn(isWeb: true, platform: TargetPlatform.windows),
        isFalse,
      );
      expect(
        canHostSignalingServerOn(isWeb: true, platform: TargetPlatform.android),
        isFalse,
      );
    });
  });

  group('hostingLimitationSummary (no false persistence claims)', () {
    test('desktop summary admits the room dies when the app closes', () {
      final s = hostingLimitationSummary(
          isWeb: false, platform: TargetPlatform.linux);
      // Must NOT promise an always-on / permanent / cloud server.
      expect(s, isNot(contains('постоянн'))); // no "постоянный сервер" promise
      expect(s.toLowerCase(), contains('пока'));
      expect(s, contains('недоступн')); // becomes unavailable when closed
    });

    test('mobile/web summary states it is NOT persistent and points to PC', () {
      final s =
          hostingLimitationSummary(isWeb: false, platform: TargetPlatform.iOS);
      expect(s, contains('НЕ сохраняется'));
      expect(s, contains('ПК'));
    });
  });
}

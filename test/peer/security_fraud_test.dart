// Phase 5 verification — fraud detection + flood guard + trust verification.
//
// SecurityMonitor is pure synchronous logic (no DB / no widgets), so these run
// instantly with no fake-async hazards. (The tester.runAsync pattern is only
// needed for widget/Drift-stream tests; nothing here touches a database.)

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/qr_pairing.dart';
import 'package:orbits_flutter/peer/security_monitor.dart';

void main() {
  group('SecurityMonitor — IP fraud detection', () {
    test('flags IP collision when two different peers share one IP', () {
      final m = SecurityMonitor();
      expect(m.recordConnection('peerA', '203.0.113.7'), isNull);
      final finding = m.recordConnection('peerB', '203.0.113.7');
      expect(finding, isNotNull);
      expect(finding!.kind, SecurityFindingKind.ipCollision);
      expect(finding.peerId, 'peerB');
      expect(m.hasAlerts, isTrue);
      expect(m.latestAlert?.kind, SecurityFindingKind.ipCollision);
    });

    test('flags IP hop when one peerId connects from two IPs', () {
      final m = SecurityMonitor();
      expect(m.recordConnection('peerA', '203.0.113.7'), isNull);
      final finding = m.recordConnection('peerA', '198.51.100.3');
      expect(finding, isNotNull);
      expect(finding!.kind, SecurityFindingKind.ipHop);
    });

    test('same peer reconnecting from the same IP stays clean', () {
      final m = SecurityMonitor();
      m.recordConnection('peerA', '203.0.113.7');
      expect(m.recordConnection('peerA', '203.0.113.7'), isNull);
      expect(m.hasAlerts, isFalse);
    });

    test('distinct peers on distinct IPs stay clean', () {
      final m = SecurityMonitor();
      expect(m.recordConnection('peerA', '10.0.0.1'), isNull);
      expect(m.recordConnection('peerB', '10.0.0.2'), isNull);
      expect(m.hasAlerts, isFalse);
    });

    test('reset clears all findings + history', () {
      final m = SecurityMonitor();
      m.recordConnection('peerA', '1.2.3.4');
      m.recordConnection('peerB', '1.2.3.4');
      expect(m.hasAlerts, isTrue);
      m.reset();
      expect(m.hasAlerts, isFalse);
      // Same IP can be reused cleanly after reset.
      expect(m.recordConnection('peerA', '1.2.3.4'), isNull);
    });
  });

  group('SecurityMonitor — flood / rate limit', () {
    test('blocks a peer after more than 5 messages in one second', () {
      final m = SecurityMonitor(maxMessagesPerSecond: 5, blockMs: 10000);
      var blocked = false;
      for (var i = 0; i < 6; i++) {
        blocked = m.recordMessage('spammer', 1000 + i * 10);
      }
      expect(blocked, isTrue, reason: 'the 6th message in <1s trips the guard');
      expect(m.isBlocked('spammer', 1100), isTrue);
    });

    test('does not block at or under the limit', () {
      final m = SecurityMonitor(maxMessagesPerSecond: 5);
      var blocked = false;
      for (var i = 0; i < 5; i++) {
        blocked = m.recordMessage('ok', 2000 + i * 10);
      }
      expect(blocked, isFalse);
      expect(m.isBlocked('ok', 2100), isFalse);
    });

    test('unblocks after the 10s block window elapses', () {
      final m = SecurityMonitor(maxMessagesPerSecond: 5, blockMs: 10000);
      // The block is armed at the tripping (6th) message's timestamp = 1050,
      // so it lifts at 1050 + 10000 = 11050.
      for (var i = 0; i < 6; i++) {
        m.recordMessage('spammer', 1000 + i * 10);
      }
      expect(m.isBlocked('spammer', 6000), isTrue); // still within 10s
      expect(m.isBlocked('spammer', 11051), isFalse); // past the window
    });

    test('messages spread across windows never trip the guard', () {
      final m = SecurityMonitor(maxMessagesPerSecond: 5, windowMs: 1000);
      var blocked = false;
      for (var i = 0; i < 30; i++) {
        blocked = m.recordMessage('steady', i * 300); // ~3.3 msg/sec
      }
      expect(blocked, isFalse);
    });
  });

  group('Contact verification (trustLevel)', () {
    test('trustLevel 2+ → verified (green check)', () {
      expect(verificationFromTrustLevel(2), ContactVerification.verified);
      expect(verificationFromTrustLevel(3), ContactVerification.verified);
    });

    test('trustLevel 1 → known (TOFU, not personally verified)', () {
      expect(verificationFromTrustLevel(1), ContactVerification.known);
    });

    test('trustLevel 0 or null → unverified (grey warning)', () {
      expect(verificationFromTrustLevel(0), ContactVerification.unverified);
      expect(verificationFromTrustLevel(null), ContactVerification.unverified);
    });
  });

  group('QR pairing — URI build / parse', () {
    test('round-trips pcPeerId + token', () {
      final uri = buildPairingUri('ORBIT-ABC123', 'tok-xyz');
      expect(uri, 'orbits_pairing:ORBIT-ABC123:tok-xyz');
      final parsed = parsePairingUri(uri);
      expect(parsed, isNotNull);
      expect(parsed!.pcPeerId, 'ORBIT-ABC123');
      expect(parsed.sessionToken, 'tok-xyz');
    });

    test('preserves a token that itself contains separators', () {
      const token = 'aa:bb:cc==';
      final parsed = parsePairingUri(buildPairingUri('PC1', token));
      expect(parsed?.pcPeerId, 'PC1');
      expect(parsed?.sessionToken, token);
    });

    test('rejects non-pairing or malformed strings', () {
      expect(parsePairingUri('https://example.com'), isNull);
      expect(parsePairingUri('orbits_pairing:onlypeer'), isNull);
      expect(parsePairingUri('orbits_pairing::tokenonly'), isNull);
      expect(parsePairingUri(''), isNull);
    });

    test('generated session tokens are 32 bytes of entropy and unique', () {
      final a = generateSessionToken();
      final b = generateSessionToken();
      expect(a, isNot(equals(b)));
      expect(a.length, greaterThanOrEqualTo(42)); // 32 bytes → ~43 base64url chars
    });
  });
}

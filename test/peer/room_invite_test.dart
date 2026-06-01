// Phase 2 (testable part): the self-hosted room invite codec. Pure round-trip +
// parse-hardening tests; no sockets, no Flutter.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/room_invite.dart';

void main() {
  group('RoomInvite encode/parse', () {
    test('LAN-only round-trips', () {
      final inv = RoomInvite(
        roomId: 'ORBIT-AB12CD',
        lanHosts: ['192.168.1.5', '10.0.0.9'],
        port: 53217,
      );
      final wire = inv.encode();
      expect(wire, startsWith('orbits-room:1;id=ORBIT-AB12CD;'));
      expect(wire, contains('h=192.168.1.5,10.0.0.9'));
      expect(wire, contains('p=53217'));
      expect(wire, isNot(contains('pub=')));

      final back = RoomInvite.tryParse(wire)!;
      expect(back.roomId, 'ORBIT-AB12CD');
      expect(back.lanHosts, ['192.168.1.5', '10.0.0.9']);
      expect(back.port, 53217);
      expect(back.hasPublic, isFalse);
      expect(back.key, isNull);
    });

    test('with public address + key round-trips', () {
      final inv = RoomInvite(
        roomId: 'ORBIT-FFFFFF',
        lanHosts: ['192.168.0.2'],
        port: 7000,
        publicHostPort: '203.0.113.7:7000',
        key: 'room-secret',
      );
      final back = RoomInvite.tryParse(inv.encode())!;
      expect(back.publicHostPort, '203.0.113.7:7000');
      expect(back.hasPublic, isTrue);
      expect(back.key, 'room-secret');
    });

    test('dialEndpoints lists public first, then LAN, de-duplicated', () {
      final inv = RoomInvite(
        roomId: 'ORBIT-AB12CD',
        lanHosts: ['192.168.1.5', '192.168.1.5'], // dup
        port: 8080,
        publicHostPort: '203.0.113.7:8080',
      );
      expect(inv.dialEndpoints, ['203.0.113.7:8080', '192.168.1.5:8080']);
    });

    test('default key "peerjs" is not serialized', () {
      final inv = RoomInvite(
        roomId: 'ORBIT-AB12CD',
        lanHosts: ['192.168.1.5'],
        port: 9000,
        key: 'peerjs',
      );
      expect(inv.encode(), isNot(contains('k=')));
    });

    test('lower-case roomId is normalized to upper-case', () {
      final inv = RoomInvite(
        roomId: 'orbit-ab12cd',
        lanHosts: ['192.168.1.5'],
        port: 9000,
      );
      expect(inv.roomId, 'ORBIT-AB12CD');
    });
  });

  group('RoomInvite.tryParse hardening', () {
    test('rejects non-invite strings', () {
      expect(RoomInvite.tryParse(null), isNull);
      expect(RoomInvite.tryParse(''), isNull);
      expect(RoomInvite.tryParse('hello'), isNull);
      expect(RoomInvite.tryParse('orbits_pairing:ORBIT-AB12CD:tok'), isNull);
    });

    test('rejects unknown version', () {
      expect(
        RoomInvite.tryParse('orbits-room:2;id=ORBIT-AB12CD;h=192.168.1.5;p=80'),
        isNull,
      );
    });

    test('rejects invalid ORBIT id', () {
      expect(
        RoomInvite.tryParse('orbits-room:1;id=NOTANID;h=192.168.1.5;p=80'),
        isNull,
      );
    });

    test('rejects out-of-range / missing port', () {
      expect(
        RoomInvite.tryParse('orbits-room:1;id=ORBIT-AB12CD;h=192.168.1.5;p=0'),
        isNull,
      );
      expect(
        RoomInvite.tryParse('orbits-room:1;id=ORBIT-AB12CD;h=192.168.1.5;p=70000'),
        isNull,
      );
      expect(
        RoomInvite.tryParse('orbits-room:1;id=ORBIT-AB12CD;h=192.168.1.5'),
        isNull,
      );
    });

    test('rejects an invite with no reachable address', () {
      expect(
        RoomInvite.tryParse('orbits-room:1;id=ORBIT-AB12CD;h=;p=8080'),
        isNull,
      );
    });

    test('accepts public-only (no LAN hosts)', () {
      final inv = RoomInvite.tryParse(
        'orbits-room:1;id=ORBIT-AB12CD;h=;p=8080;pub=203.0.113.7:8080',
      );
      expect(inv, isNotNull);
      expect(inv!.lanHosts, isEmpty);
      expect(inv.dialEndpoints, ['203.0.113.7:8080']);
    });

    test('tolerates surrounding whitespace and unknown keys', () {
      final inv = RoomInvite.tryParse(
        '  orbits-room:1;id=ORBIT-AB12CD;h=192.168.1.5;p=8080;future=xyz  ',
      );
      expect(inv, isNotNull);
      expect(inv!.roomId, 'ORBIT-AB12CD');
    });
  });
}

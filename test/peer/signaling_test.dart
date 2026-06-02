// Signaling endpoint resolution — focuses on the wss-enforcement added for
// audit H3 and the backoff bounds.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/signaling.dart';

void main() {
  group('resolveEndpoint wss enforcement (H3)', () {
    test('upgrades an insecure peerSecure=false config to wss by default', () {
      final ep = resolveEndpoint(
        host: '0.peerjs.com',
        env: const PeerEnv(peerSecure: false),
      );
      expect(ep.secure, isTrue);
      expect(ep.port, 443);
    });

    test('honours allowInsecureTransport for local dev', () {
      final ep = resolveEndpoint(
        host: 'localhost',
        env: const PeerEnv(
          peerSecure: false,
          peerPort: 9000,
          allowInsecureTransport: true,
        ),
      );
      expect(ep.secure, isFalse);
      expect(ep.port, 9000);
    });

    test('upgrades a ws:// peerServer URL to wss by default', () {
      final ep = resolveEndpoint(
        host: 'ignored',
        env: const PeerEnv(peerServer: 'ws://relay.example.com:9000/'),
      );
      expect(ep.secure, isTrue);
      // Non-standard insecure port is dropped on upgrade — dial 443 instead.
      expect(ep.port, 443);
      expect(ep.host, 'relay.example.com');
    });

    test('leaves an explicit wss:// peerServer untouched', () {
      final ep = resolveEndpoint(
        host: 'ignored',
        env: const PeerEnv(peerServer: 'wss://relay.example.com/'),
      );
      expect(ep.secure, isTrue);
      expect(ep.port, 443);
    });

    test('defaults to secure wss when nothing is configured', () {
      final ep = resolveEndpoint(host: '0.peerjs.com', env: const PeerEnv());
      expect(ep.secure, isTrue);
      expect(ep.port, 443);
    });
  });

  group('config overrides (L7)', () {
    test('signalingHosts override replaces the public peerjs fallback', () {
      final hosts = buildSignalingHosts(
        const PeerEnv(signalingHosts: ['sig1.example.com', 'sig2.example.com']),
      );
      expect(hosts, ['sig1.example.com', 'sig2.example.com']);
    });

    test('falls back to public peerjs hosts when no override', () {
      final hosts = buildSignalingHosts(const PeerEnv());
      expect(hosts, contains('0.peerjs.com'));
    });

    test('iceServers override replaces the public STUN defaults', () {
      final cfg = buildRtcConfig(
        const PeerEnv(iceServers: [
          {'urls': 'stun:stun.self-hosted.example:3478'}
        ]),
      );
      expect(cfg.iceServers.length, 1);
      expect(cfg.iceServers.first['urls'], 'stun:stun.self-hosted.example:3478');
    });

    test('a configured TURN is appended on top of the override', () {
      final cfg = buildRtcConfig(
        const PeerEnv(
          iceServers: [
            {'urls': 'stun:stun.self-hosted.example:3478'}
          ],
          turnUrl: 'turn:turn.example:3478',
          turnUsername: 'u',
          turnCredential: 'c',
        ),
      );
      expect(cfg.iceServers.length, 2);
      expect(cfg.iceServers.last['urls'], 'turn:turn.example:3478');
    });

    test('uses public defaults when no iceServers override', () {
      final cfg = buildRtcConfig(const PeerEnv());
      expect(cfg.iceServers, isNotEmpty);
      expect(cfg.iceServers.first['urls'], startsWith('stun:'));
    });
  });

  group('TURN / relay policy (cross-network)', () {
    test('TURN creds from env are added to the ICE list', () {
      final cfg = buildRtcConfig(const PeerEnv(
        turnUrl: 'turn:turn.example:3478',
        turnUsername: 'user',
        turnCredential: 'secret',
      ));
      final turn = cfg.iceServers.firstWhere(
        (s) => (s['urls'] as String).startsWith('turn:'),
        orElse: () => const {},
      );
      expect(turn['urls'], 'turn:turn.example:3478');
      expect(turn['username'], 'user');
      expect(turn['credential'], 'secret');
    });

    test('relayOnly + TURN forces iceTransportPolicy=relay', () {
      final cfg = buildRtcConfig(const PeerEnv(
        turnUrl: 'turn:t:3478',
        turnUsername: 'u',
        turnCredential: 'c',
        relayOnly: true,
      ));
      expect(cfg.iceTransportPolicy, 'relay');
    });

    test('relayOnly WITHOUT TURN does not force relay (would block all ICE)',
        () {
      final cfg = buildRtcConfig(const PeerEnv(relayOnly: true));
      expect(cfg.iceTransportPolicy, isNull);
    });

    test('no TURN configured → no relay policy, STUN-only', () {
      final cfg = buildRtcConfig(const PeerEnv());
      expect(cfg.iceTransportPolicy, isNull);
      expect(
        cfg.iceServers.any((s) => (s['urls'] as String).startsWith('turn:')),
        isFalse,
      );
    });
  });

  group('multi-transport TURN (Phase 1)', () {
    test('turnUrlsFor merges turnUrl + turnUrls, trimmed + de-duped', () {
      final urls = turnUrlsFor(const PeerEnv(
        turnUrl: 'turn:h:3478?transport=udp',
        turnUrls: [
          ' turn:h:3478?transport=tcp ',
          'turn:h:3478?transport=udp', // duplicate of turnUrl → dropped
          'turns:h:443?transport=tcp',
        ],
      ));
      expect(urls, [
        'turn:h:3478?transport=udp',
        'turn:h:3478?transport=tcp',
        'turns:h:443?transport=tcp',
      ]);
    });

    test('multiple TURN URLs become ONE ice server with a urls LIST', () {
      final cfg = buildRtcConfig(const PeerEnv(
        turnUrl: 'turn:h:3478?transport=udp',
        turnUrls: ['turn:h:3478?transport=tcp', 'turns:h:443?transport=tcp'],
        turnUsername: 'u',
        turnCredential: 'c',
      ));
      final turn =
          cfg.iceServers.firstWhere((s) => s.containsKey('credential'));
      expect(turn['urls'], isA<List<String>>());
      expect((turn['urls'] as List).cast<String>(), containsAll(const [
        'turn:h:3478?transport=udp',
        'turn:h:3478?transport=tcp',
        'turns:h:443?transport=tcp',
      ]));
      expect(turn['username'], 'u');
      expect(turn['credential'], 'c');
    });

    test('UDP / TCP / TLS-443 transport URIs are accepted verbatim', () {
      for (final uri in const [
        'turn:h:3478?transport=udp',
        'turn:h:3478?transport=tcp',
        'turns:h:443?transport=tcp',
      ]) {
        final cfg = buildRtcConfig(
            PeerEnv(turnUrl: uri, turnUsername: 'u', turnCredential: 'c'));
        final turn =
            cfg.iceServers.firstWhere((s) => s.containsKey('credential'));
        expect(turn['urls'], uri); // single URL → String, passed through as-is
      }
    });

    test('hasTurnConfigured requires a URL AND both credentials', () {
      expect(hasTurnConfigured(const PeerEnv(turnUrl: 'turn:h')), isFalse);
      expect(
          hasTurnConfigured(
              const PeerEnv(turnUsername: 'u', turnCredential: 'c')),
          isFalse);
      expect(
          hasTurnConfigured(const PeerEnv(
              turnUrls: ['turn:h'], turnUsername: 'u', turnCredential: 'c')),
          isTrue);
    });

    test('relayOnly without TURN is FLAGGED (not silently broken)', () {
      expect(relayOnlyMisconfigured(const PeerEnv(relayOnly: true)), isTrue);
      expect(
          relayOnlyMisconfigured(const PeerEnv(
              relayOnly: true,
              turnUrl: 'turn:h',
              turnUsername: 'u',
              turnCredential: 'c')),
          isFalse);
      expect(relayOnlyMisconfigured(const PeerEnv(relayOnly: false)), isFalse);
      // …and the built config falls back to a normal (non-relay) policy.
      expect(buildRtcConfig(const PeerEnv(relayOnly: true)).iceTransportPolicy,
          isNull);
    });

    test('relayOnly + multi-URL TURN still forces relay', () {
      final cfg = buildRtcConfig(const PeerEnv(
        turnUrl: 'turn:h:3478?transport=udp',
        turnUrls: ['turns:h:443?transport=tcp'],
        turnUsername: 'u',
        turnCredential: 'c',
        relayOnly: true,
      ));
      expect(cfg.iceTransportPolicy, 'relay');
    });
  });

  group('computeBackoffMs', () {
    test('grows with attempt and stays within [exp, exp+jitter]', () {
      for (var attempt = 0; attempt < 10; attempt++) {
        final v = computeBackoffMs(attempt, base: 800, maxMs: 30000, jitter: 500);
        expect(v, greaterThanOrEqualTo(0));
        expect(v, lessThanOrEqualTo(30000 + 500));
      }
    });

    test('caps the exponential term at maxMs', () {
      final v = computeBackoffMs(40, base: 800, maxMs: 30000, jitter: 1);
      expect(v, lessThanOrEqualTo(30001));
      expect(v, greaterThanOrEqualTo(30000));
    });

    test('treats negative attempts as zero', () {
      final v = computeBackoffMs(-5, base: 800, maxMs: 30000, jitter: 1);
      expect(v, greaterThanOrEqualTo(800));
      expect(v, lessThanOrEqualTo(801));
    });
  });
}

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
        const PeerEnv(
          iceServers: [
            {'urls': 'stun:stun.self-hosted.example:3478'},
          ],
        ),
      );
      expect(cfg.iceServers.length, 1);
      expect(
        cfg.iceServers.first['urls'],
        'stun:stun.self-hosted.example:3478',
      );
    });

    test('a configured TURN is appended on top of the override', () {
      final cfg = buildRtcConfig(
        const PeerEnv(
          iceServers: [
            {'urls': 'stun:stun.self-hosted.example:3478'},
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

  group(
    'LOCAL TESTNET runtime override (ORBITS_PEERJS_* / ORBITS_SIGNALING_URL)',
    () {
      test('empty env keeps public PeerJS hosts and secure wss', () {
        final env = applyPeerjsRuntimeOverride(const PeerEnv(), const {});
        expect(isPeerjsLocalTestnet(env), isFalse);
        expect(env.allowInsecureTransport, isFalse);
        final hosts = buildSignalingHosts(env);
        expect(hosts, ['0.peerjs.com', '1.peerjs.com', '2.peerjs.com']);
        final ep = resolveEndpoint(host: hosts.first, env: env);
        expect(ep.host, '0.peerjs.com');
        expect(ep.secure, isTrue);
        expect(ep.port, 443);
        expect(env.resolvedPeerKey, 'peerjs');
      });

      test('ORBITS_PEERJS_HOST pins loopback and allows ws on port 9000', () {
        final env = applyPeerjsRuntimeOverride(const PeerEnv(), const {
          kOrbitsPeerjsHostEnv: '127.0.0.1',
        });
        expect(isPeerjsLocalTestnet(env), isTrue);
        expect(env.peerHost, '127.0.0.1');
        expect(env.peerServer, isNull);
        expect(env.allowInsecureTransport, isTrue);
        expect(env.peerSecure, isFalse);
        expect(env.peerPort, kLocalPeerjsTestnetPort);
        final hosts = buildSignalingHosts(env);
        expect(hosts, ['127.0.0.1']);
        expect(canRotateHosts(env, hosts), isFalse);
        final ep = resolveEndpoint(host: hosts.first, env: env);
        expect(ep.host, '127.0.0.1');
        expect(ep.secure, isFalse);
        expect(ep.port, 9000);
      });

      test('ORBITS_SIGNALING_URL is parsed and strips a trailing /peerjs', () {
        final env = applyPeerjsRuntimeOverride(const PeerEnv(), const {
          kOrbitsSignalingUrlEnv: 'ws://127.0.0.1:9000/peerjs',
        });
        expect(isPeerjsLocalTestnet(env), isTrue);
        expect(env.peerServer, 'ws://127.0.0.1:9000/peerjs');
        final hosts = buildSignalingHosts(env);
        expect(hosts, [peerServerSentinel]);
        expect(canRotateHosts(env, hosts), isFalse);
        final ep = resolveEndpoint(host: hosts.first, env: env);
        expect(ep.host, '127.0.0.1');
        expect(ep.port, 9000);
        expect(ep.secure, isFalse);
        expect(ep.path, '/');
      });

      test(
        'partial override without host/url fails closed (no public fallback)',
        () {
          expect(
            () => applyPeerjsRuntimeOverride(const PeerEnv(), const {
              kOrbitsPeerjsPortEnv: '9000',
            }),
            throwsA(isA<PeerjsOverrideException>()),
          );
          expect(
            () => applyPeerjsRuntimeOverride(const PeerEnv(), const {
              kOrbitsSignalingUrlEnv: 'not a url',
            }),
            throwsA(isA<PeerjsOverrideException>()),
          );
        },
      );

      test('runtime pin replaces a compile-time public PEER_SERVER', () {
        const compileTime = PeerEnv(peerServer: 'wss://0.peerjs.com');
        final env = applyPeerjsRuntimeOverride(compileTime, const {
          kOrbitsPeerjsHostEnv: 'localhost',
          kOrbitsPeerjsPortEnv: '9000',
          kOrbitsPeerjsSecureEnv: 'false',
        });
        expect(env.peerServer, isNull);
        expect(env.peerHost, 'localhost');
        expect(buildSignalingHosts(env), ['localhost']);
        expect(isPeerjsLocalTestnet(env), isTrue);
      });

      test('ORBITS_PEERJS_KEY is presented when host is pinned', () {
        final env = applyPeerjsRuntimeOverride(const PeerEnv(), const {
          kOrbitsPeerjsHostEnv: '127.0.0.1',
          kOrbitsPeerjsKeyEnv: 'orbits-local-testnet',
        });
        expect(env.resolvedPeerKey, 'orbits-local-testnet');
      });
    },
  );

  group('TURN / relay policy (cross-network)', () {
    test('TURN creds from env are added to the ICE list', () {
      final cfg = buildRtcConfig(
        const PeerEnv(
          turnUrl: 'turn:turn.example:3478',
          turnUsername: 'user',
          turnCredential: 'secret',
        ),
      );
      final turn = cfg.iceServers.firstWhere(
        (s) => (s['urls'] as String).startsWith('turn:'),
        orElse: () => const {},
      );
      expect(turn['urls'], 'turn:turn.example:3478');
      expect(turn['username'], 'user');
      expect(turn['credential'], 'secret');
    });

    test('relayOnly + TURN forces iceTransportPolicy=relay', () {
      final cfg = buildRtcConfig(
        const PeerEnv(
          turnUrl: 'turn:t:3478',
          turnUsername: 'u',
          turnCredential: 'c',
          relayOnly: true,
        ),
      );
      expect(cfg.iceTransportPolicy, 'relay');
    });

    test(
      'relayOnly WITHOUT TURN fails closed (does not fall back to STUN)',
      () {
        expect(
          () => buildRtcConfig(const PeerEnv(relayOnly: true)),
          throwsA(isA<RelayOnlyUnavailable>()),
        );
      },
    );

    test(
      'user hide-IP pref is what drives relayOnly, not compile-time env',
      () {
        const compileTime = PeerEnv(relayOnly: false);
        final hidden = applyUserRelayOnly(compileTime, true);
        expect(hidden.relayOnly, isTrue);
        expect(
          () => buildRtcConfig(hidden),
          throwsA(isA<RelayOnlyUnavailable>()),
        );
        final withTurn = applyUserRelayOnly(
          const PeerEnv(
            turnUrl: 'turn:t:3478',
            turnUsername: 'u',
            turnCredential: 'c',
          ),
          true,
        );
        expect(buildRtcConfig(withTurn).iceTransportPolicy, 'relay');
      },
    );

    test('no TURN configured → no relay policy, STUN-only', () {
      final cfg = buildRtcConfig(const PeerEnv());
      expect(cfg.iceTransportPolicy, isNull);
      expect(
        cfg.iceServers.any((s) => (s['urls'] as String).startsWith('turn:')),
        isFalse,
      );
    });
  });

  group('computeBackoffMs', () {
    test('grows with attempt and stays within [exp, exp+jitter]', () {
      for (var attempt = 0; attempt < 10; attempt++) {
        final v = computeBackoffMs(
          attempt,
          base: 800,
          maxMs: 30000,
          jitter: 500,
        );
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

// DOCS-CHECK, NOT A SECURITY TEST
// Round 2 A.3: moved out of test/security/. These asserts are source/docs
// greps (readAsStringSync + contains). They do not demonstrate an attack.

// Phase 3 source guards: Drop-before-Wire, 64-bit peer IDs, UPnP RFC1918,
// no compile-time TURN secrets in CI.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final repoRoot = Directory.current;

  String read(String rel) {
    final f = File(
      '${repoRoot.path}${Platform.pathSeparator}'
      '${rel.replaceAll('/', Platform.pathSeparator)}',
    );
    expect(f.existsSync(), isTrue, reason: '$rel is missing');
    return f.readAsStringSync();
  }

  test('Drop frames require a verified handshake (fail-closed)', () {
    final router = read('lib/peer/packet_router.dart');
    expect(router, contains('dropAllowed'));
    expect(router, contains('_dropPermitted'));
    expect(router, contains('kMaxDropFrameBytes'));
    expect(router, contains('ctx.dropAllowed?.call(remoteId) == true'));

    final conns = read('lib/state/connections_notifier.dart');
    expect(
      conns,
      contains(
        'dropAllowed: (rid) => isVerified(rid) && '
        '!_messaging.isPeerBlocked(rid)',
      ),
    );

    final drop = read('lib/core/orbits_drop.dart');
    expect(drop, contains('kMaxDropFileBytes'));
    expect(drop, contains('kMaxDropIncoming'));
  });

  test('new peer IDs are 64-bit; legacy 24-bit still accepted', () {
    final identity = read('lib/core/identity.dart');
    expect(identity, contains(r'[0-9A-F]{6}(?:[0-9A-F]{10})?'));
    expect(identity, contains('generate(8'));
    expect(identity, isNot(contains('generate(3')));
  });

  test('UPnP fetches are RFC1918-only and do not follow redirects', () {
    final parse = read('lib/peer/upnp_parse.dart');
    expect(parse, contains('isAllowedUpnpUri'));
    expect(parse, contains('_isRfc1918Ipv4'));

    final mapper = read('lib/peer/upnp_port_mapper.dart');
    expect(mapper, contains('isAllowedUpnpUri'));
    expect(mapper, contains('followRedirects = false'));
    expect(mapper, contains('_readLimited'));
  });

  test('CI does not bake TURN username/credential as dart-defines', () {
    for (final rel in [
      '.github/workflows/build.yml',
      '.github/workflows/pages.yml',
    ]) {
      final yml = read(rel);
      expect(yml, isNot(contains('--dart-define=TURN_USERNAME')));
      expect(yml, isNot(contains('--dart-define=TURN_CREDENTIAL')));
      expect(yml, isNot(contains('secrets.TURN_USERNAME')));
      expect(yml, isNot(contains('secrets.TURN_CREDENTIAL')));
      expect(yml, contains('--dart-define=TURN_URL'));
    }

    final provider = read('lib/state/peer_connection_provider.dart');
    expect(provider, contains('ALLOW_COMPILE_TIME_TURN_SECRETS'));
    expect(provider, contains('compileTimeTurnSecret'));
    expect(provider, contains('loadTurnRuntimeCreds'));
    expect(provider, contains('applyTurnRuntime'));
  });
}

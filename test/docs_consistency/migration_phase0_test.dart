// DOCS-CHECK, NOT A SECURITY TEST.
// Phase 0 lock: migration ADRs exist and do not collapse layers.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/peer/room_disclaimer.dart';
import 'package:orbits_flutter/replication/corestore_addon.dart';
import 'package:orbits_flutter/transport/bare_runtime.dart';
import 'package:orbits_flutter/transport/fleet_status.dart';
import 'package:orbits_flutter/transport/layers.dart';
import 'package:orbits_flutter/transport/peerjs_window.dart';
import 'package:orbits_flutter/transport/relay_directory.dart';

void main() {
  String read(String rel) {
    final f = File(rel.replaceAll('/', Platform.pathSeparator));
    expect(f.existsSync(), isTrue, reason: '$rel is missing');
    return f.readAsStringSync();
  }

  test('Phase 0 migration docs exist', () {
    for (final rel in const [
      'docs/migration/README.md',
      'docs/migration/ADR-0001-layer-separation.md',
      'docs/migration/ADR-0002-holepunch-stack.md',
      'docs/migration/threat-model.md',
      'docs/migration/transport-api.md',
      'docs/migration/lifecycle.md',
      'docs/migration/relay-mailbox.md',
      'docs/migration/pwa-versioning-metrics.md',
      'docs/migration/master-plan.md',
      'docs/migration/phase-status.md',
      'docs/migration/phase1-harness.md',
      'docs/migration/relay-runbook.md',
      'docs/migration/app-review-notes.md',
      'docs/migration/store-data-safety.json',
      'docs/migration/test-strategy.md',
      'docs/migration/rollout.md',
      'docs/migration/phase13-group-e2e-review.md',
      'docs/migration/peerjs-support-window.md',
      'tool/connectivity_harness/BUNDLE.manifest',
      'tool/connectivity_harness/BARE_MODULES.manifest',
      'tool/bare/BARE.manifest',
      'tool/bare/addons/CORESTORE.manifest',
      'tool/sbom/ORBITS.sbom.json',
    ]) {
      expect(File(rel).existsSync(), isTrue, reason: '$rel missing');
    }
  });

  test('ADR-0001 keeps the five layers distinct', () {
    final adr = read('docs/migration/ADR-0001-layer-separation.md');
    expect(adr, contains('**Identity**'));
    expect(adr, contains('**Transport**'));
    expect(adr, contains('**Replication**'));
    expect(adr, contains('**Mailbox**'));
    expect(adr, contains('**Drift**'));
    expect(adr, contains('Noise public key'));
    expect(adr, contains('Contact is not blocked'));
    expect(adr, isNot(contains('Noise is the identity key')));
  });

  test('threat model forbids Peer-ID DHT topics', () {
    final threat = read('docs/migration/threat-model.md');
    expect(threat, contains('orbits-contact-discovery-v1'));
    expect(threat, contains('There is no `topicFromPeerId`'));
    expect(threat, contains('opaqueWakeToken'));
  });

  test('rooms and security docs point at the migration', () {
    expect(read('docs/rooms.md'), contains('docs/migration/README.md'));
    expect(read('docs/security.md'), contains('docs/migration/'));
    expect(kRoomsApplicationE2eImplemented, isFalse);
  });

  test('default flags do not enable Hyperswarm', () {
    resetFlagsForTests();
    expect(kCompletedMigrationPhase, 0);
    expect(isHyperswarmTransportEnabled(), isFalse);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(kRoomsApplicationE2eImplemented, isFalse);
    expect(kPeerjsSupportWindowOpen, isTrue);
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(peerjsIsProductPath(), isTrue);
    expect(kLiveStorageFleet, isFalse);
    expect(kLiveSignedRelayDirectory, isFalse);
    expect(kBareBinaryShipped, isFalse);
    expect(kHolepunchCorestoreAddonLinked, isFalse);
    final roomCrypto = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last == 'room_crypto.dart');
    expect(roomCrypto, isEmpty, reason: 'no lib/**/room_crypto.dart');
  });

  test('Phase 0/1 docs stay honest about PeerJS default and pending NAT', () {
    final status = read('docs/migration/phase-status.md');
    expect(status, contains('kCompletedMigrationPhase'));
    expect(status, contains('scaffold ready / hardware-NAT validation'));
    expect(status, contains('npm test'));
    expect(status, contains('cli_two_process.test.js'));
    expect(status, isNot(contains('Phase 1 closed')));
    final harness = read('docs/migration/phase1-harness.md');
    expect(harness, contains('scaffold ready / hardware-NAT validation pending'));
    expect(harness, contains('npm test'));
    expect(harness, contains('cli_two_process.test.js'));
    final plan = read('docs/migration/master-plan.md');
    expect(plan, contains('Scaffold ready / hardware-NAT validation pending'));
    expect(plan, isNot(contains('Phase 1 closed')));
  });

  test('store-review packet is not filed and stays honest', () {
    final raw = jsonDecode(read('docs/migration/store-data-safety.json'));
    expect(raw, isA<Map>());
    final packet = Map<String, Object?>.from(raw as Map);
    expect(packet['filed'], isFalse);
    expect(packet['pwaOfficialMode'], 'compatibility-client-on-PeerJS');
    expect(packet['pwaFinalFateChosen'], isFalse);
    expect(packet['kRoomsApplicationE2eImplemented'], isFalse);
    expect(packet['kLiveApnsGateway'], isFalse);
    expect(packet['kLiveFcmGateway'], isFalse);
    expect(packet['kLiveStorageFleet'], isFalse);
    expect(packet['kLiveSignedRelayDirectory'], isFalse);
    expect(packet['kBareBinaryShipped'], isFalse);
    expect(packet['kHolepunchCorestoreAddonLinked'], isFalse);
    expect(packet['voipBackgroundMode'], isFalse);
    expect(packet['collectsMessageBodies'], isFalse);
    expect(packet['defaultLivePath'], 'PeerJS');
    final export = Map<String, Object?>.from(packet['encryptionExport'] as Map);
    expect(export['customMilitaryClaims'], isFalse);
    expect(export['usesStandardHttps'], isTrue);

    final pwa = read('docs/migration/pwa-versioning-metrics.md');
    expect(pwa, contains('compatibility client on PeerJS'));
    expect(pwa, contains('pwaOfficialMode'));
    expect(pwa, contains('pwaFinalFateChosen'));
    expect(pwa, contains('**not** chosen'));
    expect(
      read('docs/migration/app-review-notes.md'),
      contains('pwaOfficialMode'),
    );
  });
}

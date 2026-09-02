import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/mailbox_protocol.dart';
import 'package:orbits_flutter/transport/layers.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/relay_directory.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

void main() {
  test('pinned protocol namespaces stay stable', () {
    expect(kOrbitsTransportFrameInfo, 'orbits-transport-v1');
    expect(kReplicationEventInfo, 'orbits-repl-event-v1');
    expect(kMailboxHttpVersion, 'orbits-mailbox-http-v1');
    expect(kRelayDirectoryInfo, 'orbits-relay-directory-v1');
    expect(kCompletedMigrationPhase, 0);
    final ipc = File(
      'packages/orbits_transport_platform_interface/lib/orbits_transport_platform_interface.dart',
    ).readAsStringSync();
    expect(ipc, contains("kOrbitsBareIpcInfo = 'orbits-bare-ipc-v1'"));
  });
}

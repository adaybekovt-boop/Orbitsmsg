import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/journal_file_stub.dart';
import 'package:orbits_flutter/transport/native_transport_host_stub.dart';

void main() {
  test('web journal stub accepts ownerPeerId and is not a durable store',
      () async {
    final journal = await openLocalFileJournal(
      'device-a',
      ownerPeerId: 'ORBIT-ALICE',
    );
    expect(journal, isNull);
    final other = await openLocalFileJournal(
      'device-b',
      ownerPeerId: 'ORBIT-BOB',
    );
    expect(other, isNull);
  });

  test('web transport host stays on PeerJS and never looks attached', () {
    final host = NativeTransportHost();
    expect(host.attached, isFalse);
    expect(host.backend, 'none');
    expect(host.visibleTransportLabel, 'PeerJS');
    expect(host.routeDiagnostics['reason'], 'web');
  });
}

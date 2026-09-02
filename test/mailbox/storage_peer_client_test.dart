import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/storage_peer_client.dart';
import 'package:orbits_flutter/transport/layers.dart';

void main() {
  test('storage peer bodies reject plaintext and anonymous tokens', () {
    expect(
      storagePeerBodyIsSafe({
        'token': 'cap',
        'writerKey': 'w',
        'seq': 0,
        'b64': 'YQ==',
      }),
      isTrue,
    );
    expect(
      storagePeerBodyIsSafe({
        'token': 'cap',
        'writerKey': 'w',
        'b64': 'YQ==',
        'plaintext': 'x',
      }),
      isFalse,
    );
    expect(
      storagePeerBodyIsSafe({
        'token': '',
        'writerKey': 'w',
        'b64': 'YQ==',
      }),
      isFalse,
    );
    expect(storagePeerGrantIsSafe({'token': 'cap'}), isTrue);
    expect(storagePeerGrantIsSafe({'token': ''}), isFalse);
    expect(storagePeerGrantIsSafe({'token': 'cap', 'kek': 'x'}), isFalse);
  });

  test('storage peer forbidden keys cover Hypercore replication fields', () {
    expect(
      kStoragePeerForbiddenKeys.containsAll(kForbiddenReplicationFields),
      isTrue,
    );
    expect(kStoragePeerForbiddenKeys.contains('text'), isTrue);
    expect(kStoragePeerForbiddenKeys.contains('body'), isTrue);
    expect(kStoragePeerForbiddenKeys.contains('peerId'), isTrue);
    expect(kStoragePeerForbiddenKeys.contains('b64'), isFalse);
  });

  test('storage peer bodies reject file keys, discovery, and ratchet scalars', () {
    const safe = <String, Object?>{
      'token': 'cap',
      'writerKey': 'w',
      'seq': 0,
      'b64': 'YQ==',
    };
    expect(storagePeerBodyIsSafe(safe), isTrue);

    for (final key in <String>[
      'fileKey',
      'fileKeyB64',
      'discoverySecret',
      'sendCk',
      'recvCk',
      'dhPriv',
    ]) {
      expect(
        storagePeerBodyIsSafe({...safe, key: 'x'}),
        isFalse,
        reason: 'forbidden key $key must be rejected',
      );
    }
    expect(storagePeerGrantIsSafe({'token': 'cap', 'fileKey': 'x'}), isFalse);
  });
}

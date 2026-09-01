import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/storage_peer_client.dart';

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
}

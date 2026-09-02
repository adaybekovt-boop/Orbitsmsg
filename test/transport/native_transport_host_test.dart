import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resume drain re-checks the relay directory', () {
    final src =
        File('lib/transport/native_transport_host.dart').readAsStringSync();
    final resume = src.split('onResumeDrain:')[1].split('wake =')[0];
    expect(resume, contains('loadRelayDirectoryFromEnv'));
    expect(resume, contains('checkRelayDirectory'));
    expect(
      resume.indexOf('loadRelayDirectoryFromEnv'),
      lessThan(resume.indexOf('drainMailbox')),
    );
    expect(
      resume.indexOf('checkRelayDirectory'),
      lessThan(resume.indexOf('drainMailbox')),
    );
  });
}

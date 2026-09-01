import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Drop prefers a filesystem path and does not force picker bytes on native', () {
    final page = File('lib/pages/drop_page.dart').readAsStringSync();
    expect(page, contains('sendFileFromPath'));
    expect(page, contains('withData: kIsWeb'));
    expect(page, isNot(contains('withData: true')));
    final provider = File('lib/state/drop_provider.dart').readAsStringSync();
    expect(provider, contains('sendFileFromPath'));
    expect(provider, contains('TransportFileDescriptor'));
    expect(
      File('lib/transport/native_transport_host.dart').readAsStringSync(),
      contains('rollbackNativeToPeerjs'),
    );
  });
}

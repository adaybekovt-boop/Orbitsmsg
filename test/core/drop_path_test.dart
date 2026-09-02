import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Drop prefers a filesystem path and does not force picker bytes on native', () {
    final page = File('lib/pages/drop_page.dart').readAsStringSync();
    expect(page, contains('sendFileFromPath'));
    expect(page, contains('withReadStream: kIsWeb'));
    expect(page, contains('sendFileFromStream'));
    expect(page, contains('withData: false'));
    expect(
      File('lib/core/orbits_drop.dart').readAsStringSync(),
      contains('DartSha256().newHashSink()'),
    );
    expect(page, isNot(contains('withData: true')));
    expect(page, isNot(contains('withData: kIsWeb')));
    final provider = File('lib/state/drop_provider.dart').readAsStringSync();
    expect(provider, contains('sendFileFromPath'));
    expect(provider, contains('TransportFileDescriptor'));
    expect(provider, contains('harness-file-received'));
    expect(provider, contains('localPath'));
    expect(provider, contains('resumeOffset'));
    expect(provider, contains('openPeerJsDropStore'));
    expect(provider, contains('persistIncomingPath'));
    expect(provider, contains('sendDropFileFromFilesystem'));
    expect(provider, contains('sendFileFromIncomingStream'));
    expect(provider, contains('sendFileFromStream'));
    expect(page, contains('t.localPath'));
    expect(page, isNot(contains('File(pf.path!).readAsBytes')));
    expect(
      File('lib/transport/native_transport_host.dart').readAsStringSync(),
      contains('rollbackNativeToPeerjs'),
    );
  });
}

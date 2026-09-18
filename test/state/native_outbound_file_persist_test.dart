import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native outbound file persist is path + sha256, not Drift blob bytes', () {
    final src = File('lib/state/messaging_notifier.dart').readAsStringSync();
    expect(src, contains('useNativePath'));
    expect(src, contains('outboundPath == null ? bytes : const <int>[]'));
    expect(src, contains('sha256hex: outboundSha'));
    expect(src, contains("if (outboundSha != null) 'sha256': outboundSha"));
    expect(src, contains('path: outboundPath'));
  });
}

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

  test('native sendFile failure does not fall through to b64EncodeHeavy', () {
    final src = File('lib/state/messaging_notifier.dart').readAsStringSync();
    final start = src.indexOf('await conns.sendFile(');
    expect(start, isNot(-1));
    final after = src.substring(start, start + 2200);
    // The native catch records diagnostics and returns: the b64 path
    // below is unreachable for native peers.
    expect(after, contains('lastReplicationError'));
    expect(after, contains('return msgId'));
    final beforeB64 = after.split('final b64').first;
    expect(beforeB64, contains('catch'));
    expect(beforeB64, isNot(contains('b64EncodeHeavy')));
  });
}

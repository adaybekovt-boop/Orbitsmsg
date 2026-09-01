import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/discovery.dart';

void main() {
  test('Dart topic matches the harness JS implementation', () async {
    final secret = List<int>.generate(32, (i) => i + 1);
    final dart = await contactDiscoveryTopic(secret);
    final dartHex = dart.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    final node = await Process.run('node', [
      '-e',
      "const {contactDiscoveryTopic}=require('./src/discovery');"
          "const s=Buffer.from([${secret.join(',')}]);"
          "process.stdout.write(contactDiscoveryTopic(s).toString('hex'));",
    ], workingDirectory: 'tool/connectivity_harness');

    if (node.exitCode != 0) {
      markTestSkipped('node harness unavailable: ${node.stderr}');
      return;
    }
    expect((node.stdout as String).trim(), dartHex);
  }, skip: !File('tool/connectivity_harness/src/discovery.js').existsSync()
      ? 'harness missing'
      : false);
}

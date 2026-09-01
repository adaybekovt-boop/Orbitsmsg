import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/discovery.dart';

void main() {
  final secret = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));

  test('same secret yields the same 32-byte topic', () async {
    final a = await contactDiscoveryTopic(secret);
    final b = await contactDiscoveryTopic(secret);
    expect(a.length, 32);
    expect(a, b);
  });

  test('contact and room domains do not collide', () async {
    final contact = await contactDiscoveryTopic(secret);
    final room = await roomDiscoveryTopic(secret);
    expect(contact, isNot(equals(room)));
  });

  test('empty secret is rejected', () async {
    expect(contactDiscoveryTopic(const <int>[]), throwsArgumentError);
  });

  test('topic is not HASH(public peer id)', () async {
    final peerId = utf8.encode('ORBIT-0123456789ABCDEF');
    final naive = await Sha256().hash(peerId);
    final topic = await contactDiscoveryTopic(secret);
    expect(topic, isNot(equals(naive.bytes)));
    expect(topic, isNot(equals(peerId)));
  });

  test('source has no topicFromPeerId helper', () {
    final src = File('lib/transport/discovery.dart').readAsStringSync();
    expect(src, contains('intentionally no topicFromPeerId'));
    expect(src, isNot(contains('topicFromPeerId(')));
    expect(src, isNot(contains('topicFromIdentitySpki(')));
  });
}

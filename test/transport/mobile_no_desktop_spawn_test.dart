import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mobile host path never installs LocalWorkletPlatform or probes Process.start', () {
    final host = File('lib/transport/native_transport_host.dart').readAsStringSync();
    expect(host, contains('isMobileBareHost()'));
    expect(host, contains('if (isMobileBareHost()) return;'));
    expect(host, contains('PluginOrbitsTransport(backend: \'hyperswarm\')'));
    expect(
      host.contains('if (isMobileBareHost())') &&
          host.contains('spawnWorklet(backend:'),
      isTrue,
    );
    final choose = host.split('Future<OrbitsTransport?> _chooseTransport').last;
    final mobileBranch = choose.split('if (isMobileBareHost())').elementAt(1);
    final untilDesktop = mobileBranch.split('final inProcess').first;
    expect(untilDesktop, isNot(contains('spawnWorklet')));
    expect(untilDesktop, isNot(contains('Process.start')));
  });

  test('Android and iOS plugins do not spawn a desktop bare process', () {
    final android = File(
      'packages/orbits_transport_android/android/src/main/kotlin/app/orbits/transport/OrbitsBareRuntime.kt',
    ).readAsStringSync();
    expect(android, isNot(contains('ProcessBuilder')));
    expect(android, contains('to.holepunch.bare.kit.IPC'));
    expect(android, contains('request("start"'));
    final plugin = File(
      'packages/orbits_transport_android/android/src/main/kotlin/app/orbits/transport/OrbitsTransportPlugin.kt',
    ).readAsStringSync();
    expect(RegExp(r'request\(\s*"send"').hasMatch(plugin), isTrue);
    expect(RegExp(r'request\(\s*"sendFile"').hasMatch(plugin), isTrue);
    expect(RegExp(r'request\(\s*"publish"').hasMatch(plugin), isTrue);
    expect(RegExp(r'request\(\s*"connect"').hasMatch(plugin), isTrue);
    expect(plugin, contains('OrbitsBareRuntime.stopSession()'));
    final ios = File(
      'packages/orbits_transport_ios/ios/Classes/OrbitsBareRuntime.swift',
    ).readAsStringSync();
    expect(ios, contains('BareIPC'));
    expect(ios, contains('request("start"'));
    expect(ios, isNot(contains('Process()')));
  });

  test('defaultTargetPlatform android is classified as mobile', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(
      File('lib/transport/dev_bare_transport.dart').readAsStringSync(),
      contains('TargetPlatform.android'),
    );
  });
}

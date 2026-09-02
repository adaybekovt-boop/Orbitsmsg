import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/state/drop_provider.dart';
import 'package:orbits_flutter/transport/peerjs_window.dart';

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

  test('DropNotifier fail-closes PeerJS send when isolation forbids it', () {
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
    expect(peerjsAllowedOnNative(), isTrue);

    final src = File('lib/state/drop_provider.dart').readAsStringSync();
    expect(src, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(src, isNot(contains('peerjsAllowedOnNative()')));
    expect(src, contains('canUseNative'));
    expect(src, contains('_isolationBlocksPeerjsDrop'));

    String slice(String start, String end) => src.split(start)[1].split(end)[0];

    final helper = slice(
      'bool _isolationBlocksPeerjsDrop',
      'String _failOutboundIsolated',
    );
    expect(helper, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(helper, contains('canUseNative'));
    expect(helper, isNot(contains('peerjsAllowedOnNative()')));

    void expectSendGated(String body) {
      expect(body, contains('_isolationBlocksPeerjsDrop'));
      expect(body, contains('_failOutboundIsolated'));
      expect(body, contains('DropStatus.failed'));
      final gateIdx = body.indexOf('_isolationBlocksPeerjsDrop');
      final openIdx = body.indexOf('openReliable');
      expect(gateIdx, greaterThanOrEqualTo(0));
      expect(openIdx, greaterThan(gateIdx));
    }

    expectSendGated(
      slice('Future<String?> sendFile(', 'Future<String?> sendFileFromStream'),
    );
    expectSendGated(
      slice(
        'Future<String?> sendFileFromStream',
        'Future<String?> sendFileFromPath',
      ),
    );

    final sendPath = slice('Future<String?> sendFileFromPath', 'void cancel(');
    expectSendGated(sendPath);
    expect(sendPath, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(sendPath, contains('conns.sendFileFromPath'));
    expect(sendPath, contains('TransportFileDescriptor'));
    expect(sendPath, contains('sendDropFileFromFilesystem'));
    final nativeCall = sendPath.indexOf('conns.sendFileFromPath');
    final peerjsFallback = sendPath.indexOf('sendDropFileFromFilesystem');
    expect(nativeCall, greaterThan(sendPath.indexOf('_isolationBlocksPeerjsDrop')));
    expect(peerjsFallback, greaterThan(nativeCall));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
  });

  test('isolation blocks PeerJS Drop only when native cannot take the file', () {
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    bool blocked({
      required String mode,
      required bool isWeb,
      required bool canUseNative,
    }) =>
        !peerjsAllowedOnNativeFor(mode, isWeb: isWeb) && !canUseNative;

    expect(
      blocked(
        mode: kPeerjsIsolationDefaultLive,
        isWeb: false,
        canUseNative: false,
      ),
      isFalse,
    );
    expect(
      blocked(
        mode: kPeerjsIsolationWebOnly,
        isWeb: false,
        canUseNative: false,
      ),
      isTrue,
    );
    expect(
      blocked(
        mode: kPeerjsIsolationWebOnly,
        isWeb: false,
        canUseNative: true,
      ),
      isFalse,
    );
    expect(
      blocked(
        mode: kPeerjsIsolationWebOnly,
        isWeb: true,
        canUseNative: false,
      ),
      isFalse,
    );
    expect(
      blocked(
        mode: kPeerjsIsolationRemoved,
        isWeb: false,
        canUseNative: false,
      ),
      isTrue,
    );
  });

  test('DropNotifier fail-closes leftover PeerJS inbound when isolation forbids it',
      () {
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
    expect(peerjsAllowedOnNative(), isTrue);

    final src = File('lib/state/drop_provider.dart').readAsStringSync();
    expect(src, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(src, isNot(contains('peerjsAllowedOnNative()')));
    expect(src, contains('_isolationBlocksPeerjsDrop'));

    final inbound = src
        .split('handleInbound: (remoteId, packet)')[1]
        .split('resetPeer:')[0];

    expect(inbound, contains('_pendingInboundPeer = remoteId'));
    expect(inbound, contains('_handleNativePathPacket'));
    expect(inbound, contains('_isolationBlocksPeerjsDrop'));
    expect(inbound, contains('_engine.handleInbound'));

    final nativeIdx = inbound.indexOf('_handleNativePathPacket');
    final gateIdx = inbound.indexOf('_isolationBlocksPeerjsDrop');
    final engineIdx = inbound.indexOf('_engine.handleInbound');
    expect(nativeIdx, greaterThanOrEqualTo(0));
    expect(gateIdx, greaterThan(nativeIdx));
    expect(engineIdx, greaterThan(gateIdx));

    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test('DropNotifier harness-file path refuses nested secrets and remote URLs',
      () {
    final src = File('lib/state/drop_provider.dart').readAsStringSync();
    expect(src, contains('harnessFilePacketIsSafe'));
    expect(src, contains('replicationValueIsSafe'));
    expect(src, contains('kForbiddenReplicationFields'));
    expect(src, contains('sanitizeDropFileName'));
    expect(src, contains("contains('://')"));
    expect(src, contains("contains('fileKey')"));
    expect(src, contains("contains('opaqueWakeToken')"));

    final handler = src
        .split('bool _handleNativePathPacket')[1]
        .split('Future<bool> _persistIncoming')[0];
    expect(handler, contains('harnessFilePacketIsSafe'));
    expect(handler, contains('sanitizeDropFileName'));
    final safetyIdx = handler.indexOf('harnessFilePacketIsSafe');
    final typeIdx = handler.indexOf("packet['type']");
    expect(safetyIdx, greaterThanOrEqualTo(0));
    expect(typeIdx, greaterThan(safetyIdx));
  });

  test('harnessFilePacketIsSafe rejects nested fileKey on harness-file-start',
      () {
    expect(
      harnessFilePacketIsSafe({
        'type': 'harness-file-start',
        'id': 'x',
        'name': 'ok',
        'meta': {'fileKey': 'k'},
      }),
      isFalse,
    );
  });

  test('harnessFilePacketIsSafe rejects remote URL path on harness-file-received',
      () {
    expect(
      harnessFilePacketIsSafe({
        'type': 'harness-file-received',
        'id': 'x',
        'path': 'https://evil/file',
      }),
      isFalse,
    );
  });

  test('harnessFilePacketIsSafe accepts local path on harness-file-received',
      () {
    expect(
      harnessFilePacketIsSafe({
        'type': 'harness-file-received',
        'id': 'x',
        'path': '/tmp/ok.bin',
      }),
      isTrue,
    );
  });

  test('harnessFilePacketIsSafe accepts harness-file-start without secrets', () {
    expect(
      harnessFilePacketIsSafe({
        'type': 'harness-file-start',
        'id': 'x',
        'name': 'ok.jpg',
        'size': 1,
      }),
      isTrue,
    );
  });

  test(
      'harnessFilePacketIsSafe rejects fileKey or opaqueWakeToken in received path',
      () {
    expect(
      harnessFilePacketIsSafe({
        'type': 'harness-file-received',
        'id': 'x',
        'path': '/tmp/fileKey-secret',
      }),
      isFalse,
    );
    expect(
      harnessFilePacketIsSafe({
        'type': 'harness-file-received',
        'id': 'x',
        'path': '/tmp/opaqueWakeToken-leak',
      }),
      isFalse,
    );
  });
}

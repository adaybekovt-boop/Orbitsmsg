import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/calls/native_call_machine.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';
import 'package:orbits_flutter/calls/opaque_call_handle.dart';
import 'package:orbits_flutter/calls/system_calling.dart';
import 'package:flutter/services.dart';

void main() {
  test('duplicate and reordered signals are idempotent', () async {
    final sent = <CallSignal>[];
    final machine = NativeCallMachine(send: (s) async => sent.add(s));
    await machine.startOutgoing(callId: 'c1', sdp: 'offer');
    machine.applyRemote(
      const CallSignal(type: CallSignalType.answer, callId: 'c1', sdp: 'ans'),
    );
    machine.applyRemote(
      const CallSignal(type: CallSignalType.answer, callId: 'c1', sdp: 'ans'),
    );
    machine.applyRemote(
      const CallSignal(
        type: CallSignalType.iceCandidate,
        callId: 'c1',
        candidate: {'candidate': '1'},
      ),
    );
    expect(machine.phase, NativeCallPhase.connected);
    expect(machine.remoteIce, hasLength(1));
    await machine.hangup();
    await machine.hangup();
    expect(machine.closed, isTrue);
    expect(sent.where((s) => s.type == CallSignalType.hangup), hasLength(1));
  });

  test('glare keeps the smaller call id', () async {
    final machine = NativeCallMachine(send: (_) async {});
    await machine.startOutgoing(callId: 'c9', sdp: 'local');
    machine.applyRemote(
      const CallSignal(type: CallSignalType.offer, callId: 'c1', sdp: 'remote'),
    );
    expect(machine.callId, 'c1');
    expect(machine.phase, NativeCallPhase.ringing);
  });

  test('timeout after network change closes an unanswered offer', () async {
    var now = 1000;
    final machine = NativeCallMachine(
      send: (_) async {},
      nowMs: () => now,
      offerTimeoutMs: 10,
    );
    await machine.startOutgoing(callId: 'c1', sdp: 'offer');
    now = 1020;
    machine.recoverAfterNetworkChange();
    expect(machine.closed, isTrue);
  });

  test('CallKit adapter stays opaque', () async {
    final calls = <MethodCall>[];
    final channel = const MethodChannel('app.orbits/calling');
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    final calling = SystemCalling(channel: channel);
    await calling.reportIncoming(callId: 'ORBIT-AAAAAAAAAAAAAAAA');
    expect(calls, isNotEmpty);
    final args = calls.first.arguments as Map;
    expect(args['displayName'], kSystemCallDisplayName);
    expect(args['opaqueCallId'], isNot(contains('ORBIT')));
    await calling.endCall('ORBIT-AAAAAAAAAAAAAAAA');
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/mailbox_protocol.dart';
import 'package:orbits_flutter/push/doze_adapter.dart';
import 'package:orbits_flutter/replication/drift_projector.dart';
import 'package:orbits_flutter/replication/file_journal.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/rooms/autobase_log.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/ipc_codec.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/transport_lifecycle.dart';

void main() {
  test(
    'corrupt and truncated journal lines do not wipe earlier events',
    () async {
      final lines = <String>[];
      final journal = FileJournal(
        writerDeviceId: 'dev-a',
        writeLine: (line) async => lines.add(line),
        readLines: () async => List<String>.from(lines),
      );
      await journal.append(
        const JournalRecord(
          seq: 0,
          writerDeviceId: 'dev-a',
          kind: ReplicationEventKind.messageEnvelopeCreated,
          fields: {
            'eventId': 'e1',
            'conversationId': 'c1',
            'senderIdentity': 'alice',
            'senderDeviceId': 'dev-a',
            'encryptedEnvelope': <int>[72, 105],
          },
        ),
      );
      lines.add('{not-json');
      lines.add(
        jsonEncode({
          'seq': 2,
          'writerDeviceId': 'dev-a',
          'kind': 'unknownFutureKind',
          'fields': {'eventId': 'e-bad'},
        }),
      );
      await journal.append(
        const JournalRecord(
          seq: 3,
          writerDeviceId: 'dev-a',
          kind: ReplicationEventKind.messageEnvelopeCreated,
          fields: {
            'eventId': 'e2',
            'conversationId': 'c1',
            'senderIdentity': 'alice',
            'senderDeviceId': 'dev-a',
            'encryptedEnvelope': <int>[66, 121],
          },
        ),
      );

      final replayed = await journal.replay();
      final projector = JournalProjector(
        decrypt: (enc) async => {'text': String.fromCharCodes(enc)},
      );
      await projector.applyAll(replayed);
      expect(projector.messages['e1']?.plaintext, 'Hi');
      expect(projector.messages['e2']?.plaintext, 'By');
      expect(projector.messages.containsKey('e-bad'), isFalse);
    },
  );

  test('disk-full append fails closed and does not half-project', () async {
    var full = false;
    final lines = <String>[];
    final journal = FileJournal(
      writerDeviceId: 'dev-a',
      writeLine: (line) async {
        if (full) throw StateError('ENOSPC');
        lines.add(line);
      },
      readLines: () async => List<String>.from(lines),
    );
    await journal.append(
      const JournalRecord(
        seq: 0,
        writerDeviceId: 'dev-a',
        kind: ReplicationEventKind.messageEnvelopeCreated,
        fields: {
          'eventId': 'e1',
          'encryptedEnvelope': <int>[65],
        },
      ),
    );
    full = true;
    await expectLater(
      journal.append(
        const JournalRecord(
          seq: 1,
          writerDeviceId: 'dev-a',
          kind: ReplicationEventKind.messageEnvelopeCreated,
          fields: {
            'eventId': 'e2',
            'encryptedEnvelope': <int>[66],
          },
        ),
      ),
      throwsA(isA<StateError>()),
    );
    final replayed = await journal.replay();
    expect(replayed.length, 1);
    expect(replayed.records.single.fields['eventId'], 'e1');
  });

  test(
    'storage peer loss leaves mailbox drain empty until the peer returns',
    () async {
      final store = BlindMailboxStore()
        ..grant(
          MailboxCapability(
            token: 'tok',
            quotaBytes: 1024,
            retentionMs: 60 * 1000,
            expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
          ),
        );
      store.put(
        token: 'tok',
        writerKey: 'alice',
        block: EncryptedBlock(
          seq: 0,
          bytes: wrapOpaqueEnvelope(Uint8List.fromList([1, 2, 3])),
          storedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      expect(store.get(token: 'tok', writerKey: 'alice').length, 1);
      store.tombstone('tok', 'alice', 0);
      expect(store.get(token: 'tok', writerKey: 'alice'), isEmpty);
    },
  );

  test('expired device certificate is rejected before persist', () {
    final binding = DeviceBinding(
      version: kDeviceBindingVersion,
      identityPublicKey: Uint8List.fromList(List<int>.filled(32, 1)),
      deviceId: 'dev-a',
      transportPublicKey: Uint8List.fromList(List<int>.filled(32, 2)),
      hypercorePublicKey: Uint8List.fromList(List<int>.filled(32, 3)),
      capabilities: const ['hyperswarm-v1'],
      createdAt: 1_000,
      expiresAt: 2_000,
      signatureByIdentityKey: Uint8List.fromList(List<int>.filled(64, 4)),
    );
    expect(deviceBindingClockIsValid(binding, nowMs: 1_500), isTrue);
    expect(deviceBindingClockIsValid(binding, nowMs: 2_001), isFalse);
    expect(
      deviceBindingClockIsValid(
        DeviceBinding(
          version: kDeviceBindingVersion,
          identityPublicKey: binding.identityPublicKey,
          deviceId: 'dev-future',
          transportPublicKey: binding.transportPublicKey,
          hypercorePublicKey: binding.hypercorePublicKey,
          capabilities: const ['hyperswarm-v1'],
          createdAt: 10_000_000,
          expiresAt: 11_000_000,
          signatureByIdentityKey: binding.signatureByIdentityKey,
        ),
        nowMs: 1_500,
      ),
      isFalse,
    );
  });

  test(
    'worklet-style crash plus Flutter restart replay the same Drift state',
    () async {
      final durable = FileJournal.memory('dev-a');
      final live = MemoryJournal('dev-a');
      final event = live.appendEnvelope(
        const MessageEnvelopeCreated(
          eventId: 'e1',
          conversationId: 'c1',
          senderIdentity: 'alice',
          senderDeviceId: 'dev-a',
          logicalSequence: 1,
          createdAt: 1,
          encryptedEnvelope: <int>[72, 105],
        ),
      );
      await durable.append(event);

      Future<Map<String, Object?>?> decrypt(List<int> enc) async => {
        'text': String.fromCharCodes(enc),
      };
      final beforeCrash = JournalProjector(decrypt: decrypt);
      await beforeCrash.applyAll(live);

      final afterRestart = JournalProjector(decrypt: decrypt);
      await afterRestart.applyAll(await durable.replay());
      expect(
        afterRestart.messages['e1']?.plaintext,
        beforeCrash.messages['e1']?.plaintext,
      );
      expect(afterRestart.cursor, beforeCrash.cursor);
    },
  );

  test(
    'Doze plus network refresh reconnects without keeping an incoming socket',
    () async {
      final transport = LoopbackOrbitsTransport();
      await transport.start(
        const TransportLocalConfiguration(
          peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
          discoverySecret: [9, 8, 7],
        ),
      );
      final life = TransportLifecycle(transport: transport);
      final doze = DozeAdapter(lifecycle: life);
      await doze.enterDoze();
      expect(doze.socketAlive, isFalse);
      await expectLater(
        transport.send(
          'ORBIT-BBBBBBBBBBBBBBBB',
          TransportChannel.message,
          const [1],
        ),
        throwsStateError,
      );
      await doze.onForeground();
      expect(doze.socketAlive, isTrue);
      expect(doze.reconnectAttempts, 1);
    },
  );

  test('Autobase partition, reorder, and revoked writer still converge', () {
    final events = <RoomEvent>[
      const RoomEvent(
        writerId: 'w2',
        seq: 1,
        kind: 'membership',
        payload: {'peerId': 'bob', 'action': 'join', 'displayName': 'Bob'},
      ),
      const RoomEvent(
        writerId: 'w1',
        seq: 1,
        kind: 'membership',
        payload: {'peerId': 'alice', 'action': 'join', 'displayName': 'Alice'},
      ),
      const RoomEvent(
        writerId: 'w1',
        seq: 2,
        kind: 'role',
        payload: {'peerId': 'alice', 'role': 'owner'},
      ),
      const RoomEvent(
        writerId: 'w2',
        seq: 2,
        kind: 'message',
        payload: {'id': 'm1', 'text': 'hello'},
      ),
      const RoomEvent(
        writerId: 'w2',
        seq: 2,
        kind: 'message',
        payload: {'id': 'm1', 'text': 'hello'},
      ),
    ];
    final left = AutobaseProjection();
    left.applyAll(events);
    final right = AutobaseProjection();
    right.applyAll(events.reversed);
    expect(left.state.members, right.state.members);
    expect(left.state.roles, right.state.roles);
    expect(left.state.messages.length, 1);

    right.revokeWriter('w2');
    right.apply(
      const RoomEvent(
        writerId: 'w2',
        seq: 3,
        kind: 'message',
        payload: {'id': 'm2', 'text': 'after-revoke'},
      ),
    );
    expect(right.state.messages.any((m) => m['id'] == 'm2'), isFalse);
  });

  test('malformed IPC after a clock-skewed capability stays fail-closed', () {
    expect(
      () => OrbitsIpcCodec().add([0, 0, 0, 0, 1, 1, 0, 0, 0, 0]),
      throwsFormatException,
    );
    expect(
      () => OrbitsIpcCodec.encode(
        OrbitsIpcMessage(
          type: kIpcRequest,
          body: {'pad': 'x' * (kOrbitsIpcMaxPayloadBytes + 16)},
        ),
      ),
      throwsFormatException,
    );
  });
}

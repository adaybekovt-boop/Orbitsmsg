// Nested chat-plaintext maps (`sticker` / `replyTo` / `voice`) must not
// persist [kForbiddenReplicationFields] into uiMsg / Drift. A secret-bearing
// map is dropped; the rest of the message (text + ACK) still lands.
// `attachment.fileKeyB64` is assembly-only and must not appear on metaOut.
// `profile_res.profile` with a nested forbidden key is consumed without
// upsertPeer / setProfilesByPeer / avatar persist.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/messaging/message_protocol.dart';
import 'package:orbits_flutter/transport/layers.dart';

ReliableInboundCtx _ctx({
  required Set<String> seen,
  required Set<String> processing,
  required List<JsonMap> persisted,
  required List<JsonMap> acks,
  required Future<InboundPersistResult> Function(String, JsonMap) persist,
  bool Function(String)? isBlocked,
  JsonMap? Function()? localProfile,
  List<(String, JsonMap)>? upserts,
  JsonMap? profilesByPeer,
}) {
  return ReliableInboundCtx(
    selfPeerId: 'ORBIT-SELF',
    localProfile: localProfile ?? () => null,
    seenMsgIds: seen,
    processingMsgIds: processing,
    persistInbound: persist,
    pushMessage: persist,
    isPeerBlocked: isBlocked,
    updateMessage: (_, __, ___) {},
    setProfilesByPeer: (updater) {
      if (profilesByPeer == null) return;
      final next = updater(Map<String, Object?>.from(profilesByPeer));
      profilesByPeer
        ..clear()
        ..addAll(next);
    },
    setMessagesByPeer: (_) {},
    upsertPeer: (id, patch) {
      upserts?.add((id, patch));
    },
    queueAckStatus: (_, __) {},
    sendEncrypted: acks.add,
    notifyNewMessage:
        ({required String from, required String text, required String tag}) {},
    hapticMessage: () {},
    playReceiveSound: () {},
    isAppInForeground: () => false,
  );
}

Future<(List<JsonMap> persisted, List<JsonMap> acks)> _dispatch(
  JsonMap packet,
) async {
  final persisted = <JsonMap>[];
  final acks = <JsonMap>[];
  final ctx = _ctx(
    seen: <String>{},
    processing: <String>{},
    persisted: persisted,
    acks: acks,
    persist: (_, msg) async {
      persisted.add(msg);
      return InboundPersistResult.committed;
    },
  );
  await dispatchReliablePlaintext(packet, (_) {}, 'ORBIT-PEER', ctx);
  return (persisted, acks);
}

Future<
    (
      List<(String, JsonMap)> upserts,
      JsonMap profiles,
      List<JsonMap> sent,
      bool consumed,
    )> _dispatchProfile(
  JsonMap packet, {
  JsonMap? Function()? localProfile,
  JsonMap? initialProfiles,
}) async {
  final upserts = <(String, JsonMap)>[];
  final profiles = initialProfiles ?? <String, Object?>{};
  final sent = <JsonMap>[];
  final ctx = _ctx(
    seen: <String>{},
    processing: <String>{},
    persisted: <JsonMap>[],
    acks: sent,
    persist: (_, msg) async => InboundPersistResult.committed,
    localProfile: localProfile,
    upserts: upserts,
    profilesByPeer: profiles,
  );
  final consumed =
      await dispatchReliablePlaintext(packet, (_) {}, 'ORBIT-PEER', ctx);
  return (upserts, profiles, sent, consumed);
}

void _expectNoSecretKeys(Object? value) {
  if (value is Map) {
    expect(
      value.keys.map((k) => '$k').toSet().intersection(kForbiddenReplicationFields),
      isEmpty,
    );
    for (final nested in value.values) {
      _expectNoSecretKeys(nested);
    }
  } else if (value is Iterable && value is! List<int>) {
    for (final item in value) {
      _expectNoSecretKeys(item);
    }
  }
}

void main() {
  group('nested chat-plaintext secrets', () {
    test('hostile sticker extra.fileKey is dropped; text + ACK still land',
        () async {
      final (persisted, acks) = await _dispatch(<String, Object?>{
        'type': 'msg',
        'id': 'm-sticker-secret',
        'text': 'hello sticker',
        'ts': 1,
        'sticker': <String, Object?>{
          'emoji': '👍',
          'extra': <String, Object?>{'fileKey': 'x'},
        },
      });

      expect(persisted, hasLength(1));
      expect(persisted.single['text'], 'hello sticker');
      expect(persisted.single['sticker'], isNull);
      _expectNoSecretKeys(persisted.single);
      expect(acks.where((a) => a['type'] == 'ack'), hasLength(1));
      expect(acks.single['id'], 'm-sticker-secret');
    });

    test('replyTo with kek is dropped', () async {
      final (persisted, acks) = await _dispatch(<String, Object?>{
        'type': 'msg',
        'id': 'm-reply-kek',
        'text': 'quoted',
        'ts': 2,
        'replyTo': <String, Object?>{'id': 'm1', 'kek': 'x'},
      });

      expect(persisted, hasLength(1));
      expect(persisted.single['text'], 'quoted');
      expect(persisted.single['replyTo'], isNull);
      _expectNoSecretKeys(persisted.single);
      expect(acks.where((a) => a['type'] == 'ack'), hasLength(1));
    });

    test('voice with nested rootKey is dropped', () async {
      final (persisted, acks) = await _dispatch(<String, Object?>{
        'type': 'msg',
        'id': 'm-voice-root',
        'text': 'voice note',
        'ts': 3,
        'voice': <String, Object?>{
          'duration': 1,
          'mime': 'audio/webm',
          'secret': <String, Object?>{'rootKey': 'x'},
        },
      });

      expect(persisted, hasLength(1));
      expect(persisted.single['text'], 'voice note');
      expect(persisted.single['voice'], isNull);
      _expectNoSecretKeys(persisted.single);
      expect(acks.where((a) => a['type'] == 'ack'), hasLength(1));
    });

    test('legit sticker still persists', () async {
      final (persisted, acks) = await _dispatch(<String, Object?>{
        'type': 'msg',
        'id': 'm-sticker-ok',
        'text': 'hi',
        'ts': 4,
        'sticker': <String, Object?>{'emoji': '👍'},
      });

      expect(persisted, hasLength(1));
      expect(persisted.single['text'], 'hi');
      expect(persisted.single['sticker'], isA<Map>());
      expect((persisted.single['sticker'] as Map)['emoji'], '👍');
      expect(acks.where((a) => a['type'] == 'ack'), hasLength(1));
    });

    test('legit voice metadata (incl. b64) is not treated as a secret',
        () async {
      expect(kForbiddenReplicationFields.contains('b64'), isFalse);
      expect(
        replicationValueIsSafe(<String, Object?>{
          'duration': 1,
          'mime': 'audio/webm',
          'b64': 'AAAA',
        }),
        isTrue,
      );

      // Metadata-only (no inline b64) so persist does not touch Drift blobs.
      final (persisted, acks) = await _dispatch(<String, Object?>{
        'type': 'msg',
        'id': 'm-voice-ok',
        'text': '',
        'ts': 5,
        'msgType': 'voice',
        'voice': <String, Object?>{
          'duration': 1,
          'mime': 'audio/webm',
        },
      });

      expect(persisted, hasLength(1));
      expect(persisted.single['voice'], isA<Map>());
      expect((persisted.single['voice'] as Map)['duration'], 1);
      expect((persisted.single['voice'] as Map)['mime'], 'audio/webm');
      _expectNoSecretKeys(persisted.single['voice']);
      expect(acks.where((a) => a['type'] == 'ack'), hasLength(1));
    });

    test('persisted attachment omits fileKey / fileKeyB64 (non-chunked)',
        () async {
      final (persisted, acks) = await _dispatch(<String, Object?>{
        'type': 'msg',
        'id': 'm-att-key',
        'text': 'file',
        'ts': 6,
        'msgType': 'file',
        'attachment': <String, Object?>{
          'name': 'notes.txt',
          'mime': 'text/plain',
          'size': 12,
          'fileKeyB64': 'c21lYWtlZA==',
          'fileKey': 'leak',
        },
      });

      expect(persisted, hasLength(1));
      final att = persisted.single['attachment'];
      expect(att, isA<Map>());
      final attMap = Map<String, Object?>.from(att as Map);
      expect(attMap.containsKey('fileKeyB64'), isFalse);
      expect(attMap.containsKey('fileKey'), isFalse);
      expect(attMap['name'], 'notes.txt');
      expect(attMap['mime'], 'text/plain');
      _expectNoSecretKeys(attMap);
      expect(acks.where((a) => a['type'] == 'ack'), hasLength(1));
    });

    test('chunked fileKeyB64 is assembly-only; metaOut has no file keys',
        () async {
      final (persisted, acks) = await _dispatch(<String, Object?>{
        'type': 'msg',
        'id': 'm-att-chunk',
        'text': '',
        'ts': 7,
        'msgType': 'file',
        'attachment': <String, Object?>{
          'name': 'a.bin',
          'mime': 'application/octet-stream',
          'size': 4,
          'chunked': true,
          'fileId': 'fid-1',
          'fileKeyB64': 'AAAAAAAAAAA=',
        },
      });

      expect(persisted, hasLength(1));
      final att = persisted.single['attachment'];
      expect(att, isA<Map>());
      final attMap = Map<String, Object?>.from(att as Map);
      expect(attMap.containsKey('fileKeyB64'), isFalse);
      expect(attMap.containsKey('fileKey'), isFalse);
      expect(attMap['name'], 'a.bin');
      _expectNoSecretKeys(attMap);
      expect(acks.where((a) => a['type'] == 'ack'), hasLength(1));
    });

    test('metaOut literal omits fileKey and fileKeyB64', () {
      final src = File('lib/messaging/message_protocol.dart').readAsStringSync();
      final match = RegExp(
        r'final metaOut = <String, Object\?>\{([\s\S]*?)\};',
      ).firstMatch(src);
      expect(match, isNotNull, reason: 'metaOut map must exist');
      final body = match!.group(1)!;
      expect(body.contains('fileKey'), isFalse);
      expect(body.contains('fileKeyB64'), isFalse);
    });
  });

  group('profile_res nested secrets', () {
    test(
        'profile_res with nested fileKey is consumed without upsert, profiles, or avatar persist',
        () async {
      final seed = <String, Object?>{
        'ORBIT-OTHER': <String, Object?>{'displayName': 'keep'},
      };
      final (upserts, profiles, sent, consumed) = await _dispatchProfile(
        <String, Object?>{
          'type': 'profile_res',
          'profile': <String, Object?>{
            'displayName': 'A',
            'extra': <String, Object?>{'fileKey': 'x'},
          },
        },
        initialProfiles: Map<String, Object?>.from(seed),
      );

      expect(consumed, isTrue);
      expect(upserts, isEmpty);
      expect(profiles, seed);
      expect(profiles.containsKey('ORBIT-PEER'), isFalse);
      expect(sent, isEmpty);
      _expectNoSecretKeys(profiles);
    });

    test('legit profile_res upserts displayName and setProfilesByPeer',
        () async {
      final (upserts, profiles, _, consumed) = await _dispatchProfile(
        <String, Object?>{
          'type': 'profile_res',
          'profile': <String, Object?>{
            'peerId': 'ORBIT-PEER',
            'displayName': 'A',
            'bio': 'hi',
            // Non-data URL: not persisted, and not treated as an explicit
            // clear (which would unawait db.deleteAvatar and trip Drift).
            'avatarDataUrl': 'https://example.invalid/avatar.png',
          },
        },
      );

      expect(consumed, isTrue);
      expect(upserts, hasLength(1));
      expect(upserts.single.$1, 'ORBIT-PEER');
      expect(upserts.single.$2['displayName'], 'A');
      expect(profiles['ORBIT-PEER'], isA<Map>());
      final stored = Map<String, Object?>.from(profiles['ORBIT-PEER']! as Map);
      expect(stored['displayName'], 'A');
      expect(stored['bio'], 'hi');
      expect(stored['peerId'], 'ORBIT-PEER');
      _expectNoSecretKeys(stored);
    });

    test('profile_req skips reply when localProfile nests a secret', () async {
      final (_, _, sent, consumed) = await _dispatchProfile(
        <String, Object?>{'type': 'profile_req', 'nonce': 1},
        localProfile: () => <String, Object?>{
          'peerId': 'ORBIT-SELF',
          'displayName': 'Me',
          'extra': <String, Object?>{'fileKey': 'x'},
        },
      );

      expect(consumed, isTrue);
      expect(sent, isEmpty);
    });
  });
}

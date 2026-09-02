// Defense-in-depth: [clampChatMessageMaps] nulls nested UI maps that
// nest [kForbiddenReplicationFields] before persist. Safe maps stay.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/state/messaging_notifier.dart';

void main() {
  group('clampChatMessageMaps', () {
    test('drops sticker with nested fileKey and keeps text', () {
      final out = clampChatMessageMaps(<String, Object?>{
        'text': 'hi',
        'sticker': <String, Object?>{
          'emoji': '👍',
          'extra': <String, Object?>{'fileKey': 'x'},
        },
      });
      expect(out['text'], 'hi');
      expect(out['sticker'], isNull);
    });

    test('drops replyTo that carries kek', () {
      final out = clampChatMessageMaps(<String, Object?>{
        'text': 'hi',
        'replyTo': <String, Object?>{'id': 'm1', 'kek': 'x'},
      });
      expect(out['text'], 'hi');
      expect(out['replyTo'], isNull);
    });

    test('drops voice with nested rootKey', () {
      final out = clampChatMessageMaps(<String, Object?>{
        'text': 'hi',
        'voice': <String, Object?>{
          'duration': 1,
          'secret': <String, Object?>{'rootKey': 'x'},
        },
      });
      expect(out['text'], 'hi');
      expect(out['voice'], isNull);
    });

    test('drops attachment that carries fileKeyB64', () {
      final out = clampChatMessageMaps(<String, Object?>{
        'text': 'hi',
        'attachment': <String, Object?>{
          'name': 'a',
          'fileKeyB64': 'xx',
        },
      });
      expect(out['text'], 'hi');
      expect(out['attachment'], isNull);
    });

    test('keeps a safe sticker map', () {
      final sticker = <String, Object?>{'emoji': '👍'};
      final out = clampChatMessageMaps(<String, Object?>{
        'text': 'hi',
        'sticker': sticker,
      });
      expect(out['text'], 'hi');
      expect(out['sticker'], same(sticker));
    });
  });
}

// Chat preferences: fontScale mapping + persisted load/save. Deterministic.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:orbits_flutter/state/chat_prefs_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatPrefs.fontScale', () {
    test('maps size buckets to multipliers', () {
      expect(const ChatPrefs(fontSize: 'XS').fontScale, 0.85);
      expect(const ChatPrefs(fontSize: 'S').fontScale, 0.92);
      expect(const ChatPrefs(fontSize: 'M').fontScale, 1.0);
      expect(const ChatPrefs(fontSize: 'L').fontScale, 1.12);
      expect(const ChatPrefs(fontSize: 'XL').fontScale, 1.25);
      expect(const ChatPrefs(fontSize: 'bogus').fontScale, 1.0); // safe default
    });
  });

  group('ChatPrefsNotifier', () {
    test('update persists and reflects in state', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final c = ProviderContainer();
      addTearDown(c.dispose);

      await c.read(chatPrefsProvider.notifier).update(
            const ChatPrefs(showSeconds: true, fontSize: 'L', bubbleStyle: 'square'),
          );

      final s = c.read(chatPrefsProvider);
      expect(s.showSeconds, isTrue);
      expect(s.fontSize, 'L');
      expect(s.bubbleStyle, 'square');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('orbits_chat_prefs_v1'), isNotNull);
    });

    test('loads persisted prefs on construction (survives restart)', () async {
      SharedPreferences.setMockInitialValues({
        'orbits_chat_prefs_v1':
            '{"showSeconds":true,"fontSize":"XL","bubbleStyle":"bubble"}',
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);

      c.read(chatPrefsProvider); // construct → async _load()
      for (var i = 0;
          i < 100 && c.read(chatPrefsProvider).showSeconds == false;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final s = c.read(chatPrefsProvider);
      expect(s.showSeconds, isTrue);
      expect(s.fontSize, 'XL');
      expect(s.bubbleStyle, 'bubble');
    });
  });
}

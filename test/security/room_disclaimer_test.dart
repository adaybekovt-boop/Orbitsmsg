// Phase 2.2: honest room-crypto disclaimer (no fake group protocol).
//
// These fail on origin/main: README / terms / security settings claimed
// universal E2E; room chat had no host-can-read notice; rooms still
// bypass the ratchet as plaintext maps.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final repoRoot = Directory.current;

  String read(String rel) {
    final f = File(
      '${repoRoot.path}${Platform.pathSeparator}'
      '${rel.replaceAll('/', Platform.pathSeparator)}',
    );
    expect(f.existsSync(), isTrue, reason: '$rel is missing');
    return f.readAsStringSync();
  }

  test('rooms are documented as not E2E (no room_crypto.dart)', () {
    expect(File('lib/peer/room_crypto.dart').existsSync(), isFalse);
    final rooms = read('docs/rooms.md');
    expect(rooms.toLowerCase(), contains('not end-to-end'));
    expect(rooms, contains('plaintext'));
    expect(rooms.toLowerCase(), contains('rekey'));

    final readme = read('README.md');
    expect(readme, contains('Rooms are not end-to-end encrypted'));
    expect(
      readme,
      isNot(
        contains(
          'A private, peer-to-peer messenger with end-to-end encryption.',
        ),
      ),
    );

    final security = read('SECURITY.md');
    expect(security, contains('docs/rooms.md'));
  });

  test('user-facing copy no longer claims every message is E2E', () {
    final terms = read('lib/ui/auth/terms_text.dart');
    expect(terms, contains('личные чаты'));
    expect(terms, contains('организатор в открытом виде'));

    final settings = read('lib/pages/settings/security_page.dart');
    expect(settings, isNot(contains('Все сообщения зашифрованы')));
    expect(settings, contains('Без сквозного шифрования'));

    final onboarding = read('lib/ui/auth/onboarding_page.dart');
    expect(onboarding, contains('организатор'));
    expect(onboarding, contains('сквозное шифрование'));
    expect(onboarding, isNot(contains('переписка надёжно защищена')));

    final disclaimer = read('lib/peer/room_disclaimer.dart');
    expect(disclaimer, contains('kRoomNotE2eBannerRu'));
    expect(disclaimer, contains('без сквозного'));
    expect(disclaimer, contains('шифрования'));

    final chat = read('lib/pages/room_chat_page.dart');
    expect(chat, contains('RoomNotE2eBanner'));
  });

  test('room packets still bypass the ratchet (plaintext maps)', () {
    final mgr = read('lib/peer/room_manager.dart');
    expect(mgr, contains('PLAINTEXT'));
    expect(mgr, contains('bypass the per-message ratchet'));

    final conns = read('lib/state/connections_notifier.dart');
    expect(conns, contains('plaintext room-protocol'));
    expect(conns, contains('bypasses the per-message ratchet'));
  });
}

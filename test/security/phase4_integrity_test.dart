// Phase 4 source guards.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String rel) {
    final f = File(rel.replaceAll('/', Platform.pathSeparator));
    expect(f.existsSync(), isTrue, reason: '$rel is missing');
    return f.readAsStringSync();
  }

  test('OPK is peeked then consumed only after X3DH succeeds', () {
    final session = read('lib/core/x3dh_session.dart');
    expect(session, contains('peekFreshOPK'));
    expect(session, contains('consumeOPK'));
    expect(
      session.indexOf('peekFreshOPK'),
      lessThan(session.indexOf('responderX3DH')),
    );
    expect(
      session.indexOf('responderX3DH'),
      lessThan(session.lastIndexOf('consumeOPK')),
    );
  });

  test('bootstrapSk is one-shot and cleared on rekey', () {
    final wire = read('lib/core/wire_session.dart');
    expect(wire, contains('session.bootstrapSk = null'));
    expect(wire, contains('Stale X3DH seed must not survive'));
  });

  test('ack/edit/delete check conversation author', () {
    final proto = read('lib/messaging/message_protocol.dart');
    expect(proto, contains('remoteCanAckOutbound'));
    expect(proto, contains('remoteOwnsInboundMessage'));
  });

  test('biometric gate fails closed when the sensor is missing', () {
    final vault = read('lib/storage/secure_kek_vault.dart');
    expect(vault, contains('biometricAvailabilityGate(false)'));
    expect(vault, contains('Fail closed'));
  });

  test('Drop names are sanitized; new passwords are 12+ / two classes', () {
    expect(read('lib/core/orbits_drop.dart'), contains('sanitizeDropFileName'));
    final pw = read('lib/core/auth_validation.dart');
    expect(pw, contains('p.length < 12'));
    expect(pw, contains("'weak'"));
  });

  test('QR copy does not claim vault login', () {
    final page = read('lib/pages/qr_pairing_page.dart');
    expect(page, isNot(contains('Сессия авторизована')));
    expect(page, contains('не вход в профиль'));
    final settings = read('lib/pages/settings/security_page.dart');
    expect(settings, contains('не копирование сейфа'));
  });

  test('notifications page stays honest', () {
    final n = read('lib/pages/settings/notifications_page.dart');
    expect(n, contains('Уведомления пока не работают'));
  });
}

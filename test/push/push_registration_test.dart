import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/push/push_gateway.dart';
import 'package:orbits_flutter/push/push_registration.dart';

void main() {
  test('honest apns and fcm tokens are stored', () {
    final reg = PushRegistration();
    reg.acceptToken({'apns': 'aa', 'fcm': 'bb'});
    expect(reg.tokens.apnsToken, 'aa');
    expect(reg.tokens.fcmToken, 'bb');
  });

  test('URL apns token is not stored', () {
    final reg = PushRegistration();
    reg.acceptToken({'apns': 'https://evil.example/t'});
    expect(reg.tokens.apnsToken, isNull);
    expect(reg.tokens.fcmToken, isNull);
  });

  test('fcm token with fileKey fragment is not stored', () {
    final reg = PushRegistration();
    reg.acceptToken({'fcm': 'has-fileKey'});
    expect(reg.tokens.fcmToken, isNull);
    expect(reg.tokens.apnsToken, isNull);
  });

  test('apns tokens with secret fragments are refused', () {
    for (final bad in ['peerId-fragment', 'rootKey', 'discoverySecret-1']) {
      final reg = PushRegistration();
      reg.acceptToken({'apns': bad});
      expect(reg.tokens.apnsToken, isNull, reason: bad);
      expect(reg.tokens.fcmToken, isNull, reason: bad);
    }
  });

  test('nested forbidden key drops the whole payload', () {
    final reg = PushRegistration();
    reg.acceptToken({
      'apns': 'tok',
      'extra': {'fileKey': 'x'},
    });
    expect(reg.tokens.apnsToken, isNull);
    expect(reg.tokens.fcmToken, isNull);
  });

  test('shouldRegisterNative is false', () {
    expect(PushRegistration().shouldRegisterNative, isFalse);
  });

  test('kLiveApnsGateway and kLiveFcmGateway stay false', () {
    expect(kLiveApnsGateway, isFalse);
    expect(kLiveFcmGateway, isFalse);
  });
}

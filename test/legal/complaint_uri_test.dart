import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/pages/settings/complaint_page.dart';

void main() {
  test('abuse report URL contains peer context and user note', () {
    final uri = buildComplaintUri(
      peerId: 'ORBIT-TEST',
      messageId: 'msg-42',
      note: 'Угрозы в чате',
    );

    expect(uri.scheme, 'https');
    expect(uri.host, 'github.com');
    expect(uri.queryParameters['title'], contains('Abuse report'));
    expect(uri.queryParameters['body'], contains('ORBIT-TEST'));
    expect(uri.queryParameters['body'], contains('msg-42'));
    expect(uri.queryParameters['body'], contains('Угрозы в чате'));
  });
}

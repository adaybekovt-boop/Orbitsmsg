import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/safety/content_safety_filter.dart';

void main() {
  test('blocks explicit threats in Russian and English', () {
    expect(ContentSafetyFilter.blockedReason('I will kill you'), isNotNull);
    expect(ContentSafetyFilter.blockedReason('Я убью тебя'), isNotNull);
  });

  test('blocks explicit child sexual abuse material references', () {
    expect(ContentSafetyFilter.blockedReason('share CSAM'), isNotNull);
    expect(ContentSafetyFilter.blockedReason('детская порнография'), isNotNull);
  });

  test('does not block ordinary conversation or substrings', () {
    expect(ContentSafetyFilter.blockedReason('Привет, как дела?'), isNull);
    expect(
      ContentSafetyFilter.blockedReason('This is a killer feature'),
      isNull,
    );
  });
}

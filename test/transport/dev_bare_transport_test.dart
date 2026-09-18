import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/transport/dev_bare_transport.dart';

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('dev Bare path is off in release even with dart-define', () {
    expect(
      isDevBareTransportRequested(dartDefine: true, releaseMode: true),
      isFalse,
    );
    expect(isHyperswarmTransportEnabled(), isFalse);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
  });

  test('debug dart-define or pref enables the test path without flipping rollout', () {
    expect(
      isDevBareTransportRequested(dartDefine: true, releaseMode: false),
      isTrue,
    );
    hydrateDevBareTransportPref(true);
    expect(isDevBareTransportRequested(releaseMode: false), isTrue);
    expect(isHyperswarmTransportEnabled(), isTrue);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
  });

  test('Android and iOS are mobile Bare hosts; desktop is not', () {
    expect(
      isMobileBareHost(platform: TargetPlatform.android, isWeb: false),
      isTrue,
    );
    expect(isMobileBareHost(platform: TargetPlatform.iOS, isWeb: false), isTrue);
    expect(
      isMobileBareHost(platform: TargetPlatform.linux, isWeb: false),
      isFalse,
    );
    expect(
      isMobileBareHost(platform: TargetPlatform.android, isWeb: true),
      isFalse,
    );
  });
}

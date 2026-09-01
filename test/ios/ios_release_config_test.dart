import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '$path is missing');
    return file.readAsStringSync();
  }

  group('iOS release configuration', () {
    test('minimum iOS version matches camera and WebRTC plugins', () {
      expect(read('ios/Podfile'), contains("platform :ios, '15.5'"));
      expect(
        read('ios/Runner.xcodeproj/project.pbxproj'),
        isNot(contains('IPHONEOS_DEPLOYMENT_TARGET = 12.0')),
      );
      expect(
        read('ios/Runner.xcodeproj/project.pbxproj'),
        contains('IPHONEOS_DEPLOYMENT_TARGET = 15.5'),
      );
      expect(
        read('ios/Flutter/AppFrameworkInfo.plist'),
        contains('<string>15.5</string>'),
      );
    });

    test('purpose strings cover every protected iOS capability', () {
      final plist = read('ios/Runner/Info.plist');
      for (final key in <String>[
        'NSCameraUsageDescription',
        'NSMicrophoneUsageDescription',
        'NSPhotoLibraryUsageDescription',
        'NSFaceIDUsageDescription',
        'NSLocalNetworkUsageDescription',
      ]) {
        expect(plist, contains(key), reason: '$key must be declared');
      }
      expect(plist, contains('<key>NSAllowsArbitraryLoads</key>'));
      expect(plist, contains('<false/>'));
    });

    test('privacy manifest is bundled and declares no tracking', () {
      final manifest = read('ios/Runner/PrivacyInfo.xcprivacy');
      expect(manifest, contains('<key>NSPrivacyTracking</key>'));
      expect(manifest, contains('<false/>'));
      expect(manifest, contains('NSPrivacyCollectedDataTypeUserID'));
      expect(manifest, contains('NSPrivacyCollectedDataTypeOtherDataTypes'));

      final project = read('ios/Runner.xcodeproj/project.pbxproj');
      expect(project, contains('PrivacyInfo.xcprivacy in Resources'));
    });

    test('release entitlements are signing-safe and bundle-id independent', () {
      final release = read('ios/Runner/Release.entitlements');
      expect(release, isNot(contains('get-task-allow')));
      expect(
        release,
        contains(r'$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)'),
      );
      expect(release, isNot(contains('com.orbits.orbitsFlutter')));

      final debug = read('ios/Runner/DebugProfile.entitlements');
      expect(debug, contains('<key>get-task-allow</key>'));
      expect(debug, contains('<true/>'));
    });

    test('iOS CI uses Xcode 26 and builds device plus simulator targets', () {
      final workflow = read('.github/workflows/build.yml');
      expect(workflow, contains('runs-on: macos-26'));
      expect(workflow, contains('/Applications/Xcode_26.5.app'));
      expect(workflow, contains('flutter build ios --release --no-codesign'));
      expect(workflow, contains('flutter build ios --simulator --debug'));
      expect(workflow, contains('flutter build macos --release'));
      expect(workflow, contains('kBareBinaryShipped stays false'));
    });
  });
}

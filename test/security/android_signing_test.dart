// Phase 1.1 Android release signing guards (GH-C01 / U-5).
//
// These fail on the Phase 0 tree: release still assigned the Android debug
// keystore, CI cached ~/.android/debug.keystore, and there was no upload-key
// path, apksigner check, or signing doc.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final repoRoot = Directory.current;

  File file(String rel) => File('${repoRoot.path}${Platform.pathSeparator}'
      '${rel.replaceAll('/', Platform.pathSeparator)}');

  String read(String rel) {
    final f = file(rel);
    expect(f.existsSync(), isTrue, reason: '$rel is missing');
    return f.readAsStringSync();
  }

  Map<String, String> childEnv(Map<String, String> extra) {
    final env = Map<String, String>.from(Platform.environment);
    for (final key in [
      'ANDROID_UPLOAD_KEYSTORE_BASE64',
      'ANDROID_UPLOAD_STORE_PASSWORD',
      'ANDROID_UPLOAD_KEY_ALIAS',
      'ANDROID_UPLOAD_KEY_PASSWORD',
      'GITHUB_ACTIONS',
      'GITHUB_REF',
      'GITHUB_ENV',
      'ORBITS_KEYSTORE_DIR',
    ]) {
      env.remove(key);
    }
    extra.forEach((key, value) {
      if (value.isEmpty) {
        env.remove(key);
      } else {
        env[key] = value;
      }
    });
    return env;
  }

  group('committed gradle never debug-signs release (GH-C01 / U-5)', () {
    test('release uses the upload config and names the env vars', () {
      final gradle = read('android/app/build.gradle.kts');
      expect(gradle, contains('ORBITS_RELEASE_SIGNING'));
      expect(gradle, contains('ORBITS_UPLOAD_STORE_FILE'));
      expect(gradle, contains('ORBITS_UPLOAD_STORE_PASSWORD'));
      expect(gradle, contains('ORBITS_UPLOAD_KEY_ALIAS'));
      expect(gradle, contains('ORBITS_UPLOAD_KEY_PASSWORD'));
      expect(gradle, contains('signingConfigs.getByName("release")'));
      expect(gradle, contains('no debug-keystore fallback'));
      expect(gradle, isNot(contains('signingConfigs.getByName("debug")')));
      expect(gradle, isNot(contains('androiddebugkey')));
    });

    test('assembleRelease fails closed when the upload keystore is missing', () {
      final gradle = read('android/app/build.gradle.kts');
      expect(gradle, contains('taskGraph.whenReady'));
      expect(gradle, contains('releaseSigningConfigured'));
      expect(gradle, contains('GradleException'));
    });
  });

  group('CI wiring (GH-C01 / U-5)', () {
    test('workflow prepares an upload keystore and verifies APK certs', () {
      final build = read('.github/workflows/build.yml');
      expect(build, contains('tool/ci/prepare_upload_keystore.sh'));
      expect(build, contains('tool/ci/verify_apk_not_debug_signed.sh'));
      expect(build, contains('ANDROID_UPLOAD_KEYSTORE_BASE64'));
      expect(build, contains('android-upload-keystore-ci-v1'));
      expect(read('tool/ci/verify_apk_not_debug_signed.sh'), contains('apksigner'));
      expect(read('tool/ci/verify_apk_not_debug_signed.sh'), contains('CN=Android Debug'));
      expect(build, isNot(contains('android-debug-keystore-v1')));
      expect(build, isNot(contains('debug.keystore')));
      expect(build, isNot(contains('androiddebugkey')));
      expect(build, isNot(contains('storepass android')));
    });

    test('docs describe secrets, rotation, and compromise', () {
      final docs = read('docs/android-signing.md');
      expect(docs, contains('GH-C01'));
      expect(docs, contains('U-5'));
      expect(docs, contains('ANDROID_UPLOAD_KEYSTORE_BASE64'));
      expect(docs, contains('ORBITS_UPLOAD_STORE_FILE'));
      expect(docs.toLowerCase(), contains('rotation'));
      expect(docs.toLowerCase(), contains('compromise'));
      expect(docs, contains('androiddebugkey'));
      expect(read('SECURITY.md'), contains('docs/android-signing.md'));
    });

    test('keystores and password files stay gitignored', () {
      final gi = read('.gitignore');
      expect(gi, contains('*.keystore'));
      expect(gi, contains('*.keystore.pass'));
      expect(gi, contains('*.jks'));
      expect(gi, contains('key.properties'));
    });
  });

  group('prepare_upload_keystore.sh', () {
    late Directory tmp;
    late String script;
    late String githubEnv;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('orbits-upload-ks-');
      script = file('tool/ci/prepare_upload_keystore.sh').path;
      githubEnv = '${tmp.path}/github.env';
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    ProcessResult runPrepare(Map<String, String> extra) {
      return Process.runSync(
        'bash',
        [script],
        environment: childEnv({
          'ORBITS_KEYSTORE_DIR': tmp.path,
          'GITHUB_ENV': githubEnv,
          ...extra,
        }),
      );
    }

    String listing(String store, String password) {
      final result = Process.runSync('keytool', [
        '-list',
        '-v',
        '-keystore',
        store,
        '-storepass',
        password,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}\n${result.stdout}');
      return '${result.stdout}\n${result.stderr}';
    }

    test('PR without a production secret gets CN=Orbits OU=CI, not Android Debug',
        () {
      final result = runPrepare({'GITHUB_REF': 'refs/pull/12/merge'});
      expect(result.exitCode, 0,
          reason: '${result.stderr}\n${result.stdout}');
      final envFile = File(githubEnv).readAsStringSync();
      expect(envFile, contains('ORBITS_UPLOAD_KEY_ALIAS=orbits-upload'));
      expect(envFile, isNot(contains('androiddebugkey')));
      final store = File('${tmp.path}/orbits-ci-upload.keystore');
      expect(store.existsSync(), isTrue);
      final pass = File('${tmp.path}/orbits-ci-upload.keystore.pass')
          .readAsStringSync();
      final text = listing(store.path, pass);
      expect(text, contains('CN=Orbits'));
      expect(text, contains('OU=CI'));
      expect(text, isNot(contains('CN=Android Debug')));
      expect(text, contains('Alias name: orbits-upload'));
    });

    test('tagged release without the production secret fails closed', () {
      final result = runPrepare({'GITHUB_REF': 'refs/tags/v9.0.0'});
      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('ANDROID_UPLOAD_KEYSTORE_BASE64'));
      expect(File('${tmp.path}/orbits-ci-upload.keystore').existsSync(), isFalse);
    });

    test('production secret on a tag is decoded; the same secret on a PR is not',
        () {
      final prodPath = '${tmp.path}/prod.keystore';
      const prodPass = 'prod-pass-not-android';
      const prodAlias = 'orbits-upload';
      final gen = Process.runSync('keytool', [
        '-genkeypair',
        '-keystore',
        prodPath,
        '-storetype',
        'PKCS12',
        '-storepass',
        prodPass,
        '-keypass',
        prodPass,
        '-alias',
        prodAlias,
        '-keyalg',
        'RSA',
        '-keysize',
        '2048',
        '-validity',
        '365',
        '-dname',
        'CN=Orbits,OU=Release,O=Orbits,C=US',
      ]);
      expect(gen.exitCode, 0, reason: '${gen.stderr}\n${gen.stdout}');
      final b64 = base64Encode(File(prodPath).readAsBytesSync());

      final tag = runPrepare({
        'GITHUB_REF': 'refs/tags/v9.1.0',
        'ANDROID_UPLOAD_KEYSTORE_BASE64': b64,
        'ANDROID_UPLOAD_STORE_PASSWORD': prodPass,
        'ANDROID_UPLOAD_KEY_ALIAS': prodAlias,
        'ANDROID_UPLOAD_KEY_PASSWORD': prodPass,
      });
      expect(tag.exitCode, 0, reason: '${tag.stderr}\n${tag.stdout}');
      final tagEnv = File(githubEnv).readAsStringSync();
      expect(tagEnv, contains('orbits-release-upload.keystore'));
      final tagStore = File('${tmp.path}/orbits-release-upload.keystore');
      expect(listing(tagStore.path, prodPass), contains('OU=Release'));

      File(githubEnv).writeAsStringSync('');
      final pr = runPrepare({
        'GITHUB_REF': 'refs/pull/3/merge',
        'ANDROID_UPLOAD_KEYSTORE_BASE64': b64,
        'ANDROID_UPLOAD_STORE_PASSWORD': prodPass,
        'ANDROID_UPLOAD_KEY_ALIAS': prodAlias,
        'ANDROID_UPLOAD_KEY_PASSWORD': prodPass,
      });
      expect(pr.exitCode, 0, reason: '${pr.stderr}\n${pr.stdout}');
      final prEnv = File(githubEnv).readAsStringSync();
      expect(prEnv, contains('orbits-ci-upload.keystore'));
      expect(prEnv, isNot(contains('orbits-release-upload.keystore')));
      final ciPass = File('${tmp.path}/orbits-ci-upload.keystore.pass')
          .readAsStringSync();
      expect(
        listing('${tmp.path}/orbits-ci-upload.keystore', ciPass),
        contains('OU=CI'),
      );
    });

    test('rejects a production secret that is the Android debug keystore', () {
      final debugPath = '${tmp.path}/fake-debug.keystore';
      final gen = Process.runSync('keytool', [
        '-genkeypair',
        '-keystore',
        debugPath,
        '-storetype',
        'PKCS12',
        '-storepass',
        'android',
        '-keypass',
        'android',
        '-alias',
        'orbits-upload',
        '-keyalg',
        'RSA',
        '-keysize',
        '2048',
        '-validity',
        '365',
        '-dname',
        'CN=Android Debug,O=Android,C=US',
      ]);
      expect(gen.exitCode, 0, reason: '${gen.stderr}\n${gen.stdout}');
      final result = runPrepare({
        'GITHUB_REF': 'refs/tags/v9.2.0',
        'ANDROID_UPLOAD_KEYSTORE_BASE64':
            base64Encode(File(debugPath).readAsBytesSync()),
        'ANDROID_UPLOAD_STORE_PASSWORD': 'android',
        'ANDROID_UPLOAD_KEY_ALIAS': 'orbits-upload',
        'ANDROID_UPLOAD_KEY_PASSWORD': 'android',
      });
      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('Android debug'));
    });
  }, skip: (!Platform.isLinux && !Platform.isMacOS)
      ? 'prepare_upload_keystore.sh is a bash/keytool helper'
      : false);

  group('patch_android.sh does not reintroduce debug release signing', () {
    test('Flutter template debug assignment is rewritten to upload signing', () {
      final tmp = Directory.systemTemp.createTempSync('orbits-android-patch-');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      final android = Directory('${tmp.path}/android/app/src/main')
        ..createSync(recursive: true);
      File('${android.path}/AndroidManifest.xml').writeAsStringSync('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="orbits">
    </application>
</manifest>
''');
      final gradlePath = '${tmp.path}/android/app/build.gradle.kts';
      File(gradlePath).writeAsStringSync(r'''
plugins {
    id("com.android.application")
}
android {
    namespace = "com.example.app"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.example.app"
        minSdk = 21
        targetSdk = 34
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}
flutter {
    source = "../.."
}
''');

      final result = Process.runSync(
        'bash',
        [file('tool/ci/patch_android.sh').path],
        workingDirectory: tmp.path,
        environment: childEnv({}),
      );
      expect(result.exitCode, 0, reason: '${result.stderr}\n${result.stdout}');

      final patched = File(gradlePath).readAsStringSync();
      expect(patched, contains('ORBITS_RELEASE_SIGNING'));
      expect(patched, contains('ORBITS_UPLOAD_STORE_FILE'));
      expect(patched, contains('signingConfigs.getByName("release")'));
      expect(patched, contains('no debug-keystore fallback'));
      expect(patched, isNot(contains('signingConfigs.getByName("debug")')));
    });
  }, skip: (!Platform.isLinux && !Platform.isMacOS)
      ? 'patch_android.sh is a bash helper'
      : false);
}

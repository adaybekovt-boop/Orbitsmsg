#!/usr/bin/env bash
# Patch the freshly-generated `android/` folder so it matches what this
# project actually needs:
#
#   1. AndroidManifest.xml — add INTERNET, CAMERA, RECORD_AUDIO, plus the
#      `<queries>` blocks for `share_plus` / file picker intents and the
#      `usesCleartextTraffic` flag we toggle for local PeerJS dev signaling.
#
#   2. build.gradle(.kts) — release currently signs with the debug keystore
#      (ORBITS_RELEASE_SIGNING). That is a known Critical defect (GH-C01 / U-5)
#      and is replaced in Phase 1. This script only ensures the marker is
#      present so a regenerated template still produces a sideloadable APK
#      until that PR lands. Do not treat the debug key as a Play upload key.
#
#   3. gradle.properties — bump the JVM heap so the d8/r8 step doesn't
#      OOM on the GitHub-hosted runner with the larger transitive
#      dependency graph (cryptography + drift + flutter_webrtc).
#
#   4. minSdk bump to 23 — flutter_webrtc / mobile_scanner / record floors.
#
#   5. settings.gradle — defensive Kotlin/AGP bump. On Flutter 3.32+ the
#      template already ships Kotlin 2.x and AGP 8.7+, so this is usually
#      a no-op. Kept around for older Flutter SDKs where the template
#      still pins Kotlin to 1.8.22.
#
# Run this AFTER `flutter create --platforms=android …`. Idempotent.

set -euo pipefail

ANDROID_DIR="android"
MANIFEST="$ANDROID_DIR/app/src/main/AndroidManifest.xml"

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: $MANIFEST not found. Did you run 'flutter create' first?" >&2
  exit 1
fi

# ─── 1. AndroidManifest permissions ──────────────────────────────────────────

# Insert the permissions just before the `<application` opening tag, which
# is where Flutter places its own internet permission in the default
# template. Use a marker so re-running this script doesn't duplicate.
if ! grep -q "ORBITS_PERMS_INJECTED" "$MANIFEST"; then
  python3 - "$MANIFEST" <<'PY'
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
xml = path.read_text(encoding="utf-8")

block = """\
    <!-- ORBITS_PERMS_INJECTED -->
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
    <uses-permission android:name="android.permission.CAMERA"/>
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
    <uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>
    <uses-permission android:name="android.permission.READ_MEDIA_AUDIO"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>

    <uses-feature android:name="android.hardware.camera" android:required="false"/>
    <uses-feature android:name="android.hardware.camera.autofocus" android:required="false"/>
    <uses-feature android:name="android.hardware.microphone" android:required="false"/>

"""

# Inject right before <application
new_xml, n = re.subn(r"(\s*<application\b)", "\n" + block + r"\1", xml, count=1)
if n == 0:
    print("ERROR: could not find <application tag", file=sys.stderr)
    sys.exit(1)

# Allow cleartext traffic ONLY via network_security_config.xml (localhost
# / 127.0.0.1 / 10.0.2.2). Never set usesCleartextTraffic=true on the
# application — that would permit plaintext HTTP/ws to the public internet.
if 'android:networkSecurityConfig=' not in new_xml:
    new_xml = re.sub(
        r'(<application\b)([^>]*?)(\s*>)',
        lambda m: m.group(1) + m.group(2)
            + ' android:networkSecurityConfig="@xml/network_security_config"'
            + ' android:usesCleartextTraffic="false"'
            + ' android:allowBackup="false"'
            + m.group(3),
        new_xml,
        count=1,
    )
else:
    # Belt-and-braces: a regenerated template must not re-enable global cleartext.
    new_xml = re.sub(
        r'android:usesCleartextTraffic="true"',
        'android:usesCleartextTraffic="false"',
        new_xml,
    )

path.write_text(new_xml, encoding="utf-8")
print(f"Patched permissions into {path}")
PY
else
  echo "Permissions already present, skipping manifest patch."
fi

# ─── 2. build.gradle — release signing = debug keystore ──────────────────────

# Newer Flutter (3.27+) emits Kotlin DSL by default. Older / migrated
# projects might still use Groovy. Handle both.

GRADLE_KTS="$ANDROID_DIR/app/build.gradle.kts"
GRADLE_GROOVY="$ANDROID_DIR/app/build.gradle"

if [ -f "$GRADLE_KTS" ]; then
  if ! grep -q "ORBITS_RELEASE_SIGNING" "$GRADLE_KTS"; then
    python3 - "$GRADLE_KTS" <<'PY'
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")

# The default template has:
#     buildTypes {
#         release {
#             signingConfig = signingConfigs.getByName("debug")
#         }
#     }
# i.e. it ALREADY uses debug for release. But the line is sometimes
# commented or absent depending on Flutter version. We force it.

new = re.sub(
    r'buildTypes\s*\{\s*release\s*\{[^}]*\}\s*\}',
    '''buildTypes {
        release {
            // ORBITS_RELEASE_SIGNING — sideload-only build, no upload key.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }''',
    src,
    count=1,
    flags=re.DOTALL,
)

if new == src:
    # Couldn't find the buildTypes block — append one.
    new = re.sub(
        r'(android\s*\{)',
        r'''\1
    // ORBITS_RELEASE_SIGNING
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
''',
        src,
        count=1,
    )

path.write_text(new, encoding="utf-8")
print(f"Patched {path}")
PY
  else
    echo "Release signing already patched in $GRADLE_KTS."
  fi
elif [ -f "$GRADLE_GROOVY" ]; then
  if ! grep -q "ORBITS_RELEASE_SIGNING" "$GRADLE_GROOVY"; then
    python3 - "$GRADLE_GROOVY" <<'PY'
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")

new = re.sub(
    r'buildTypes\s*\{\s*release\s*\{[^}]*\}\s*\}',
    '''buildTypes {
        release {
            // ORBITS_RELEASE_SIGNING — sideload-only build, no upload key.
            signingConfig signingConfigs.debug
            minifyEnabled false
            shrinkResources false
        }
    }''',
    src,
    count=1,
    flags=re.DOTALL,
)

path.write_text(new, encoding="utf-8")
print(f"Patched {path}")
PY
  else
    echo "Release signing already patched in $GRADLE_GROOVY."
  fi
else
  echo "ERROR: no build.gradle(.kts) found at $ANDROID_DIR/app/" >&2
  exit 1
fi

# ─── 3. gradle.properties — bigger heap, AndroidX ────────────────────────────

PROPS="$ANDROID_DIR/gradle.properties"
if [ -f "$PROPS" ]; then
  # Heap. Default is 1.5g — bump to 4g so r8/d8 doesn't OOM with our
  # cryptography + flutter_webrtc + drift dependency graph.
  if grep -q "org.gradle.jvmargs" "$PROPS"; then
    sed -i.bak -E 's|^org\.gradle\.jvmargs=.*|org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=2G -XX:+HeapDumpOnOutOfMemoryError -Dfile.encoding=UTF-8|' "$PROPS"
  else
    echo "org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=2G -XX:+HeapDumpOnOutOfMemoryError -Dfile.encoding=UTF-8" >> "$PROPS"
  fi
  rm -f "$PROPS.bak"

  grep -q "android.useAndroidX=true" "$PROPS" || echo "android.useAndroidX=true" >> "$PROPS"
  grep -q "android.enableJetifier=true" "$PROPS" || echo "android.enableJetifier=true" >> "$PROPS"
fi

# ─── 4. minSdk bump — flutter_webrtc + mobile_scanner need 21+, several
#       package transitive deps (just_audio, record) want 23+. Bumping to
#       23 keeps coverage at >99% of in-use Android devices and avoids the
#       desugaring grief that minSdk<21 causes.

APP_GRADLE="${GRADLE_KTS:-$GRADLE_GROOVY}"
if [ -f "$APP_GRADLE" ]; then
  python3 - "$APP_GRADLE" <<'PY'
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")

# Kotlin DSL: `minSdk = flutter.minSdkVersion` or `minSdk = 21`
# Groovy:     `minSdkVersion flutter.minSdkVersion`
new = re.sub(r'minSdk\s*=\s*[^\n]+',           'minSdk = 23',     src)
new = re.sub(r'minSdkVersion\s+[^\n]+',         'minSdkVersion 23', new)
path.write_text(new, encoding="utf-8")
PY
fi

# ─── 5. settings.gradle — defensive Kotlin/AGP version bumps ────────────────
#
# Flutter 3.32+ already ships Kotlin 2.x in templates, so this is
# typically a no-op. Kept for forward/backward compat: if a future
# Flutter ever regresses to <2.0, sed bumps to 2.0.21 and we still
# build. The assertion below accepts ANY Kotlin 2.x — we just need
# something modern enough for mobile_scanner ^6.

SETTINGS_KTS="$ANDROID_DIR/settings.gradle.kts"
SETTINGS_GROOVY="$ANDROID_DIR/settings.gradle"
SETTINGS=""
if [ -f "$SETTINGS_KTS" ]; then SETTINGS="$SETTINGS_KTS"; fi
if [ -z "$SETTINGS" ] && [ -f "$SETTINGS_GROOVY" ]; then SETTINGS="$SETTINGS_GROOVY"; fi

if [ -n "$SETTINGS" ]; then
  echo "── Before patching $SETTINGS ─────────────────────────────"
  cat "$SETTINGS"

  # Match Kotlin version on the kotlin.android plugin line in either
  # Groovy DSL (`id "..." version "X"`) or Kotlin DSL
  # (`id("...") version "X"`). If the template already has 2.x we
  # still rewrite to 2.0.21 — harmless, picks a known-good version.
  # But ONLY if the current pinned version is < 2.0. Use awk for the
  # conditional rewrite so a 2.1.x in the template stays untouched.
  python3 - "$SETTINGS" <<'PY'
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")

def bump_kotlin(match):
    prefix = match.group(1)
    ver = match.group(2)
    suffix = match.group(3)
    # Only rewrite if it's < 2.0.0. Anything >=2.0 we leave alone so
    # we don't downgrade a newer template's choice.
    parts = ver.split(".")
    try:
        major = int(parts[0])
    except (ValueError, IndexError):
        major = 0
    if major < 2:
        ver = "2.0.21"
    return prefix + ver + suffix

src = re.sub(
    r'(id[^"\']*["\']org\.jetbrains\.kotlin\.android["\'][^v]*version[^"\']*["\'])([^"\']+)(["\'])',
    bump_kotlin,
    src,
)
path.write_text(src, encoding="utf-8")
PY

  echo "── After patching $SETTINGS ──────────────────────────────"
  cat "$SETTINGS"

  # Belt-and-braces: assert ANY Kotlin 2.x ended up in the file. On
  # Flutter 3.32+ this is satisfied by the template directly; on older
  # SDKs it's satisfied by the bump above. If neither path produced a
  # 2.x line we fail loudly here, before Gradle has a chance to spend
  # 4 minutes confusing us.
  if ! grep -qE 'org\.jetbrains\.kotlin\.android.*version[[:space:]]+["'\''](2|[3-9])\.' "$SETTINGS"; then
    echo "ERROR: no Kotlin 2.x version found in $SETTINGS after patching." >&2
    echo "       Template format may have changed; update the regex above." >&2
    exit 1
  fi
fi

# Bump compileSdk / targetSdk to 36 and pin NDK 27 in app/build.gradle(.kts).
# Current flutter_secure_storage / mobile_scanner releases require API 36,
# and the native plugin graph requires NDK 27.0.12077973.

if [ -f "$APP_GRADLE" ]; then
  echo "── Before patching $APP_GRADLE ───────────────────────────"
  cat "$APP_GRADLE"
  python3 - "$APP_GRADLE" <<'PY'
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
src = re.sub(r'compileSdk\s*=\s*[^\n]+',     'compileSdk = 36',     src)
src = re.sub(r'compileSdkVersion\s+[^\n]+',   'compileSdkVersion 36', src)
src = re.sub(r'targetSdk\s*=\s*[^\n]+',      'targetSdk = 36',      src)
src = re.sub(r'targetSdkVersion\s+[^\n]+',    'targetSdkVersion 36',  src)
src = re.sub(r'ndkVersion\s*=\s*[^\n]+',      'ndkVersion = "27.0.12077973"', src)
path.write_text(src, encoding="utf-8")
print(f"Bumped compileSdk/targetSdk and NDK in {path}")
PY
  echo "── After patching $APP_GRADLE ────────────────────────────"
  cat "$APP_GRADLE"
fi

echo "── Android patches done."

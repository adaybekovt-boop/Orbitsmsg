# Android release signing

Audit: **GH-C01 / U-5**.

Orbits release APKs are signed with an upload keystore. They are **never**
signed with the well-known Android SDK debug keystore (`~/.android/debug.keystore`,
alias `androiddebugkey`, store password `android`, DN `CN=Android Debug`).
Every Android SDK ships that key, so a debug-signed release APK can be
silently updated by anyone who can run `flutter build apk --release`.

`flutter run` / debug builds still use the debug keystore. That is expected
and is not a distribution signature.

## Environment variables

`android/app/build.gradle.kts` reads:

| Variable | Purpose |
|----------|---------|
| `ORBITS_UPLOAD_STORE_FILE` | Absolute path to a PKCS12 / JKS keystore file |
| `ORBITS_UPLOAD_STORE_PASSWORD` | Keystore password |
| `ORBITS_UPLOAD_KEY_ALIAS` | Key alias (must not be `androiddebugkey`) |
| `ORBITS_UPLOAD_KEY_PASSWORD` | Key password |

If any of those are missing, empty, or the file does not exist,
`assembleRelease` / `bundleRelease` **fail**. There is no fallback to the
debug keystore. That is intentional: a local `flutter build apk --release`
without a keystore must not produce an installable, universally-forgeable APK.

## Local release build

```bash
export ORBITS_UPLOAD_STORE_FILE="$PWD/orbits-upload.keystore"
export ORBITS_UPLOAD_STORE_PASSWORD='…'
export ORBITS_UPLOAD_KEY_ALIAS=orbits-upload
export ORBITS_UPLOAD_KEY_PASSWORD='…'
flutter build apk --release
```

Do not commit the keystore, `key.properties`, or passwords. They are gitignored
(`*.keystore`, `*.jks`, `*.p12`, `*.keystore.pass`, `key.properties`).

## GitHub Actions

`tool/ci/prepare_upload_keystore.sh` chooses a keystore from the git ref:

| Ref | `ANDROID_UPLOAD_KEYSTORE_BASE64` set | Result |
|-----|--------------------------------------|--------|
| `refs/tags/v*` | yes | Decode the production upload key |
| `refs/tags/v*` | no | **Fail the job** — a GitHub Release must not use the CI sideload key |
| `refs/heads/main` or `master` | yes | Decode the production upload key |
| `refs/heads/main` or `master` | no | CI sideload key (`CN=Orbits,OU=CI,O=Orbits,C=US`, alias `orbits-upload`) |
| Pull requests and other branches | ignored even if present | CI sideload key (never the production key) |

PR artifacts therefore cannot update installs that were signed with the
production key, and a same-repo PR cannot mint a production-signed APK.

After the APK is built, `tool/ci/verify_apk_not_debug_signed.sh` runs
`apksigner verify --print-certs` and fails if any artifact's DN contains
`CN=Android Debug`.

The CI sideload key's password is random and stored next to the keystore in
the Actions cache (`android-upload-keystore-ci-v1`). It is **not** a trust
boundary: it only keeps PR APK signatures stable across runs. Do not
distribute those APKs as official releases.

### Secrets the maintainer must set

This automation cannot create repository secrets. A maintainer with admin
access adds these under **Settings → Secrets and variables → Actions**:

| Secret | Value |
|--------|-------|
| `ANDROID_UPLOAD_KEYSTORE_BASE64` | `base64 -w0 orbits-upload.keystore` (no wrapping newlines required) |
| `ANDROID_UPLOAD_STORE_PASSWORD` | Keystore password |
| `ANDROID_UPLOAD_KEY_ALIAS` | e.g. `orbits-upload` |
| `ANDROID_UPLOAD_KEY_PASSWORD` | Key password (often the same as the store password for PKCS12) |

Until those secrets exist, `main` and pull requests still produce sideload
APKs signed with the CI key. **Tags fail closed.**

### Generate an upload keystore

```bash
keytool -genkeypair -v \
  -keystore orbits-upload.keystore \
  -storetype PKCS12 \
  -alias orbits-upload \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Orbits,OU=Release,O=Orbits,C=US"
base64 -w0 orbits-upload.keystore
```

Store the `.keystore` file and passwords in a password manager, not in git.

## Rotation

1. Generate a new keystore (new DN optional, new key material required).
2. Update the four GitHub secrets.
3. Build a tagged release. Confirm `apksigner verify --print-certs` shows
   the new DN and not `CN=Android Debug`.
4. Sideload testers on the old signature must **uninstall** before they can
   install the new APK. Android will not update across signing certificates.
5. If the app is on Play, upload the new key only according to Play App
   Signing rules (the upload key can be reset; the app-signing key Google
   holds cannot be rotated by this repo).

## Compromise

Treat a leaked upload keystore or password as equivalent to a stolen
publisher identity for **sideloaded** installs:

1. Rotate immediately (above).
2. Stop distributing APKs signed with the old key. Delete or mark the
   affected GitHub Release as untrusted if one went out.
3. Tell users who sideloaded that build to uninstall and reinstall from a
   new tagged release (or Play, once the upload key is reset there).
4. If the leak was the Play **app-signing** key rather than the upload key,
   follow Google Play's compromised-key process. This repo cannot recover
   that key.

A leak of the CI sideload key (cache / `OU=CI`) does not affect tagged
releases or Play. Rotate it by changing the cache key
`android-upload-keystore-ci-v1` in `.github/workflows/build.yml` so the next
run generates a new keypair.

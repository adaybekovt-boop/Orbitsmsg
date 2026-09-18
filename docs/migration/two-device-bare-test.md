# Two-device Bare/Hyperswarm test

Development-only. Production rollout stays `HyperswarmRollout.off` and
PeerJS remains the default. This path is unavailable in release builds.

## What you need

- Two phones (Android+Android, iOS+iOS, or mixed).
- Debug builds from this branch. Release APKs ignore the test path.
- Two **disposable test identities**. Do not use real conversations,
  production accounts, or contacts that already have chat history. Create
  a fresh account on each device, then add each other as contacts via QR.

## Build

Android (installable debug APK, transport forced on):

```bash
flutter build apk --debug --split-per-abi \
  --dart-define=ORBITS_DEV_BARE_TRANSPORT=true
```

Install `build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk` (or the
ABI that matches the device). CI uploads the same files as artifact
`orbits-android-dev-bare`
(`orbits-android-arm64-dev-bare.apk` / `orbits-android-arm32-dev-bare.apk`).

iOS (no-sign validation on CI; on a Mac with a development team):

```bash
flutter build ios --debug --no-codesign \
  --dart-define=ORBITS_DEV_BARE_TRANSPORT=true
```

Then open `ios/Runner.xcworkspace` and run onto two devices from Xcode.

Without the dart-define, a debug build still exposes
**Settings → Соединение → Bare/Hyperswarm (dev)**. Turn it on on both
phones. Release builds hide the switch.

## Enable and confirm the transport

1. Open **Настройки → Дополнительно → Соединение**.
2. The row **Активный транспорт** must read `Bare/Hyperswarm (dev)`.
3. If BareKit cannot start, the row says it failed and messaging does
   **not** fall back to PeerJS. That is fail-closed, not success.

## Connect the two devices

1. Create a **new disposable identity** on each phone. Do not import a
   real account and do not reuse a phone that already has production
   chats. After the test, you can delete the accounts.
2. Exchange QR codes so each phone has the other as a contact. That
   shared contact secret is the discovery topic
   `HASH("orbits-contact-discovery-v1" || secret)`.
3. Keep both apps in the foreground on the same LAN or on networks that
   can reach the public Hyperswarm DHT.
4. Open the chat with the other contact. Opening the chat calls
   `connect()` with the **shared contact secret** (never `HASH(peerId)`).
   The worklet joins `HASH("orbits-contact-discovery-v1" || secret)`.
   PeerJS is not used on this path. If Bare cannot start, the transport
   row says it failed and messages are not sent.

## Message and file

1. Send a unique text from A. B must show that exact text.
2. Reply from B. A must show that exact reply.
3. Send a file of at least a few megabytes (the worklet cap is 50 MiB).
   Confirm the received file opens and matches.
4. Force-stop both apps, relaunch, confirm the conversation is still
   there (Corestore journal on device storage).
5. Send another message after restart.

## Diagnostics

The diagnostics page shows the active transport name only. It does not
log message bodies, private keys, or discovery secrets.

## Commands used to produce artifacts

```bash
bash tool/bare/fetch-official-runtime.sh --kit
npm ci --prefix tool/connectivity_harness
bash tool/bare/assemble-mobile-worklet.sh
flutter build apk --debug --split-per-abi \
  --dart-define=ORBITS_DEV_BARE_TRANSPORT=true
bash tool/bare/verify-packaged-kit.sh apk \
  build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk
```

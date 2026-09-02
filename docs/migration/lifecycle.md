# Lifecycle model

## iOS — do not promise always-on P2P

On background:

1. Stop discovery.
2. Finish or pause replication jobs.
3. Persist each Hypercore cursor.
4. Suspend Hyperswarm (`suspend()`).
5. Close sensitive IPC sessions.
6. Do **not** keep an incoming socket “for messages”.

On resume:

1. Recheck the network interface.
2. Recreate the UDP socket.
3. Resume the Bare worklet.
4. Reannounce discovery topics.
5. Connect to relay / storage peers.
6. Download missing encrypted blocks.
7. Project into Drift.
8. Show notifications **after** local decrypt.

Incoming delivery while suspended requires an **opaque APNs wake**, then
the steps above. CallKit reports an in-app incoming sheet with an opaque
handle and the name “Orbits”. PushKit / `voip` background mode is **not**
enabled — do not promise always-on P2P.

## Android

- FCM is the primary wake channel; UnifiedPush is optional later.
- Foreground service only where a live call or an explicit user-visible
  transfer justifies it.
- Doze: treat the socket as mortal; reconnect on resume / wake.
- `MainActivity` listens for `PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED`
  and forwards `{idle: true|false}` on `app.orbits/lifecycle`. Dart calls
  `TransportLifecycle.onDoze` / `onDozeExit`. This is not a messaging
  foreground service.
- `MainActivity` also listens for `Intent.ACTION_BATTERY_LOW` /
  `ACTION_BATTERY_OKAY` and forwards `{low: true|false}` on the same
  channel. Dart calls `NativeTransportHost.onLowBattery` which suspends,
  rolls back to PeerJS (`NativeRollbackReason.battery`), and abandons
  the native carrier. `onBatteryOkay` must **not** re-enable native.
- iOS `AppDelegate` mirrors low-battery onto `app.orbits/lifecycle`
  from `UIDevice.batteryStateDidChangeNotification` /
  `batteryLevelDidChangeNotification` (level ≤ 0.20 while unplugged).
- FCM SDK is not a required dependency. `OpaqueWakeService` accepts only
  an opaque token. `OrbitsWakeReceiver` drops extras that carry text,
  names, or peer IDs, then forwards the allowlisted token onto
  `app.orbits/push` (`wake`) when Flutter is attached. iOS APNs device
  tokens arrive as `token` on the same channel and stay on-device.
  A public push gateway is still not deployed.
  Mailbox deposit wakes call `dispatchMailboxWake` with on-device
  tokens (never a dummy `undeployed` token) and may POST the opaque
  wake to loopback `ORBITS_PUSH_GATEWAY_ORIGIN` only.
  `PushSender.sendApns` / `sendFcm` refuse while `kLiveApnsGateway` /
  `kLiveFcmGateway` are false. An APNs provider ES256 JWT may be built
  (Apple p8 scalar, not the identity key) and is still not sent. An FCM
  service-account RS256 JWT and the OAuth JWT-bearer token request may
  be built and are still not exchanged or sent. FCM HTTP v1 send
  `Authorization` is an OAuth access_token, never that assertion JWT.
- Foreground service is for an in-app Telecom call, not for keeping a
  messaging socket alive.

## Desktop

A user-owned desktop may stay online as a **personal mailbox** (delivery
mode 3). That is optional, not required for 1:1.

## Flutter process vs Bare worklet

| Event | Flutter | Bare |
|-------|---------|------|
| App background (iOS) | `suspend()` | Stop discovery, park sockets |
| App resume | `resume()` + `refreshNetwork()` | New UDP, reannounce |
| Vault lock | Tear down IPC that can touch keys | Keep transport keys only if still needed for resume; never export KEK |
| Worklet crash | Restart worklet, do not wipe Drift | Reload **the bundled** JS, never a remote URL |
| Flutter kill | OS; Drift WAL is the recover path | Worklet dies with the process |

## Calls

Media stays WebRTC. Path migration (Wi-Fi ↔ LTE) must not reset the
logical call without an explicit hangup. Hyperswarm relay is not TURN.

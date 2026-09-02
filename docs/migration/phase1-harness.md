# Phase 1 — Bare / Hyperswarm connectivity harness

Status: **scaffold ready / hardware-NAT validation pending.**

Phase 0 remediations are in tree. `kCompletedMigrationPhase` stays
**0**. This is a **verifiable, isolated** Node/Bare harness under
`tool/connectivity_harness/`. It is **not** wired into the Flutter
product. `HyperswarmRollout` stays `off`. Default live transport is
still PeerJS. Do not treat this document as a closed NAT gate.

## What is implemented

- Headless `Worklet`: `start` / `publish` / `connect` / `send` /
  `sendFile` / `suspend` / `resume` / `stop`, plus `markAuthenticated`,
  `cancelFile`, `diagnostics`.
- Mux (7-byte header) and IPC (10-byte `orbits-bare-ipc-v1` header) with
  **max frame size**, bounded pending buffers, and typed
  `malformed-frame` / `oversized-frame` errors. The worklet destroys that
  peer socket and emits `disconnected` with the same reason.
- Per-peer `authenticated` flag. **Default is `strict`**: a peer starts
  unauthenticated. Only `markAuthenticated(peerId)` (IPC from Dart after
  ADR-0001 DeviceBinding checks) flips it. Production Dart never sets
  `harnessAuth: 'local'` or `allowLocalAuth`. IPC `start` refuses
  `harnessAuth: 'local'` unless `allowLocalAuth === true`. In strict
  mode the only pre-auth pass-through is control `device-binding`
  (emitted, never auto-auth). `harness-hello` is dropped and counted in
  `droppedPreAuth`. Other frames are dropped, not queued. `'local'` is
  only for the CLI, `stand.js`, and tests that opt in.
- Per-peer outbound queue with a 4 MiB byte cap; `send()` waits for
  socket `drain`; overflow is `outbound-queue-full`. File send honours
  that backpressure per 64 KiB chunk. `MAX_FILE_BYTES` is 64 MiB on send
  and receive.
- `connect({ timeoutMs })` rejects with `connect-timeout`.
  `cancelFile(id)` (and `AbortSignal` on `sendFile`) stops the sender
  and, on the receiver, sends `harness-file-cancel` and deletes the
  partial file.
- Reconnect after `disconnected` replaces the socket without deleting a
  newer peer object. File resume still uses `harness-file-start` /
  `harness-file-resume` / chunk / end from the confirmed contiguous
  offset.
- `diagnostics()` JSON: lifecycle
  `idle|starting|started|suspended|stopping|stopped`, backend, per-peer
  path / timings / bytes / retryCount / disconnectReason / authenticated,
  totals, `droppedPreAuth`, `oversizedFrames`, active file transfers.
  IPC method `diagnostics`.
- `stop()` closes sockets, fds, timers (unref + clear), listeners,
  swarm, journal. Dedicated `no_hanging_handles.test.js` asserts
  handles shrink; `--test-force-exit` remains on the npm script for
  leftover Hyperswarm/UDX tests only.
- Security: no `eval` / `new Function` / remote `fetch` / `import()` /
  `require('://…')` in `src/`. Runtime refuse of `://` on
  worklet / file / journal / CLI paths. Discovery secret must be ≥ 32
  bytes. Topic is `HASH("orbits-contact-discovery-v1" || secret)`, never
  `HASH(peerId)`. IPC `send` / `sendFile` / `journal.append` reject
  `identityPrivateKey`, `fileKey`, `fileKeyB64`, `discoverySecret`.
- CLI `src/cli.js` (`bin`: `orbits-harness`): `listen`, `dial
  [host:port]`, stdin `echo` / `send-file` / `resume-file` /
  `diagnostics` / `shutdown`. Flags: `--backend`, `--secret-file`,
  `--timeout-ms`, `--diagnostics-out`, `--listen-host`, `--incoming-dir`,
  `--bootstrap`. Stdin is queued until the peer is connected and
  authenticated; timeout prints `ERR NOT_CONNECTED <cmd>` and exits
  non-zero. Listener prints `OK PEER connected|disconnected` and
  `OK FILE received <id> <bytes> sha256=… path=…`. `--help` / `-h` exit
  0. Hyperswarm dial **ignores** the optional target; the topic is
  always `HASH("orbits-contact-discovery-v1" || secret-file)`.
  `--diagnostics-out` is written after `stop()` (`lifecycle: stopped`).
  SIGINT/SIGTERM. No remote fetch.

Mux max is **1 MiB** (64 KiB attachment chunks base64 to ~87 KiB). IPC
max is **4 MiB**.

## What is verified automatically

```text
cd tool/connectivity_harness
npm test
node --test --test-force-exit test/cli_two_process.test.js
```

`npm test` is the full suite (Node 22). The second command is the
two-process CLI integration test alone. Behavioral tests, not
source-text `includes()` except the labeled source scan for eval/remote
import.

Covered on **loopback**:

- connect, echo, binary and empty payloads
- malformed / oversized frame → peer dropped
- 10 MiB file, sha256 equality
- kill socket mid-transfer, reconnect, resume from confirmed offset
- disconnect during handshake; reconnect after disconnect
- connect timeout; sender and receiver file cancel
- outbound queue cap typed rejection (queue bytes never exceed cap)
- resource cleanup / no hanging handles after `stop()`
- short / missing discovery secret rejected; `://` paths rejected
- pre-auth application frames dropped and counted
- two child `node src/cli.js` processes: queued echo before
  `OK CONNECTED`, 1 MiB `send-file` with listener `OK FILE received`
  (matching sha256), diagnostics after stop (`lifecycle: stopped`,
  `totals.bytesSent > 0`, `peers.*.authenticated`)

Hyperswarm-backend tests **skip if the module is missing**, same as
before. They use a **local** HyperDHT bootstrap only. They do **not**
prove public DHT, NAT, or UDP holepunch.

## What is loopback-only

Default backend binds `127.0.0.1` and connects to that host. CI echo,
file, resume, cancel, auth, CLI two-process, and handle-cleanup tests
are this path. `--listen-host 0.0.0.0` is opt-in LAN TCP and is still
**not** holepunch.

## What needs two machines

Share a **file**, not argv or chat paste of the raw secret if you can
avoid it:

```bash
# once, on a trusted machine
dd if=/dev/urandom of=secret.bin bs=32 count=1
# copy secret.bin to machine B (sneakernet / existing secure channel)
```

Loopback across a LAN (direct TCP, no NAT claim):

```bash
# Machine A
cd tool/connectivity_harness
node src/cli.js listen --backend loopback --listen-host 0.0.0.0 \
  --secret-file ./secret.bin --diagnostics-out ./a-diag.json \
  --incoming-dir ./incoming --timeout-ms 15000
# stdout:
#   OK LISTENING 0.0.0.0:<port> TOPIC <64-hex>
#   OK PEER connected <peerId> path=direct
#   OK FILE received <id> <bytes> sha256=<hex> path=./incoming/<name>
#   OK PEER disconnected <peerId> reason=<reason>
# tell B the reachable A address and port (LAN IP, not 0.0.0.0)

# Machine B
cd tool/connectivity_harness
node src/cli.js dial <A-LAN-IP>:<port> --backend loopback \
  --secret-file ./secret.bin --diagnostics-out ./b-diag.json --timeout-ms 15000
# stdout: OK CONNECTED <peerId> TOPIC <64-hex>
# stdin on B (safe to type or pipe before OK CONNECTED):
echo ping
send-file ./file.bin
shutdown
```

Hyperswarm (still not a NAT gate). Both sides need the **same**
secret file and an **explicit** bootstrap. There is no public-DHT
default. **`dial` does not take a topic hex as the join target** — both
sides already `publish` the secret-derived topic.

```bash
# Machine A (after you have a bootstrap host:port you control)
node src/cli.js listen --backend hyperswarm --secret-file ./secret.bin \
  --bootstrap <dht-host>:<dht-port> --diagnostics-out ./a-diag.json \
  --incoming-dir ./incoming
# stdout: OK LISTENING hyperswarm TOPIC <64-hex>
# The hex is HASH("orbits-contact-discovery-v1" || secret), not HASH(peerId).
# B does not need that hex to dial.

# Machine B
node src/cli.js dial --backend hyperswarm --secret-file ./secret.bin \
  --bootstrap <dht-host>:<dht-port> --diagnostics-out ./b-diag.json
# optional leftover host:port / hex on argv is ignored
# stdout: OK CONNECTED <peerId> TOPIC <same 64-hex>
# stdin: echo ping / send-file ./file.bin / shutdown
```

## What needs a real NAT / UDP / Kazakhstan matrix

Kcell / Beeline / Tele2 / home / corp / IPv4-only / IPv6 / dual-stack /
symmetric NAT / UDP-blocked / Wi-Fi↔LTE handover. `src/stand.js`
scenarios other than `loopback` stay **blocked** unless
`ORBITS_STAND_HARDWARE=1` and the operator is free. This repo must not
claim those gates are closed.

## Diagnostics and logs

- Worklet: `worklet.diagnostics()` and IPC `diagnostics`.
- CLI: `--diagnostics-out <path>` writes JSON **after** `stop()` on
  SIGINT/SIGTERM/`shutdown` (`lifecycle: stopped`, last-known peers).
- Stdout lines: `OK LISTENING …`, `OK CONNECTED …`,
  `OK PEER connected <id> path=direct|relay`,
  `OK PEER disconnected <id> reason=…`, `OK ECHO …`,
  `OK FILE sent …`, `OK FILE received <id> <bytes> sha256=… path=…`,
  `OK DIAGNOSTICS {…}`, `OK SHUTDOWN`, or `ERR NOT_CONNECTED <cmd>`.
- Peer drop reasons include `malformed-frame`, `oversized-frame`,
  `closed`, `local-disconnect`.

Expected local echo + file:

```text
OK LISTENING 127.0.0.1:41234 TOPIC a1…
OK PEER connected outbound:41234 path=direct
OK CONNECTED outbound:41234 TOPIC a1…
OK ECHO ping
OK FILE received abcd… 1048576 sha256=… path=/tmp/orbits-harness-incoming/…
OK SHUTDOWN
```

Exit code 0 on success; non-zero if listen/dial/secret/bootstrap fails.

## Honest remaining gap

Phase 1 acceptance in the master plan is a headless harness for echo,
files, path, and suspend **without** product wiring. That scaffold is in
tree and covered on loopback. **Two-machine NAT/UDP/Kazakhstan evidence
is not in CI and is not claimed.**

# Connectivity harness (Phase 1)

Headless Bare/Node worklet and CLI. **Not wired into the Flutter product.**
No UI, Drift, Hypercore-as-sync-source, new ratchets, or rooms.

Status: **scaffold ready / hardware-NAT validation pending.**

```text
npm test
node src/cli.js listen --secret-file ./secret.bin
node src/stand.js
```

`ORBITS_HARNESS_BACKEND=hyperswarm` uses HyperDHT and **requires an explicit
bootstrap**. Default is local TCP loopback so CI does not need UDP holepunching.

On Bare, `package.json` import maps send `node:fs` / `node:net` / … to
`bare-*` modules. Install those at **build time** with
`./vendor-bare-modules.sh` (never from Dart). Node CI does not need that
install; Node builtins still apply.

The worklet never fetches remote executable JS. Discovery topic is
`HASH("orbits-contact-discovery-v1" || sharedSecret)` — never `HASH(peerId)`.
Secrets are 32+ bytes and are read from `--secret-file`, never argv.

## Limits (documented)

| Cap | Value | Why |
|-----|------:|-----|
| `MAX_MUX_FRAME_BYTES` | 1 MiB | 64 KiB attachment chunks base64 to ~87 KiB; 1 MiB leaves slack |
| `MAX_MUX_PENDING_BYTES` | 1 MiB + 7 + 64 KiB | bounded decoder buffer |
| `MAX_IPC_FRAME_BYTES` | 4 MiB | path/descriptor IPC, not file bytes |
| `MAX_FILE_BYTES` | 64 MiB | send and receive |
| `OUTBOUND_QUEUE_CAP` | 4 MiB | per-peer outbound; excess is a typed `outbound-queue-full` |
| discovery secret | ≥ 32 bytes | reject shorter / absent |

Oversized or malformed mux frames destroy that peer socket with
`disconnected` reason `oversized-frame` / `malformed-frame`.

## Auth gating

Until `markAuthenticated(peerId)` (IPC) or a `harness-hello` /
`device-binding` control frame, only those two control types are
processed. Other channels are dropped and counted as `droppedPreAuth`
(not queued). Default `harnessAuth: 'local'` auto-authenticates on
connect so isolated harness tests and the CLI do not need Dart.

## CLI

```text
# same host, loopback
dd if=/dev/urandom of=secret.bin bs=32 count=1
node src/cli.js listen --backend loopback --secret-file ./secret.bin --diagnostics-out ./a.json
# stdout: OK LISTENING 127.0.0.1:<port> TOPIC <hex>
node src/cli.js dial 127.0.0.1:<port> --backend loopback --secret-file ./secret.bin --diagnostics-out ./b.json
# stdin (either process): echo ping | send-file <path> | resume-file <id> <path> | diagnostics | shutdown
```

Graceful SIGINT/SIGTERM. Non-zero exit on failure. See
[docs/migration/phase1-harness.md](../../docs/migration/phase1-harness.md)
for two-machine Hyperswarm commands and what is **not** verified.

Hardware NAT matrix (Kcell / Beeline / Tele2 / …) is **blocked** until the
operator is free. Set `ORBITS_STAND_HARDWARE=1` and
`ORBITS_STAND_SCENARIO=kcell` only then. This harness does **not** close
the NAT gate.

# LOCAL TESTNET — two localhost Orbits clients (PeerJS)

Production 1:1 signaling stays on public `0.peerjs.com` / `1.peerjs.com` /
`2.peerjs.com`. Hyperswarm rollout stays **off**. This page is only for
two clients on the same machine (or an RFC1918 LAN) when you **explicitly**
pin signaling.

Room hosting uses a different embedded server with a random key. Do not
reuse that path for 1:1: clients present the public PeerJS key `peerjs`.

## 1. Start loopback signaling

```bash
bash tool/local-peerjs-signaling.sh
```

That runs `npx peer` on `127.0.0.1:9000` (PeerJS 1.5, key `peerjs`). If the
process does not bind, the script exits non-zero — it does **not** fall back
to `*.peerjs.com`.

## 2. Launch two isolated GTK clients against that server

```bash
export ORBITS_PEERJS_HOST=127.0.0.1
export ORBITS_PEERJS_PORT=9000
export ORBITS_PEERJS_SECURE=false
bash tool/ci/two_linux_gtk_clients.sh
```

`two_linux_gtk_clients.sh` starts the loopback server itself when those
variables are unset, then launches Alice and Bob with isolated `$HOME`s.

Equivalent URL form:

```bash
export ORBITS_SIGNALING_URL=ws://127.0.0.1:9000
```

## 3. What you should see

Settings → Соединение → **Активный транспорт** must read
`PeerJS (localhost/testnet)`, not Bare/Hyperswarm.

Without any `ORBITS_PEERJS_*` / `ORBITS_SIGNALING_URL` variable the app still
dials public PeerJS (`wss://0.peerjs.com:443`).

## Env knobs

| Variable | Role |
| --- | --- |
| `ORBITS_SIGNALING_URL` | Full `ws://` / `wss://` URL. Pins the host. |
| `ORBITS_PEERJS_HOST` | Pinned host (disables `*.peerjs.com` rotation). |
| `ORBITS_PEERJS_PORT` | TCP port (default `9000` on localhost). |
| `ORBITS_PEERJS_SECURE` | `true`/`false`. Localhost defaults to `false` (`ws`). |
| `ORBITS_PEERJS_PATH` | Path prefix. Do not include `/peerjs` (the client appends it). |
| `ORBITS_PEERJS_KEY` | Optional. Default `peerjs` (matches `npx peer`). |

A partial override (port/key/path without host or URL) is **fail-closed**:
the app refuses to start rather than silently using the public cloud.

Compile-time `--dart-define=PEER_HOST=...` still exists for release builds.
Runtime `ORBITS_*` wins over those dart-defines so a prebuilt GTK binary can
be pointed at localhost without a rebuild.

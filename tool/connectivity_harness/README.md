# Connectivity harness (Phase 1)

Headless Bare/Node worklet. No Flutter UI, Drift, Hypercore, new ratchets, or rooms.

```text
node --test test/*.test.js
node src/stand.js
```

`ORBITS_HARNESS_BACKEND=hyperswarm` uses HyperDHT. Default is local TCP loopback so CI does not need UDP holepunching.

On Bare, `package.json` import maps send `node:fs` / `node:net` / … to
`bare-*` modules. Install those at **build time** with
`./vendor-bare-modules.sh` (never from Dart). Node CI does not need that
install; Node builtins still apply.

Hardware NAT matrix (Kcell / Beeline / Tele2 / …) is **blocked** until the operator is free. Set `ORBITS_STAND_HARDWARE=1` and `ORBITS_STAND_SCENARIO=kcell` only then.

The worklet never fetches remote executable JS.

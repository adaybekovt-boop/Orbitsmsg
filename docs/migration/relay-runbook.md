# Relay / mailbox operations runbook

Not deployed. This is the ops checklist for the public fleet.

## Roles

| Kind | Count | Notes |
|------|------:|-------|
| Bootstrap | 3 | Different regions (CA, EU, spare) |
| Connection relay | ≥2 | RTT-based client pick |
| Blind storage | ≥2 | Encrypted blocks only |

## Health

- `GET /health` on each node
- Signed relay directory, rotated keys
- Rate limits and amplification caps
- Capacity alerts on bandwidth and disk

## Incidents

1. Mark node unsound in the signed directory.
2. Clients fail over by RTT.
3. Rotate server keys if the host was exposed.
4. Do not inspect mailbox ciphertext.

Hardware placement, DDoS contracts, and volume backups are filled when
the fleet exists.

## Local loopback (CI only)

`tool/fleet/local_fleet.js` starts 3 bootstrap + 2 relay + 2 storage
on 127.0.0.1. When `hyperdht` is installed, bootstrap is a local
testnet (first three nodes) and the two extra nodes are relay rows
with DHT public keys for Hyperswarm `relayThrough`. HTTP health ports
are never used as HyperDHT addresses. Without the module, every row
is HTTP health. Hyperswarm bootstrap can also come from
`ORBITS_DHT_BOOTSTRAP=host:port,…` or HyperDHT-shaped rows in
`ORBITS_RELAY_DIRECTORY`. `tool/fleet/directory.js` maps fleet ports
to unsigned directory rows (`live: false`). Identity-signed
directories are Dart fixtures (`kLiveSignedRelayDirectory` stays
false). Dart never fetches a directory URL. This does not claim a
live NAT path.


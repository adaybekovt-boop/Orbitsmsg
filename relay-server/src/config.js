// Tunable limits for the relay server. All env-overridable for deployment.
//
// Defaults are aligned with the Flutter client: ws_relay_transport.dart caps
// INBOUND frames at 512 KiB, so the server accepts at most that per message —
// anything the server forwards is therefore also acceptable to the recipient.
//
// None of these values, and nothing this server ever logs, includes frame
// content. The relay is a dumb router: it measures sizes but never inspects
// the opaque `frame`.

function intEnv(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

export const config = {
  // Listen address.
  port: intEnv('PORT', 8080),
  host: process.env.HOST || '0.0.0.0',

  // Max raw WebSocket message size accepted before JSON parse. Aligned with the
  // client's 512 KiB inbound cap. Also enforced at the ws transport layer
  // (maxPayload) so oversized frames are rejected by the protocol itself.
  maxRawMessageBytes: intEnv('RELAY_MAX_MESSAGE_BYTES', 512 * 1024),

  // Max size of the opaque `frame` payload inside a relay message (belt &
  // braces under maxRawMessageBytes). Measured, never inspected.
  maxFrameBytes: intEnv('RELAY_MAX_FRAME_BYTES', 384 * 1024),

  // Identity / id length caps.
  maxPeerIdLen: intEnv('RELAY_MAX_PEER_ID_LEN', 64),
  maxIdLen: intEnv('RELAY_MAX_ID_LEN', 128),

  // Max concurrent connections (backstop against socket exhaustion).
  maxConnections: intEnv('RELAY_MAX_CONNECTIONS', 1000),

  // Per-connection token-bucket rate limit for inbound messages.
  rateCapacity: intEnv('RELAY_RATE_CAPACITY', 20),
  rateRefillPerSec: intEnv('RELAY_RATE_REFILL_PER_SEC', 10),

  // Relay messages older than this (by `ts`) are dropped as expired. Matches
  // the client RelayEnvelope.defaultTtlMs (24h).
  maxTtlMs: intEnv('RELAY_MAX_TTL_MS', 24 * 60 * 60 * 1000),

  // WebSocket liveness ping interval (terminate sockets that miss a pong).
  heartbeatMs: intEnv('RELAY_HEARTBEAT_MS', 30000),

  // ── Signed registration (relay Phase 2) ──
  // Random challenge nonce size in bytes (base64-encoded on the wire).
  nonceBytes: intEnv('RELAY_NONCE_BYTES', 24),
  // A challenge is only valid this long after it was issued.
  challengeTtlMs: intEnv('RELAY_CHALLENGE_TTL_MS', 30_000),
  // The signed `ts` must be within this many ms of the server clock (skew /
  // replay guard), in either direction.
  registerTsSkewMs: intEnv('RELAY_REGISTER_TS_SKEW_MS', 60_000),
  // Identity bound into the signed blob (replay-domain separation between relay
  // deployments). Defaults to a random per-process id; pin it with the env var
  // for a stable multi-instance deployment.
  serverId: process.env.RELAY_SERVER_ID || `relay-${randomId()}`,
};

function randomId() {
  // Avoid importing crypto at module top just for this; cheap unique-ish id.
  return Math.abs(Date.now() ^ (process.pid * 2654435761)).toString(36);
}

// Shared test helpers (NOT a test file — no `.test.js` suffix, so the runner
// won't execute it). Real Node P-256 crypto stands in for the Flutter client.

import crypto from 'node:crypto';
import { RelayHub } from '../src/hub.js';
import { buildRelayRegisterBlob } from '../src/register-blob.js';

export const A = 'ORBIT-AAAAAA';
export const B = 'ORBIT-BBBBBB';
export const C = 'ORBIT-CCCCCC';
export const SERVER_ID = 'test-relay';
export const NOW = 1_000_000;

export function fakeConn() {
  return {
    sent: [],
    closed: null,
    send(str) { this.sent.push(str); },
    close(code, reason) { this.closed = { code, reason }; },
    get messages() { return this.sent.map((s) => JSON.parse(s)); },
  };
}

export function makeHub(overrides = {}) {
  const { log, ...cfgOverrides } = overrides;
  const config = {
    maxRawMessageBytes: 512 * 1024,
    maxFrameBytes: 384 * 1024,
    maxPeerIdLen: 64,
    maxIdLen: 128,
    maxConnections: 1000,
    rateCapacity: 50,
    rateRefillPerSec: 10,
    maxTtlMs: 24 * 60 * 60 * 1000,
    heartbeatMs: 30000,
    nonceBytes: 24,
    challengeTtlMs: 30_000,
    registerTsSkewMs: 60_000,
    serverId: SERVER_ID,
    ...cfgOverrides,
  };
  let clock = NOW;
  const hub = new RelayHub({ config, now: () => clock, log });
  return { hub, config, advance: (ms) => { clock += ms; }, now: () => clock };
}

export function genKey() {
  return crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
}
export function idPubOf(kp) {
  return kp.publicKey.export({ format: 'der', type: 'spki' }).toString('base64');
}
export function signBlob(kp, { peer, nonce, ts, relay }) {
  const blob = Buffer.from(buildRelayRegisterBlob({ peer, nonce, ts, relay }), 'utf8');
  return crypto
    .sign('sha256', blob, { key: kp.privateKey, dsaEncoding: 'ieee-p1363' })
    .toString('base64');
}
export function challengeOf(conn) {
  return conn.messages.find((m) => m.type === 'relay_challenge');
}

/** Build the signed `register` message for a conn's issued challenge (does NOT
 * send it). Returns { msg, idPub, sig }. */
export function buildRegister(conn, peer, kp, ts) {
  const ch = challengeOf(conn);
  const idPub = idPubOf(kp);
  const sig = signBlob(kp, { peer, nonce: ch.nonce, ts, relay: ch.relay });
  return { msg: { type: 'register', peer, ts, nonce: ch.nonce, idPub, sig }, idPub, sig };
}

/** Full signed registration against the hub. Returns the hub result. */
export function doRegister(hub, conn, peer, kp, ts) {
  if (!conn._added) { hub.addConnection(conn); conn._added = true; }
  const { msg } = buildRegister(conn, peer, kp, ts);
  return hub.handleMessage(conn, JSON.stringify(msg));
}

export function relayMsg(from, to, id, frame, ts = NOW) {
  return JSON.stringify({ type: 'relay', from, to, id, ts, frame });
}

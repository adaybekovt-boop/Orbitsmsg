// RelayHub unit tests — pure (no `ws`), but using REAL Node P-256 crypto to
// exercise the full signed-registration path end to end. Run: node --test
//
// Proves: a challenge is issued on connect; a valid signed register succeeds;
// relay before registration is rejected; wrong nonce / stale ts / bad signature
// are rejected; server-side TOFU (same-key reconnect replaces, different-key
// rejected); forwarding still works after auth; the opaque frame is unchanged;
// plus the Phase-1 invariants (size caps, rate limit, offline, etc).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { RelayHub } from '../src/hub.js';
import { buildRelayRegisterBlob } from '../src/register-blob.js';

const A = 'ORBIT-AAAAAA';
const B = 'ORBIT-BBBBBB';
const C = 'ORBIT-CCCCCC';
const SERVER_ID = 'test-relay';
const NOW = 1_000_000;

function fakeConn() {
  return {
    sent: [],
    closed: null,
    send(str) { this.sent.push(str); },
    close(code, reason) { this.closed = { code, reason }; },
    get messages() { return this.sent.map((s) => JSON.parse(s)); },
  };
}

function makeHub(overrides = {}) {
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
    ...overrides,
  };
  let clock = NOW;
  const hub = new RelayHub({ config, now: () => clock });
  return { hub, config, advance: (ms) => { clock += ms; }, now: () => clock };
}

// ── Real P-256 identity helpers (Node side stands in for the Flutter client) ──
function genKey() {
  return crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
}
function idPubOf(kp) {
  return kp.publicKey.export({ format: 'der', type: 'spki' }).toString('base64');
}
function signBlob(kp, { peer, nonce, ts, relay }) {
  const blob = Buffer.from(buildRelayRegisterBlob({ peer, nonce, ts, relay }), 'utf8');
  return crypto
    .sign('sha256', blob, { key: kp.privateKey, dsaEncoding: 'ieee-p1363' })
    .toString('base64');
}
function challengeOf(conn) {
  return conn.messages.find((m) => m.type === 'relay_challenge');
}
function errorsOf(conn) {
  return conn.messages.filter((m) => m.type === 'register_error').map((m) => m.reason);
}

// Drive a full signed registration against the hub (addConnection issues the
// challenge; we answer it). Overrides let tests inject bad nonce/ts/key.
function doRegister(hub, conn, peer, kp, ts, over = {}) {
  if (!conn._added) { hub.addConnection(conn); conn._added = true; }
  const ch = challengeOf(conn);
  const nonce = over.nonce ?? ch.nonce;
  const relay = over.relay ?? ch.relay;
  const idPub = over.idPub ?? idPubOf(kp);
  const sig = over.sig ?? signBlob(kp, {
    peer,
    nonce: over.signNonce ?? nonce,
    ts: over.signTs ?? ts,
    relay: over.signRelay ?? relay,
  });
  return hub.handleMessage(conn, JSON.stringify({ type: 'register', peer, ts, nonce, idPub, sig }));
}

function relayMsg(from, to, id, frame, ts = NOW) {
  return JSON.stringify({ type: 'relay', from, to, id, ts, frame });
}

test('a challenge is sent immediately on connect', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  hub.addConnection(a);
  const ch = challengeOf(a);
  assert.ok(ch, 'relay_challenge sent');
  assert.equal(typeof ch.nonce, 'string');
  assert.ok(ch.nonce.length > 0);
  assert.equal(ch.relay, SERVER_ID);
  assert.equal(typeof ch.ts, 'number');
});

test('a valid signed registration succeeds (register_ok)', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  const res = doRegister(hub, a, A, genKey(), now());
  assert.equal(res.action, 'registered');
  assert.equal(res.peer, A);
  assert.ok(a.messages.some((m) => m.type === 'register_ok' && m.peer === A));
  assert.equal(hub.peers.get(A), a);
});

test('relay BEFORE registration is rejected (not_registered)', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  const b = fakeConn();
  hub.addConnection(a); // challenged, NOT registered
  hub.addConnection(b);
  const res = hub.handleMessage(a, relayMsg(A, B, 'm1', 'v2:x'));
  assert.equal(res.reason, 'not_registered');
  assert.equal(b.messages.filter((m) => m.type === 'relay').length, 0);
});

test('wrong nonce is rejected', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  const res = doRegister(hub, a, A, genKey(), now(), { nonce: 'WRONG-NONCE' });
  assert.equal(res.reason, 'bad_nonce');
  assert.ok(errorsOf(a).includes('bad_nonce'));
  assert.equal(hub.peers.size, 0);
});

test('stale timestamp is rejected', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  const staleTs = now() - 5 * 60_000; // 5 min old, skew is 60s
  const res = doRegister(hub, a, A, genKey(), staleTs);
  assert.equal(res.reason, 'stale_ts');
  assert.equal(hub.peers.size, 0);
});

test('expired challenge is rejected', () => {
  const { hub, advance, now } = makeHub();
  const a = fakeConn();
  hub.addConnection(a); a._added = true;
  advance(31_000); // challenge TTL is 30s
  const res = doRegister(hub, a, A, genKey(), now());
  assert.equal(res.reason, 'challenge_expired');
  assert.equal(hub.peers.size, 0);
});

test('invalid signature is rejected', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  // Sign a DIFFERENT blob (wrong peer) so nonce/ts pass but the signature
  // doesn't verify against the canonical blob the server rebuilds.
  const kp = genKey();
  hub.addConnection(a); a._added = true;
  const ch = challengeOf(a);
  const badSig = signBlob(kp, { peer: 'ORBIT-FFFFFF', nonce: ch.nonce, ts: now(), relay: ch.relay });
  const res = hub.handleMessage(a, JSON.stringify({
    type: 'register', peer: A, ts: now(), nonce: ch.nonce, idPub: idPubOf(kp), sig: badSig,
  }));
  assert.equal(res.reason, 'bad_signature');
  assert.equal(hub.peers.size, 0);
});

test('a tampered idPub (wrong key) fails verification', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  // Sign with kp1 but present kp2's public key.
  const kp1 = genKey();
  const kp2 = genKey();
  hub.addConnection(a); a._added = true;
  const ch = challengeOf(a);
  const sig = signBlob(kp1, { peer: A, nonce: ch.nonce, ts: now(), relay: ch.relay });
  const res = hub.handleMessage(a, JSON.stringify({
    type: 'register', peer: A, ts: now(), nonce: ch.nonce, idPub: idPubOf(kp2), sig,
  }));
  assert.equal(res.reason, 'bad_signature');
});

test('invalid peer id is rejected + socket closed', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  const res = doRegister(hub, a, 'not-orbit', genKey(), now());
  assert.equal(res.reason, 'invalid_peer');
  assert.equal(a.closed.code, 4002);
});

test('TOFU: same peer + SAME key reconnect REPLACES old socket (4001)', () => {
  const { hub, now } = makeHub();
  const kp = genKey();
  const a1 = fakeConn();
  const a2 = fakeConn();
  assert.equal(doRegister(hub, a1, A, kp, now()).action, 'registered');
  assert.equal(doRegister(hub, a2, A, kp, now()).action, 'registered');
  assert.equal(a1.closed.code, 4001, 'old socket closed');
  assert.equal(hub.peers.get(A), a2, 'new socket is live');
  assert.equal(hub.peers.size, 1);
});

test('TOFU: same peer + DIFFERENT key is rejected as hijack (key_changed)', () => {
  const { hub, now } = makeHub();
  const a1 = fakeConn();
  const a2 = fakeConn();
  assert.equal(doRegister(hub, a1, A, genKey(), now()).action, 'registered');
  // Attacker connects and tries to claim A with a different identity key.
  const res = doRegister(hub, a2, A, genKey(), now());
  assert.equal(res.reason, 'key_changed');
  assert.ok(errorsOf(a2).includes('key_changed'));
  assert.equal(a1.closed, null, 'the legitimate socket is NOT disturbed');
  assert.equal(hub.peers.get(A), a1, 'legit holder keeps the peer');
});

test('after registration, relay forwarding works + frame is opaque/unchanged', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  const b = fakeConn();
  doRegister(hub, a, A, genKey(), now());
  doRegister(hub, b, B, genKey(), now());
  const frame = { type: 'wireHello', pub: 'KEY==', nested: { arr: [1, 2, 3] } };
  const res = hub.handleMessage(a, relayMsg(A, B, 'm1', frame));
  assert.equal(res.action, 'forwarded');
  const got = b.messages.find((m) => m.type === 'relay');
  assert.ok(got);
  assert.deepEqual(got.frame, frame);
  assert.equal(got.from, A);
  assert.equal(got.to, B);
});

test('relay does NOT forward to an unrelated registered peer', () => {
  const { hub, now } = makeHub();
  const a = fakeConn(); const b = fakeConn(); const c = fakeConn();
  doRegister(hub, a, A, genKey(), now());
  doRegister(hub, b, B, genKey(), now());
  doRegister(hub, c, C, genKey(), now());
  hub.handleMessage(a, relayMsg(A, B, 'm1', 'v2:x'));
  assert.equal(b.messages.filter((m) => m.type === 'relay').length, 1);
  assert.equal(c.messages.filter((m) => m.type === 'relay').length, 0);
});

test('a registered peer cannot spoof `from`', () => {
  const { hub, now } = makeHub();
  const a = fakeConn(); const b = fakeConn();
  doRegister(hub, a, A, genKey(), now());
  doRegister(hub, b, B, genKey(), now());
  const res = hub.handleMessage(a, relayMsg(C, B, 'm1', 'v2:x')); // A claims from=C
  assert.equal(res.reason, 'from_mismatch');
  assert.equal(b.messages.filter((m) => m.type === 'relay').length, 0);
});

test('offline recipient → relay_error to sender', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  doRegister(hub, a, A, genKey(), now());
  const res = hub.handleMessage(a, relayMsg(A, B, 'm9', 'v2:x'));
  assert.equal(res.action, 'offline');
  const err = a.messages.find((m) => m.type === 'relay_error' && m.id === 'm9');
  assert.equal(err.reason, 'offline');
});

test('expired (stale ts) relay frame is dropped', () => {
  const { hub, now } = makeHub({ maxTtlMs: 1000 });
  const a = fakeConn(); const b = fakeConn();
  doRegister(hub, a, A, genKey(), now());
  doRegister(hub, b, B, genKey(), now());
  const res = hub.handleMessage(a, relayMsg(A, B, 'm1', 'v2:x', now() - 5000));
  assert.equal(res.reason, 'expired');
  assert.equal(b.messages.filter((m) => m.type === 'relay').length, 0);
});

test('malformed JSON / bad message / unknown type are rejected, no crash', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  hub.addConnection(a);
  assert.equal(hub.handleMessage(a, '{not json').reason, 'bad_json');
  assert.equal(hub.handleMessage(a, '[]').reason, 'bad_message');
  assert.equal(hub.handleMessage(a, '{"no":"type"}').reason, 'bad_message');
  assert.equal(hub.handleMessage(a, '{"type":"hax"}').reason, 'unknown_type');
});

test('oversized raw message is rejected before parse', () => {
  const { hub } = makeHub({ maxRawMessageBytes: 1024 });
  const a = fakeConn();
  hub.addConnection(a);
  assert.equal(hub.handleMessage(a, 'x'.repeat(2048)).reason, 'oversize');
});

test('oversized frame is rejected (registered sender)', () => {
  const { hub, now } = makeHub({ maxFrameBytes: 1024 });
  const a = fakeConn(); const b = fakeConn();
  doRegister(hub, a, A, genKey(), now());
  doRegister(hub, b, B, genKey(), now());
  const res = hub.handleMessage(a, relayMsg(A, B, 'm1', 'y'.repeat(4096)));
  assert.equal(res.reason, 'frame_too_big');
});

test('rate limit rejects spam past the bucket', () => {
  const { hub, now } = makeHub({ rateCapacity: 5, rateRefillPerSec: 1 });
  const a = fakeConn(); const b = fakeConn();
  // doRegister consumes 1 token on `a` (the register message).
  doRegister(hub, a, A, genKey(), now());
  doRegister(hub, b, B, genKey(), now());
  let forwarded = 0; let limited = 0;
  for (let i = 0; i < 6; i++) {
    const r = hub.handleMessage(a, relayMsg(A, B, `m${i}`, 'v2:x'));
    if (r.action === 'forwarded') forwarded++;
    if (r.reason === 'rate_limited') limited++;
  }
  assert.equal(forwarded, 4); // 5 cap − 1 consumed by register
  assert.ok(limited >= 1);
});

test('max connections backstop closes excess sockets', () => {
  const { hub } = makeHub({ maxConnections: 1 });
  const a = fakeConn(); const b = fakeConn();
  assert.equal(hub.addConnection(a), true);
  assert.equal(hub.addConnection(b), false);
  assert.equal(b.closed.code, 1013);
});

test('removeConnection frees the peer mapping (TOFU pin persists)', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  const kp = genKey();
  doRegister(hub, a, A, kp, now());
  assert.equal(hub.peers.size, 1);
  hub.removeConnection(a);
  assert.equal(hub.peers.size, 0);
  assert.equal(hub.connectionCount, 0);
  // The TOFU pin survives a disconnect: reconnecting with the SAME key is fine,
  // a DIFFERENT key is still rejected.
  const a2 = fakeConn();
  assert.equal(doRegister(hub, a2, A, kp, now()).action, 'registered');
  const a3 = fakeConn();
  assert.equal(doRegister(hub, a3, A, genKey(), now()).reason, 'key_changed');
});

test('relay with a null frame is rejected', () => {
  const { hub, now } = makeHub();
  const a = fakeConn(); const b = fakeConn();
  doRegister(hub, a, A, genKey(), now());
  doRegister(hub, b, B, genKey(), now());
  const res = hub.handleMessage(a, JSON.stringify({ type: 'relay', from: A, to: B, id: 'm1', frame: null }));
  assert.equal(res.reason, 'bad_envelope');
});

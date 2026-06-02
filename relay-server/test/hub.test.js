// RelayHub unit tests — pure, no `ws`, no network. Run with: node --test
//
// These prove the security-critical invariants of the relay:
//   register stores a peer; relay forwards to the recipient only; malformed /
//   oversized / unregistered / offline / duplicate / rate-limited behaviors;
//   and that the opaque frame is forwarded byte-identical and never inspected.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RelayHub } from '../src/hub.js';

// A fake connection: records everything sent / how it was closed. The hub only
// requires send(string) + close(code, reason).
function fakeConn() {
  return {
    sent: [],
    closed: null,
    send(str) { this.sent.push(str); },
    close(code, reason) { this.closed = { code, reason }; },
    // Parsed view of what the hub forwarded to this conn.
    get messages() { return this.sent.map((s) => JSON.parse(s)); },
    last() { return this.messages[this.messages.length - 1]; },
  };
}

// A hub with a controllable clock and generous limits (overridden per test).
function makeHub(overrides = {}) {
  const config = {
    maxRawMessageBytes: 512 * 1024,
    maxFrameBytes: 384 * 1024,
    maxPeerIdLen: 64,
    maxIdLen: 128,
    maxConnections: 1000,
    rateCapacity: 20,
    rateRefillPerSec: 10,
    maxTtlMs: 24 * 60 * 60 * 1000,
    heartbeatMs: 30000,
    ...overrides,
  };
  let clock = 1_000_000;
  const hub = new RelayHub({ config, now: () => clock });
  return { hub, config, advance: (ms) => { clock += ms; }, setNow: (v) => { clock = v; }, now: () => clock };
}

const A = 'ORBIT-AAAAAA';
const B = 'ORBIT-BBBBBB';
const C = 'ORBIT-CCCCCC';

function register(hub, conn, peer) {
  hub.addConnection(conn);
  return hub.handleMessage(conn, JSON.stringify({ type: 'register', peer }));
}

function relayMsg(from, to, id, frame, extra = {}) {
  return JSON.stringify({ type: 'relay', from, to, id, ts: 1_000_000, frame, ...extra });
}

test('register stores a peer (normalized)', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  const res = register(hub, a, 'orbit-aaaaaa'); // lower-case → normalized
  assert.equal(res.action, 'registered');
  assert.equal(res.peer, A);
  assert.equal(hub.peerCount, 1);
  assert.equal(hub.peers.get(A), a);
});

test('relay forwards to the recipient, opaque frame unchanged', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  const b = fakeConn();
  register(hub, a, A);
  register(hub, b, B);

  // A complex frame (here a control-map shape) must arrive byte-identical.
  const frame = { type: 'wireHello', pub: 'KEYDATA==', nested: { n: 1, arr: [1, 2, 3] } };
  const res = hub.handleMessage(a, relayMsg(A, B, 'm1', frame));

  assert.equal(res.action, 'forwarded');
  assert.equal(b.sent.length, 1);
  const got = b.last();
  assert.equal(got.type, 'relay');
  assert.equal(got.from, A);
  assert.equal(got.to, B);
  assert.equal(got.id, 'm1');
  assert.deepEqual(got.frame, frame, 'frame forwarded opaque + unchanged');
});

test('a string ciphertext frame round-trips identically', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  const b = fakeConn();
  register(hub, a, A);
  register(hub, b, B);
  const cipher = 'v2:aGVhZGVy:aXY:Y2lwaGVydGV4dA==';
  hub.handleMessage(a, relayMsg(A, B, 'm1', cipher));
  assert.equal(b.last().frame, cipher);
});

test('relay does NOT forward to an unrelated peer', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  const b = fakeConn();
  const c = fakeConn();
  register(hub, a, A);
  register(hub, b, B);
  register(hub, c, C);
  hub.handleMessage(a, relayMsg(A, B, 'm1', 'v2:x'));
  assert.equal(b.sent.length, 1, 'recipient B got it');
  assert.equal(c.sent.length, 0, 'unrelated C got nothing');
});

test('malformed JSON is rejected without crashing', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  hub.addConnection(a);
  const res = hub.handleMessage(a, '{not json');
  assert.equal(res.action, 'rejected');
  assert.equal(res.reason, 'bad_json');
});

test('non-object / arrays / missing type are rejected', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  hub.addConnection(a);
  assert.equal(hub.handleMessage(a, '123').reason, 'bad_message');
  assert.equal(hub.handleMessage(a, '[]').reason, 'bad_message');
  assert.equal(hub.handleMessage(a, '{"no":"type"}').reason, 'bad_message');
  assert.equal(hub.handleMessage(a, '"hi"').reason, 'bad_message');
});

test('unknown message type is rejected', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  hub.addConnection(a);
  assert.equal(hub.handleMessage(a, '{"type":"hax"}').reason, 'unknown_type');
});

test('oversized raw message is rejected before parse', () => {
  const { hub } = makeHub({ maxRawMessageBytes: 1024 });
  const a = fakeConn();
  register(hub, a, A);
  const huge = 'x'.repeat(2048);
  const res = hub.handleMessage(a, huge);
  assert.equal(res.action, 'rejected');
  assert.equal(res.reason, 'oversize');
});

test('oversized frame (within raw cap) is rejected', () => {
  const { hub } = makeHub({ maxRawMessageBytes: 1024 * 1024, maxFrameBytes: 1024 });
  const a = fakeConn();
  const b = fakeConn();
  register(hub, a, A);
  register(hub, b, B);
  const bigFrame = 'y'.repeat(4096);
  const res = hub.handleMessage(a, relayMsg(A, B, 'm1', bigFrame));
  assert.equal(res.reason, 'frame_too_big');
  assert.equal(b.sent.length, 0);
});

test('invalid peer id on register is rejected + socket closed', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  hub.addConnection(a);
  const res = hub.handleMessage(a, JSON.stringify({ type: 'register', peer: 'not-an-orbit-id' }));
  assert.equal(res.reason, 'invalid_peer');
  assert.equal(a.closed.code, 4002);
  assert.equal(hub.peerCount, 0);
});

test('empty peer id is rejected', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  hub.addConnection(a);
  assert.equal(hub.handleMessage(a, '{"type":"register","peer":""}').reason, 'invalid_peer');
});

test('unregistered sender cannot relay (explicit not_registered)', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  const b = fakeConn();
  hub.addConnection(a); // NOT registered
  register(hub, b, B);
  const res = hub.handleMessage(a, relayMsg(A, B, 'm1', 'v2:x'));
  assert.equal(res.action, 'rejected');
  assert.equal(res.reason, 'not_registered');
  assert.equal(b.sent.length, 0);
  assert.equal(a.last().type, 'relay_error');
  assert.equal(a.last().reason, 'not_registered');
});

test('a registered peer cannot spoof `from` (anti-spoof)', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  const b = fakeConn();
  register(hub, a, A);
  register(hub, b, B);
  // A tries to relay AS C.
  const res = hub.handleMessage(a, relayMsg(C, B, 'm1', 'v2:x'));
  assert.equal(res.reason, 'from_mismatch');
  assert.equal(b.sent.length, 0);
  assert.equal(a.last().reason, 'from_mismatch');
});

test('offline recipient → relay_error to sender, no delivery', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  register(hub, a, A);
  // B never registered.
  const res = hub.handleMessage(a, relayMsg(A, B, 'm1', 'v2:x'));
  assert.equal(res.action, 'offline');
  assert.equal(a.last().type, 'relay_error');
  assert.equal(a.last().id, 'm1');
  assert.equal(a.last().reason, 'offline');
});

test('expired (stale ts) relay is dropped', () => {
  const { hub, now } = makeHub({ maxTtlMs: 1000 });
  const a = fakeConn();
  const b = fakeConn();
  register(hub, a, A);
  register(hub, b, B);
  const staleTs = now() - 5000; // 5s old, ttl 1s
  const res = hub.handleMessage(a, relayMsg(A, B, 'm1', 'v2:x', { ts: staleTs }));
  assert.equal(res.reason, 'expired');
  assert.equal(b.sent.length, 0);
  assert.equal(a.last().reason, 'expired');
});

test('duplicate registration REPLACES the old socket (closed 4001)', () => {
  const { hub } = makeHub();
  const a1 = fakeConn();
  const a2 = fakeConn();
  register(hub, a1, A);
  register(hub, a2, A); // same peer, new socket
  assert.equal(a1.closed.code, 4001, 'old socket closed');
  assert.equal(hub.peers.get(A), a2, 'new socket is the live one');
  assert.equal(hub.peerCount, 1);

  // Frames to A now go to the NEW socket only.
  const b = fakeConn();
  register(hub, b, B);
  hub.handleMessage(b, relayMsg(B, A, 'm1', 'v2:x'));
  assert.equal(a2.sent.length, 1);
  // a1 only ever saw nothing forwarded (its one entry, if any, was the close).
  assert.equal(a1.messages.filter((m) => m.type === 'relay').length, 0);
});

test('rate limit rejects spam past the bucket', () => {
  // capacity 5, no refill within the test (clock frozen).
  const { hub } = makeHub({ rateCapacity: 5, rateRefillPerSec: 1 });
  const a = fakeConn();
  const b = fakeConn();
  // register consumes 1 token from each conn's bucket.
  hub.addConnection(a);
  hub.addConnection(b);
  hub.handleMessage(a, JSON.stringify({ type: 'register', peer: A })); // token #1
  hub.handleMessage(b, JSON.stringify({ type: 'register', peer: B }));

  // a has 4 tokens left → 4 relays succeed, the 5th is rate_limited.
  let forwarded = 0;
  let limited = 0;
  for (let i = 0; i < 6; i++) {
    const r = hub.handleMessage(a, relayMsg(A, B, `m${i}`, 'v2:x'));
    if (r.action === 'forwarded') forwarded++;
    if (r.reason === 'rate_limited') limited++;
  }
  assert.equal(forwarded, 4);
  assert.ok(limited >= 1, 'at least one message rate-limited');
});

test('rate bucket refills over time', () => {
  const { hub, advance } = makeHub({ rateCapacity: 2, rateRefillPerSec: 10 });
  const a = fakeConn();
  const b = fakeConn();
  hub.addConnection(a);
  hub.addConnection(b);
  hub.handleMessage(a, JSON.stringify({ type: 'register', peer: A }));
  hub.handleMessage(b, JSON.stringify({ type: 'register', peer: B }));
  // Drain the bucket.
  hub.handleMessage(a, relayMsg(A, B, 'm1', 'v2:x'));
  const drained = hub.handleMessage(a, relayMsg(A, B, 'm2', 'v2:x'));
  // After draining, next is limited...
  const limited = hub.handleMessage(a, relayMsg(A, B, 'm3', 'v2:x'));
  assert.equal(limited.reason, 'rate_limited');
  // ...wait 1s → +10 tokens (capped at 2) → succeeds again.
  advance(1000);
  const ok = hub.handleMessage(a, relayMsg(A, B, 'm4', 'v2:x'));
  assert.equal(ok.action, 'forwarded');
  assert.ok(drained); // referenced to avoid unused-var lints
});

test('removeConnection frees the peer mapping', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  register(hub, a, A);
  assert.equal(hub.peerCount, 1);
  hub.removeConnection(a);
  assert.equal(hub.peerCount, 0);
  assert.equal(hub.connectionCount, 0);
});

test('max connections backstop closes excess sockets', () => {
  const { hub } = makeHub({ maxConnections: 1 });
  const a = fakeConn();
  const b = fakeConn();
  assert.equal(hub.addConnection(a), true);
  assert.equal(hub.addConnection(b), false);
  assert.equal(b.closed.code, 1013);
  assert.equal(hub.connectionCount, 1);
});

test('relay with a null frame is rejected (nothing to route)', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  const b = fakeConn();
  register(hub, a, A);
  register(hub, b, B);
  const res = hub.handleMessage(a, JSON.stringify({ type: 'relay', from: A, to: B, id: 'm1', frame: null }));
  assert.equal(res.reason, 'bad_envelope');
  assert.equal(b.sent.length, 0);
});

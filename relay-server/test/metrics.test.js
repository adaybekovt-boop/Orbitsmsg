// Phase 3: safe metrics counters + log safety + origin allowlist.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { originAllowed } from '../src/server.js';
import {
  A, B, C, NOW,
  fakeConn, makeHub, genKey, doRegister, relayMsg, buildRegister,
} from './helpers.js';

test('metricsSnapshot exposes ONLY safe aggregate counts', () => {
  const { hub } = makeHub();
  const snap = hub.metricsSnapshot();
  // Exactly the safe keys — no frames, ids, keys, or signatures.
  assert.deepEqual(
    Object.keys(snap).sort(),
    [
      'activeConnections', 'forwarded', 'knownPeerKeys', 'offlineRecipient',
      'registeredPeers', 'rejectedAuth', 'rejectedMalformed',
      'rejectedRateLimit', 'totalRelayAttempts',
    ].sort(),
  );
  for (const v of Object.values(snap)) assert.equal(typeof v, 'number');
});

test('counters increment for forward / offline / reject categories', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  const b = fakeConn();
  doRegister(hub, a, A, genKey(), now());
  doRegister(hub, b, B, genKey(), now());

  hub.handleMessage(a, relayMsg(A, B, 'm1', 'v2:x')); // forwarded
  hub.handleMessage(a, relayMsg(A, C, 'm2', 'v2:x')); // offline (C not here)

  // unregistered sender → auth reject
  const u = fakeConn();
  hub.addConnection(u);
  hub.handleMessage(u, relayMsg('ORBIT-DDDDDD', B, 'm3', 'v2:x'));

  // malformed
  hub.handleMessage(a, '{bad json');
  hub.handleMessage(a, '{"type":"weird"}');

  const snap = hub.metricsSnapshot();
  assert.equal(snap.registeredPeers, 2);
  assert.equal(snap.totalRelayAttempts, 3); // m1, m2, m3
  assert.equal(snap.forwarded, 1);
  assert.equal(snap.offlineRecipient, 1);
  assert.equal(snap.rejectedAuth, 1); // not_registered
  assert.equal(snap.rejectedMalformed, 2); // bad_json + unknown_type
  assert.ok(snap.knownPeerKeys >= 2);
});

test('rate-limit rejections are counted', () => {
  const { hub, now } = makeHub({ rateCapacity: 3, rateRefillPerSec: 0.001 });
  const a = fakeConn();
  const b = fakeConn();
  doRegister(hub, a, A, genKey(), now()); // consumes 1 token on a
  doRegister(hub, b, B, genKey(), now());
  for (let i = 0; i < 6; i++) hub.handleMessage(a, relayMsg(A, B, `m${i}`, 'v2:x'));
  assert.ok(hub.metricsSnapshot().rejectedRateLimit >= 1);
});

test('logs NEVER contain frame / idPub / sig contents', () => {
  const logs = [];
  const { hub, now } = makeHub({ log: (event, meta) => logs.push({ event, meta }) });
  const a = fakeConn();
  const b = fakeConn();

  // Register with REAL keys (so idPub/sig are long base64 strings we can grep).
  hub.addConnection(a); a._added = true;
  const reg = buildRegister(a, A, genKey(), now());
  hub.handleMessage(a, JSON.stringify(reg.msg));
  doRegister(hub, b, B, genKey(), now());

  // Forward a frame carrying a unique marker we can search for.
  const marker = 'SECRET_FRAME_MARKER_v2:do-not-log-me';
  hub.handleMessage(a, relayMsg(A, B, 'm1', marker));

  const dump = JSON.stringify(logs);
  assert.ok(!dump.includes(marker), 'frame content must never be logged');
  assert.ok(!dump.includes(reg.sig), 'signature must never be logged');
  assert.ok(!dump.includes(reg.idPub), 'idPub must never be logged');
  // Full peer id should not be logged either — only the 4-char tail.
  assert.ok(!dump.includes(A), 'full peer id must not be logged (tail only)');
  assert.ok(dump.includes(A.slice(-4)), 'peer-id tail IS logged for ops');
});

test('originAllowed: no allowlist ⇒ allow all; native (no origin) always allowed', () => {
  assert.equal(originAllowed('https://evil.test', null), true);
  assert.equal(originAllowed('https://evil.test', []), true);
  assert.equal(originAllowed(undefined, ['https://ok.test']), true); // native client
  assert.equal(originAllowed('', ['https://ok.test']), true);
  assert.equal(originAllowed('https://ok.test', ['https://ok.test']), true);
  assert.equal(originAllowed('https://evil.test', ['https://ok.test']), false);
});

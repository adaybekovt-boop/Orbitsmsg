// End-to-end smoke test over REAL WebSockets with the signed-registration flow:
// start the server, connect two clients, each answers the server challenge with
// a real ECDSA P-256 signature, then A relays a frame to B and we assert B gets
// the exact frame. Requires the `ws` dependency (npm install); skips cleanly if
// absent so the dependency-free hub/blob tests still run.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { buildRelayRegisterBlob } from '../src/register-blob.js';

let WebSocket;
let startRelayServer;
let available = true;
try {
  ({ WebSocket } = await import('ws'));
  ({ startRelayServer } = await import('../src/server.js'));
} catch {
  available = false;
}

const A = 'ORBIT-AAAAAA';
const B = 'ORBIT-BBBBBB';

function testConfig() {
  return {
    port: 0,
    host: '127.0.0.1',
    maxRawMessageBytes: 512 * 1024,
    maxFrameBytes: 384 * 1024,
    maxPeerIdLen: 64,
    maxIdLen: 128,
    maxConnections: 100,
    rateCapacity: 50,
    rateRefillPerSec: 50,
    maxTtlMs: 24 * 60 * 60 * 1000,
    heartbeatMs: 60000,
    nonceBytes: 24,
    challengeTtlMs: 30_000,
    registerTsSkewMs: 60_000,
    serverId: 'smoke-relay',
  };
}

// A client that auto-answers the relay challenge with a signed registration
// using a fresh P-256 identity key (stands in for the Flutter identity key).
function signingClient(port, peer) {
  const kp = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const inbox = [];
  const waiters = [];
  let registered = false;
  const regWaiters = [];

  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString('utf8'));
    if (msg.type === 'relay_challenge') {
      const ts = Date.now();
      const blob = Buffer.from(
        buildRelayRegisterBlob({ peer, nonce: msg.nonce, ts, relay: msg.relay }),
        'utf8',
      );
      const sig = crypto
        .sign('sha256', blob, { key: kp.privateKey, dsaEncoding: 'ieee-p1363' })
        .toString('base64');
      ws.send(JSON.stringify({
        type: 'register',
        peer,
        ts,
        nonce: msg.nonce,
        idPub: kp.publicKey.export({ format: 'der', type: 'spki' }).toString('base64'),
        sig,
      }));
      return;
    }
    if (msg.type === 'register_ok') {
      registered = true;
      regWaiters.splice(0).forEach((r) => r());
      return;
    }
    inbox.push(msg);
    const w = waiters.shift();
    if (w) w(msg);
  });

  let opened = false;
  const openWaiters = [];
  ws.on('open', () => { opened = true; openWaiters.splice(0).forEach((r) => r()); });

  return {
    open: () => (opened ? Promise.resolve() : new Promise((r) => openWaiters.push(r))),
    registered: () => (registered ? Promise.resolve() : new Promise((r) => regWaiters.push(r))),
    relay: (to, id, frame) => ws.send(JSON.stringify({ type: 'relay', from: peer, to, id, ts: Date.now(), frame })),
    next: () => (inbox.length ? Promise.resolve(inbox.shift()) : new Promise((r) => waiters.push(r))),
    inboxLength: () => inbox.length,
    close: () => ws.close(),
  };
}

test('signed handshake: A & B register, A → B frame arrives identical', {
  skip: available ? false : 'ws not installed (run `npm install` in relay-server/)',
}, async () => {
  const handle = await startRelayServer({ config: testConfig(), log: () => {} });
  const port = handle.httpServer.address().port;
  const a = signingClient(port, A);
  const b = signingClient(port, B);
  try {
    await Promise.all([a.open(), b.open()]);
    await Promise.all([a.registered(), b.registered()]); // both completed signed register

    const frame = 'v2:hdr:iv:opaqueCiphertext==';
    a.relay(B, 'm1', frame);

    const got = await b.next();
    assert.equal(got.type, 'relay');
    assert.equal(got.from, A);
    assert.equal(got.to, B);
    assert.equal(got.id, 'm1');
    assert.equal(got.frame, frame, 'B received the exact frame A sent');
  } finally {
    a.close();
    b.close();
    await handle.close();
  }
});

test('unrelated client C never receives an A → B frame', {
  skip: available ? false : 'ws not installed',
}, async () => {
  const C = 'ORBIT-CCCCCC';
  const handle = await startRelayServer({ config: testConfig(), log: () => {} });
  const port = handle.httpServer.address().port;
  const a = signingClient(port, A);
  const b = signingClient(port, B);
  const c = signingClient(port, C);
  try {
    await Promise.all([a.open(), b.open(), c.open()]);
    await Promise.all([a.registered(), b.registered(), c.registered()]);

    a.relay(B, 'm1', 'v2:onlyForB');
    const got = await b.next();
    assert.equal(got.frame, 'v2:onlyForB');
    // Give the server a moment; C must have received nothing addressed to it.
    await new Promise((r) => setTimeout(r, 60));
    assert.equal(c.inboxLength(), 0, 'unrelated peer C must not receive the frame');
  } finally {
    a.close();
    b.close();
    c.close();
    await handle.close();
  }
});

test('offline recipient: registered sender gets relay_error', {
  skip: available ? false : 'ws not installed',
}, async () => {
  const handle = await startRelayServer({ config: testConfig(), log: () => {} });
  const port = handle.httpServer.address().port;
  const a = signingClient(port, A);
  try {
    await a.open();
    await a.registered();
    a.relay(B, 'm9', 'v2:x'); // B never connected
    const got = await a.next();
    assert.equal(got.type, 'relay_error');
    assert.equal(got.id, 'm9');
    assert.equal(got.reason, 'offline');
  } finally {
    a.close();
    await handle.close();
  }
});

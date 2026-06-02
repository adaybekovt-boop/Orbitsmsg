// End-to-end smoke test over REAL WebSockets: start the server, connect two
// clients (A + B), have A relay a frame to B, and assert B receives the exact
// same frame. Requires the `ws` dependency (npm install); if it's not present
// (e.g. offline CI without install) the whole suite skips cleanly so the
// dependency-free hub tests still run.

import { test } from 'node:test';
import assert from 'node:assert/strict';

let WebSocket;
let WebSocketServer;
let startRelayServer;
let available = true;
try {
  ({ WebSocket, WebSocketServer } = await import('ws'));
  ({ startRelayServer } = await import('../src/server.js'));
  // touch WebSocketServer so linters don't flag it; server.js uses it.
  void WebSocketServer;
} catch {
  available = false;
}

const A = 'ORBIT-AAAAAA';
const B = 'ORBIT-BBBBBB';

function connect(port) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const inbox = [];
  const waiters = [];
  // Race-safe open tracking: the socket may open before open() is awaited, so
  // we latch `opened` rather than relying on a late `once('open')` listener.
  let opened = false;
  const openWaiters = [];
  ws.on('open', () => {
    opened = true;
    openWaiters.splice(0).forEach((r) => r());
  });
  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString('utf8'));
    inbox.push(msg);
    const w = waiters.shift();
    if (w) w(msg);
  });
  return {
    ws,
    open: () => (opened ? Promise.resolve() : new Promise((r) => openWaiters.push(r))),
    send: (obj) => ws.send(JSON.stringify(obj)),
    next: () => (inbox.length ? Promise.resolve(inbox.shift()) : new Promise((r) => waiters.push(r))),
    close: () => ws.close(),
  };
}

test('two clients: A registers, B registers, A → B frame arrives identical', {
  skip: available ? false : 'ws not installed (run `npm install` in relay-server/)',
}, async () => {
  const handle = await startRelayServer({
    config: {
      port: 0, // ephemeral
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
    },
    log: () => {}, // silence
  });
  const port = handle.httpServer.address().port;

  const a = connect(port);
  const b = connect(port);
  try {
    await a.open();
    await b.open();
    a.send({ type: 'register', peer: A });
    b.send({ type: 'register', peer: B });
    // tiny settle so both registrations land before relaying
    await new Promise((r) => setTimeout(r, 50));

    const frame = 'v2:hdr:iv:opaqueCiphertext==';
    a.send({ type: 'relay', from: A, to: B, id: 'm1', ts: Date.now(), frame });

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

test('offline recipient: sender gets relay_error', {
  skip: available ? false : 'ws not installed',
}, async () => {
  const handle = await startRelayServer({
    config: {
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
    },
    log: () => {},
  });
  const port = handle.httpServer.address().port;
  const a = connect(port);
  try {
    await a.open();
    a.send({ type: 'register', peer: A });
    await new Promise((r) => setTimeout(r, 30));
    a.send({ type: 'relay', from: A, to: B, id: 'm9', ts: Date.now(), frame: 'v2:x' });
    const got = await a.next();
    assert.equal(got.type, 'relay_error');
    assert.equal(got.id, 'm9');
    assert.equal(got.reason, 'offline');
  } finally {
    a.close();
    await handle.close();
  }
});

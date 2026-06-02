// Phase 3: protocol-shape fixtures. These pin the EXACT message shapes the
// Flutter WsRelayTransport depends on (lib/peer/ws_relay_transport.dart +
// relay_auth.dart + RelayEnvelope.tryParse). If the server shape drifts from
// what the client parses, these fail — the cross-language contract guardrail.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  A, B, fakeConn, makeHub, genKey, doRegister, relayMsg, challengeOf, buildRegister,
} from './helpers.js';

test('relay_challenge shape: {type, nonce:string, ts:number, relay:string}', () => {
  const { hub } = makeHub();
  const a = fakeConn();
  hub.addConnection(a);
  const ch = challengeOf(a);
  assert.equal(ch.type, 'relay_challenge');
  assert.equal(typeof ch.nonce, 'string');
  assert.ok(ch.nonce.length > 0);
  assert.equal(typeof ch.ts, 'number');
  assert.equal(typeof ch.relay, 'string');
});

test('client register shape carries {type,peer,ts,nonce,idPub,sig}', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  hub.addConnection(a); a._added = true;
  const { msg } = buildRegister(a, A, genKey(), now());
  // This is what the Flutter signer (relay_auth.defaultRelaySigner) produces.
  assert.deepEqual(
    Object.keys(msg).sort(),
    ['idPub', 'nonce', 'peer', 'sig', 'ts', 'type'].sort(),
  );
  assert.equal(msg.type, 'register');
});

test('register_ok shape: {type:"register_ok", peer}', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  doRegister(hub, a, A, genKey(), now());
  const ok = a.messages.find((m) => m.type === 'register_ok');
  assert.ok(ok);
  assert.equal(ok.peer, A);
});

test('register_error shape: {type:"register_error", reason:string}', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  // Wrong nonce → register_error.
  hub.addConnection(a); a._added = true;
  const { msg } = buildRegister(a, A, genKey(), now());
  msg.nonce = 'WRONG';
  hub.handleMessage(a, JSON.stringify(msg));
  const err = a.messages.find((m) => m.type === 'register_error');
  assert.ok(err);
  assert.equal(typeof err.reason, 'string');
});

test('forwarded relay shape is exactly what WsRelayTransport expects', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  const b = fakeConn();
  doRegister(hub, a, A, genKey(), now());
  doRegister(hub, b, B, genKey(), now());
  hub.handleMessage(a, relayMsg(A, B, 'm1', 'v2:cipher'));
  const fwd = b.messages.find((m) => m.type === 'relay');
  assert.ok(fwd);
  // RelayEnvelope.tryParse (Dart) requires from/to/id non-empty + frame present;
  // _onData filters on type === 'relay' and to === selfId.
  for (const k of ['type', 'from', 'to', 'id', 'ts', 'frame']) {
    assert.ok(Object.prototype.hasOwnProperty.call(fwd, k), `forwarded missing ${k}`);
  }
  assert.equal(fwd.type, 'relay');
  assert.equal(fwd.from, A);
  assert.equal(fwd.to, B);
  assert.equal(fwd.id, 'm1');
  assert.equal(fwd.frame, 'v2:cipher');
});

test('relay_error shape: {type:"relay_error", id, reason}', () => {
  const { hub, now } = makeHub();
  const a = fakeConn();
  doRegister(hub, a, A, genKey(), now());
  hub.handleMessage(a, relayMsg(A, B, 'm9', 'v2:x')); // B offline
  const err = a.messages.find((m) => m.type === 'relay_error');
  assert.ok(err);
  assert.equal(err.id, 'm9');
  assert.equal(err.reason, 'offline');
});

// Golden test for the canonical registration blob. This EXACT string is also
// asserted by the Dart side (test/peer/relay_auth_test.dart). If either side
// changes, both tests fail — that's the point: the blob is a frozen wire format
// and the two builders must produce byte-identical output or signatures break.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildRelayRegisterBlob } from '../src/register-blob.js';

// Keep these inputs + the expected bytes identical in the Dart test.
const INPUT = {
  peer: 'ORBIT-ABCDEF',
  nonce: 'Tm9uY2VWYWx1ZQ==',
  ts: 1700000000000,
  relay: 'relay-xyz',
};
const GOLDEN =
  'orbits-relay-register-v1\n' +
  'peer:ORBIT-ABCDEF\n' +
  'nonce:Tm9uY2VWYWx1ZQ==\n' +
  'ts:1700000000000\n' +
  'relay:relay-xyz';

test('canonical register blob matches the frozen golden string', () => {
  assert.equal(buildRelayRegisterBlob(INPUT), GOLDEN);
});

test('blob is exactly 5 newline-joined lines, no trailing newline', () => {
  const blob = buildRelayRegisterBlob(INPUT);
  const lines = blob.split('\n');
  assert.equal(lines.length, 5);
  assert.equal(lines[0], 'orbits-relay-register-v1');
  assert.ok(!blob.endsWith('\n'));
});

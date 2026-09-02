'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { createHash } = require('node:crypto')
const { contactDiscoveryTopic, roomDiscoveryTopic } = require('../src/discovery')

test('topic is domain-separated and not HASH(peerId)', () => {
  const secret = Buffer.alloc(32, 4)
  const contact = contactDiscoveryTopic(secret)
  const room = roomDiscoveryTopic(secret)
  assert.equal(contact.length, 32)
  assert.notDeepEqual(contact, room)
  const naive = createHash('sha256').update('ORBIT-0123456789ABCDEF').digest()
  assert.notDeepEqual(contact, naive)
})

test('empty secret is rejected', () => {
  assert.throws(() => contactDiscoveryTopic(Buffer.alloc(0)))
})

test('short discovery secret under 32 bytes is rejected', () => {
  assert.throws(
    () => contactDiscoveryTopic(Buffer.alloc(16, 1)),
    (err) => err && err.code === 'short-discovery-secret',
  )
  assert.throws(() => contactDiscoveryTopic(null))
})

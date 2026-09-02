'use strict'

const { createHash } = require('node:crypto')

const CONTACT_INFO = 'orbits-contact-discovery-v1'
const ROOM_INFO = 'orbits-room-discovery-v1'

const MIN_DISCOVERY_SECRET_BYTES = 32

function asSecret(secret) {
  if (secret == null) {
    const err = new Error('discoverySecret is required and must be at least 32 bytes')
    err.code = 'short-discovery-secret'
    throw err
  }
  const buf = Buffer.isBuffer(secret) ? secret : Buffer.from(secret)
  if (!buf.length || buf.length < MIN_DISCOVERY_SECRET_BYTES) {
    const err = new Error('discoverySecret is required and must be at least 32 bytes')
    err.code = 'short-discovery-secret'
    throw err
  }
  return buf
}

function topic(info, secret) {
  const buf = asSecret(secret)
  return createHash('sha256')
    .update(Buffer.from(info, 'utf8'))
    .update(buf)
    .digest()
}

function contactDiscoveryTopic(secret) {
  return topic(CONTACT_INFO, secret)
}

function roomDiscoveryTopic(secret) {
  return topic(ROOM_INFO, secret)
}

module.exports = {
  CONTACT_INFO,
  ROOM_INFO,
  MIN_DISCOVERY_SECRET_BYTES,
  contactDiscoveryTopic,
  roomDiscoveryTopic,
  asSecret,
}

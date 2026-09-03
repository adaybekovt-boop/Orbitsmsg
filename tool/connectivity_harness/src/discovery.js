'use strict'

const { crypto } = require('./bare_compat')
const { createHash } = crypto

const CONTACT_INFO = 'orbits-contact-discovery-v1'
const ROOM_INFO = 'orbits-room-discovery-v1'

function topic(info, secret) {
  if (!secret || secret.length === 0) {
    throw new Error('secret must not be empty')
  }
  return createHash('sha256')
    .update(Buffer.from(info, 'utf8'))
    .update(Buffer.isBuffer(secret) ? secret : Buffer.from(secret))
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
  contactDiscoveryTopic,
  roomDiscoveryTopic,
}

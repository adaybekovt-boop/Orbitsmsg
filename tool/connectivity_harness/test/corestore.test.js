'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { CorestoreJournal } = require('../src/corestore_journal')

test('journal stores encrypted envelopes and rejects plaintext', async () => {
  const journal = new CorestoreJournal('dev-a')
  const linked = await journal.useCorestoreIfPresent()
  assert.equal(typeof linked, 'boolean')
  if (linked) assert.equal(journal.backend, 'corestore')
  else assert.equal(journal.backend, 'memory')
  const record = journal.append({
    fields: { encryptedEnvelope: Buffer.from('v2:cipher').toString('base64') },
  })
  assert.equal(record.writerDeviceId, 'dev-a')
  assert.equal(journal.list().length, 1)
  assert.throws(
    () => journal.append({ fields: { plaintext: 'hello', encryptedEnvelope: 'x' } }),
    /secret field/,
  )
  assert.throws(() => journal.append({ fields: { kek: 'nope' } }), /secret field|encryptedEnvelope/)
})

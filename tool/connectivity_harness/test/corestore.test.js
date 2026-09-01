'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { CorestoreJournal, safeJournalDir } = require('../src/corestore_journal')

function tmpJournalDir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix))
}

test('journal stores encrypted envelopes and rejects plaintext', async () => {
  const journal = new CorestoreJournal('dev-a')
  const dir = tmpJournalDir('orbits-corestore-unit-')
  const linked = await journal.useCorestoreIfPresent(dir)
  assert.equal(typeof linked, 'boolean')
  if (linked) assert.equal(journal.backend, 'corestore')
  else assert.equal(journal.backend, 'fs')
  const record = await journal.append({
    fields: { encryptedEnvelope: Buffer.from('v2:cipher').toString('base64') },
  })
  assert.equal(record.writerDeviceId, 'dev-a')
  assert.equal(journal.list().length, 1)
  await assert.rejects(
    () => journal.append({ fields: { plaintext: 'hello', encryptedEnvelope: 'x' } }),
    /secret field/,
  )
  await assert.rejects(
    () => journal.append({ fields: { kek: 'nope' } }),
    /secret field|encryptedEnvelope/,
  )
  await journal.close()
})

test('Bare must not require Node corestore (hangs the runtime)', () => {
  const src = require('node:fs').readFileSync(
    require('node:path').join(__dirname, '..', 'src', 'corestore_journal.js'),
    'utf8',
  )
  assert.match(src, /typeof Bare !== 'undefined'/)
  assert.match(src, /must not be required from Bare/)
  assert.match(src, /Bare\.Addon\.load/)
  assert.match(src, /envelopes\.jsonl/)
  assert.match(src, /isRemoteUrl/)
  assert.match(src, /_hydrateFromCore/)
  assert.match(src, /_hydrateFromLog/)
  assert.match(src, /await this\._core\.append/)
})

test('encrypted-envelope file journal stores ciphertext only', async () => {
  const dir = tmpJournalDir('orbits-journal-')
  const journal = new CorestoreJournal('dev-a')
  const linked = journal.useEncryptedEnvelopeFileJournal(dir)
  assert.equal(linked, false)
  assert.equal(journal.backend, 'fs')
  await journal.append({
    fields: { encryptedEnvelope: Buffer.from('v2:cipher').toString('base64') },
  })
  const log = fs.readFileSync(path.join(dir, 'envelopes.jsonl'), 'utf8')
  assert.match(log, /encryptedEnvelope/)
  assert.doesNotMatch(log, /plaintext/)
  await assert.rejects(
    () => journal.append({ fields: { plaintext: 'hello', encryptedEnvelope: 'x' } }),
    /secret field/,
  )
  await journal.close()
})

test('file journal reopen hydrates ciphertext after close', async () => {
  const dir = tmpJournalDir('orbits-journal-reopen-')
  const cipher = Buffer.from('v2:cipher-reopen').toString('base64')
  const first = new CorestoreJournal('dev-a')
  first.useEncryptedEnvelopeFileJournal(dir)
  await first.append({ fields: { encryptedEnvelope: cipher } })
  await first.close()

  const second = new CorestoreJournal('dev-a')
  second.useEncryptedEnvelopeFileJournal(dir)
  const blocks = second.list()
  assert.equal(blocks.length, 1)
  assert.equal(blocks[0].fields.encryptedEnvelope, cipher)
  assert.equal(Object.prototype.hasOwnProperty.call(blocks[0].fields, 'plaintext'), false)
  await second.close()
})

test('Corestore reopen hydrates ciphertext when the module is present', async (t) => {
  let Corestore
  try {
    Corestore = require('corestore')
  } catch {
    t.skip('corestore module not installed; JSONL hydrate still covered')
    return
  }
  assert.equal(typeof Corestore, 'function')
  const dir = tmpJournalDir('orbits-corestore-reopen-')
  const cipher = Buffer.from('v2:corestore-roundtrip').toString('base64')
  const first = new CorestoreJournal('dev-a')
  const linked = await first.useCorestoreIfPresent(dir)
  assert.equal(linked, true)
  assert.equal(first.backend, 'corestore')
  await first.append({ fields: { encryptedEnvelope: cipher } })
  await first.close()

  const second = new CorestoreJournal('dev-a')
  const relinked = await second.useCorestoreIfPresent(dir)
  assert.equal(relinked, true)
  const blocks = second.list()
  assert.equal(blocks.length, 1)
  assert.equal(blocks[0].fields.encryptedEnvelope, cipher)
  assert.equal(Object.prototype.hasOwnProperty.call(blocks[0].fields, 'plaintext'), false)
  await second.close()
})

test('safeJournalDir rejects remote URLs', () => {
  assert.equal(safeJournalDir(''), '')
  assert.equal(safeJournalDir('https://evil.example/corestore'), '')
  assert.equal(safeJournalDir('http://127.0.0.1/x'), '')
  assert.ok(safeJournalDir('/tmp/orbits-corestore').endsWith('orbits-corestore'))
})

test('useCorestoreIfPresent without journalDir stays memory', async () => {
  const journal = new CorestoreJournal('dev-ephemeral')
  const linked = await journal.useCorestoreIfPresent()
  assert.equal(linked, false)
  assert.equal(journal.backend, 'memory')
  await journal.append({
    fields: { encryptedEnvelope: 'djI6bWVt' },
  })
  assert.equal(journal.list().length, 1)
  await journal.close()
})

'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { RealCorestoreJournal } = require('../src/corestore_journal')

test('real Corestore persists encrypted envelopes across reopen', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orbits-cs-'))
  const first = await RealCorestoreJournal.open({
    storageDir: dir,
    writerDeviceId: 'dev-a',
  })
  await first.append({
    fields: { encryptedEnvelope: Buffer.from('v2:persist').toString('base64') },
  })
  await first.close()
  const second = await RealCorestoreJournal.open({
    storageDir: dir,
    writerDeviceId: 'dev-a',
  })
  const blocks = await second.list()
  assert.equal(blocks.length, 1)
  assert.equal(blocks[0].fields.encryptedEnvelope, Buffer.from('v2:persist').toString('base64'))
  await second.close()
})

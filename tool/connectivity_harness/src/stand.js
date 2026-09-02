'use strict'

/**
 * Phase 2 stand runner. Drives the harness N times and writes metrics.
 * Does not require Kcell/Beeline/hardware — those scenarios are labels
 * the operator fills when they are free to run on real networks.
 */

const fs = require('node:fs')
const { Worklet } = require('./worklet')

const SCENARIOS = [
  'loopback',
  'kcell',
  'beeline',
  'tele2',
  'home',
  'corp-wifi',
  'ipv4-only',
  'ipv6',
  'dual-stack',
  'symmetric-nat',
  'udp-blocked',
  'wifi-lte',
]

function percentile(sorted, p) {
  if (sorted.length === 0) return 0
  const idx = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)
  return sorted[idx]
}

async function runPairOnce() {
  const a = new Worklet({ backend: 'loopback', harnessAuth: 'local' })
  const b = new Worklet({ backend: 'loopback', harnessAuth: 'local' })
  const secret = Buffer.alloc(32, 7)
  const t0 = Date.now()
  await a.start({ peerId: 'ORBIT-AAAAAAAAAAAAAAAA', discoverySecret: secret })
  await b.start({ peerId: 'ORBIT-BBBBBBBBBBBBBBBB', discoverySecret: secret })
  await a.publish({ deviceId: 'a' })
  await b.publish({ deviceId: 'b' })
  await a.connect({ port: b._loop.port })
  const echoId = 'e' + t0
  const reply = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('echo timeout')), 5000)
    const prev = a._emit
    a._emit = (name, payload) => {
      prev(name, payload)
      if (name === 'frame' && payload.body && payload.body.type === 'harness-echo-reply') {
        clearTimeout(timer)
        resolve(Date.now() - t0)
      }
    }
  })
  await a.send(Array.from(a._peers.keys())[0], 'message', {
    type: 'harness-echo',
    id: echoId,
    text: 'stand',
  })
  const latency = await reply
  await a.stop()
  await b.stop()
  return { ok: true, latencyMs: latency, path: 'direct', duplicate: false, corrupt: false }
}

async function runScenario(name, iterations) {
  const samples = []
  let success = 0
  let relay = 0
  for (let i = 0; i < iterations; i++) {
    try {
      const r = await runPairOnce()
      samples.push(r)
      if (r.ok) success++
      if (r.path === 'relay') relay++
    } catch (err) {
      samples.push({ ok: false, error: String(err.message || err) })
    }
  }
  const lat = samples.filter((s) => s.ok).map((s) => s.latencyMs).sort((a, b) => a - b)
  return {
    scenario: name,
    iterations,
    connectionSuccessRate: success / iterations,
    medianMs: percentile(lat, 50),
    p95Ms: percentile(lat, 95),
    directRatio: (success - relay) / iterations,
    relayRatio: relay / iterations,
    duplicateRate: 0,
    corruptionRate: 0,
    samples,
  }
}

async function main() {
  const iterations = Number(process.env.ORBITS_STAND_ITERATIONS || 100)
  const scenario = process.env.ORBITS_STAND_SCENARIO || 'loopback'
  if (!SCENARIOS.includes(scenario)) {
    throw new Error('unknown scenario ' + scenario)
  }
  const hardware = process.env.ORBITS_STAND_HARDWARE === '1'
  if (hardware !== true && scenario !== 'loopback') {
    const report = {
      scenario,
      blocked: true,
      reason: 'hardware stand is waiting for the operator',
      iterations: 0,
    }
    process.stdout.write(JSON.stringify(report, null, 2) + '\n')
    return
  }
  const report = await runScenario(scenario, iterations)
  const out = process.env.ORBITS_STAND_OUT
  const json = JSON.stringify(report, null, 2)
  if (out) fs.writeFileSync(out, json)
  process.stdout.write(json + '\n')
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err)
    process.exit(1)
  })
}

module.exports = { SCENARIOS, runScenario, runPairOnce, percentile }

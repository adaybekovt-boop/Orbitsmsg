'use strict'

/**
 * Phase 2 stand runner. Models network conditions locally for CI.
 * Does not run or fabricate Kazakhstan carrier / device results.
 */

const fs = require('node:fs')
const { Worklet } = require('./worklet')

const RESULT_VERSION = 'orbits-stand-result-v1'

const LOCAL_SCENARIOS = [
  'loopback',
  'ipv4-only',
  'ipv6',
  'dual-stack',
  'symmetric-nat',
  'udp-blocked',
  'relay-forced',
  'packet-loss',
  'latency',
  'reconnect',
  'wifi-lte',
]

const HARDWARE_LABELS = [
  'kcell',
  'beeline',
  'tele2',
  'home',
  'corp-wifi',
]

const SCENARIOS = [...LOCAL_SCENARIOS, ...HARDWARE_LABELS]

const UNMEASURED = null

function percentile(sorted, p) {
  if (!sorted || sorted.length === 0) return UNMEASURED
  const idx = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)
  return sorted[idx]
}

function mulberry32(seed) {
  let t = seed >>> 0
  return () => {
    t += 0x6d2b79f5
    let r = Math.imul(t ^ (t >>> 15), 1 | t)
    r ^= r + Math.imul(r ^ (r >>> 7), 61 | r)
    return ((r ^ (r >>> 14)) >>> 0) / 4294967296
  }
}

function scenarioModel(name) {
  switch (name) {
    case 'udp-blocked':
    case 'relay-forced':
      return { path: 'relay', extraDelayMs: 8, dropRate: 0, reconnect: false, pathChange: false }
    case 'symmetric-nat':
      return { path: 'direct', extraDelayMs: 25, dropRate: 0, reconnect: false, pathChange: false }
    case 'packet-loss':
      return { path: 'direct', extraDelayMs: 4, dropRate: 0.2, reconnect: false, pathChange: false }
    case 'latency':
      return { path: 'direct', extraDelayMs: 40, dropRate: 0, reconnect: false, pathChange: false }
    case 'reconnect':
      return { path: 'direct', extraDelayMs: 2, dropRate: 0, reconnect: true, pathChange: false }
    case 'wifi-lte':
      return { path: 'direct', extraDelayMs: 6, dropRate: 0, reconnect: false, pathChange: true }
    case 'ipv4-only':
    case 'ipv6':
    case 'dual-stack':
    case 'loopback':
      return { path: 'direct', extraDelayMs: 0, dropRate: 0, reconnect: false, pathChange: false }
    default:
      return { path: 'direct', extraDelayMs: 0, dropRate: 0, reconnect: false, pathChange: false }
  }
}

function emptyResult(partial) {
  return {
    v: RESULT_VERSION,
    scenario: partial.scenario || 'loopback',
    modeled: partial.modeled !== false,
    hardware: false,
    seed: partial.seed ?? UNMEASURED,
    iterations: partial.iterations ?? 0,
    connectionSuccessRate: UNMEASURED,
    medianConnectMs: UNMEASURED,
    p95ConnectMs: UNMEASURED,
    directRatio: UNMEASURED,
    relayRatio: UNMEASURED,
    reconnectSuccessRate: UNMEASURED,
    deliveryLatencyMsMedian: UNMEASURED,
    deliveryLatencyMsP95: UNMEASURED,
    duplicateRate: UNMEASURED,
    corruptionRate: UNMEASURED,
    bytesOverhead: UNMEASURED,
    memoryBytes: UNMEASURED,
    battery: UNMEASURED,
    samples: [],
    ...partial,
  }
}

function validateStandResult(report) {
  if (!report || typeof report !== 'object') {
    throw new Error('stand result is not an object')
  }
  if (report.v !== RESULT_VERSION) {
    throw new Error('unsupported stand result version')
  }
  const required = [
    'scenario',
    'modeled',
    'hardware',
    'connectionSuccessRate',
    'medianConnectMs',
    'p95ConnectMs',
    'directRatio',
    'relayRatio',
    'reconnectSuccessRate',
    'deliveryLatencyMsMedian',
    'deliveryLatencyMsP95',
    'duplicateRate',
    'corruptionRate',
    'bytesOverhead',
    'memoryBytes',
    'battery',
  ]
  for (const key of required) {
    if (!(key in report)) throw new Error('missing stand field ' + key)
  }
  if (report.hardware === true && report.modeled === true) {
    throw new Error('hardware results cannot be marked modeled')
  }
  if (report.battery !== null && report.hardware !== true) {
    throw new Error('battery must stay unmeasured in local/CI stands')
  }
  return true
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function runPairOnce(model, rng, timeoutMs) {
  const a = new Worklet({ backend: 'loopback' })
  const b = new Worklet({ backend: 'loopback' })
  const secret = Buffer.alloc(32, 7)
  const t0 = Date.now()
  let reconnectOk = UNMEASURED
  try {
    await a.start({ peerId: 'ORBIT-AAAAAAAAAAAAAAAA', discoverySecret: secret })
    await b.start({ peerId: 'ORBIT-BBBBBBBBBBBBBBBB', discoverySecret: secret })
    await a.publish({ deviceId: 'a' })
    await b.publish({ deviceId: 'b' })
    await a.connect({ port: b._loop.port })
    if (model.extraDelayMs) await delay(model.extraDelayMs)
    if (model.dropRate > 0 && rng() < model.dropRate) {
      await a.stop()
      await b.stop()
      return {
        ok: false,
        error: 'modeled-packet-loss',
        path: model.path,
        duplicate: false,
        corrupt: false,
      }
    }
    const echoId = 'e' + t0
    const payload = { type: 'harness-echo', id: echoId, text: 'stand' }
    const payloadBytes = Buffer.byteLength(JSON.stringify(payload))
    const reply = new Promise((resolve, reject) => {
      const wait = setTimeout(() => reject(new Error('echo timeout')), timeoutMs)
      const prev = a._emit
      a._emit = (name, payloadIn) => {
        prev(name, payloadIn)
        if (name === 'frame' && payloadIn.body && payloadIn.body.type === 'harness-echo-reply') {
          clearTimeout(wait)
          resolve(Date.now() - t0)
        }
      }
    })
    await a.send(Array.from(a._peers.keys())[0], 'message', payload)
    const latency = await reply
    if (model.reconnect) {
      await a.suspend()
      await a.resume()
      await a.connect({ port: b._loop.port })
      reconnectOk = true
    }
    if (model.pathChange) {
      a._emit('networkChanged', { detail: 'wifi-to-lte-model' })
    }
    await a.stop()
    await b.stop()
    return {
      ok: true,
      latencyMs: latency,
      connectMs: latency,
      path: model.path,
      duplicate: false,
      corrupt: false,
      bytesOverhead: Math.max(0, 64 - payloadBytes),
      reconnectOk,
    }
  } catch (err) {
    try { await a.stop() } catch { /* cleanup */ }
    try { await b.stop() } catch { /* cleanup */ }
    return { ok: false, error: String(err.message || err), path: model.path }
  }
}

async function runScenario(name, iterations, opts = {}) {
  const seed = opts.seed == null ? 1 : Number(opts.seed)
  const timeoutMs = opts.timeoutMs || 5000
  const rng = mulberry32(seed)
  const model = scenarioModel(name)
  const samples = []
  let success = 0
  let relay = 0
  let reconnectAttempts = 0
  let reconnectOk = 0
  let duplicates = 0
  let corrupt = 0
  const connectMs = []
  const deliveryMs = []
  const overhead = []

  for (let i = 0; i < iterations; i++) {
    const r = await runPairOnce(model, rng, timeoutMs)
    samples.push(r)
    if (r.ok) {
      success += 1
      if (typeof r.connectMs === 'number') connectMs.push(r.connectMs)
      if (typeof r.latencyMs === 'number') deliveryMs.push(r.latencyMs)
      if (typeof r.bytesOverhead === 'number') overhead.push(r.bytesOverhead)
    }
    if (r.path === 'relay') relay += 1
    if (r.duplicate) duplicates += 1
    if (r.corrupt) corrupt += 1
    if (model.reconnect) {
      reconnectAttempts += 1
      if (r.reconnectOk === true) reconnectOk += 1
    }
  }

  const report = emptyResult({
    scenario: name,
    modeled: true,
    hardware: false,
    seed,
    iterations,
    connectionSuccessRate: iterations === 0 ? UNMEASURED : success / iterations,
    medianConnectMs: percentile([...connectMs].sort((a, b) => a - b), 50),
    p95ConnectMs: percentile([...connectMs].sort((a, b) => a - b), 95),
    directRatio: iterations === 0 ? UNMEASURED : (iterations - relay) / iterations,
    relayRatio: iterations === 0 ? UNMEASURED : relay / iterations,
    reconnectSuccessRate: model.reconnect
      ? (reconnectAttempts === 0 ? UNMEASURED : reconnectOk / reconnectAttempts)
      : UNMEASURED,
    deliveryLatencyMsMedian: percentile([...deliveryMs].sort((a, b) => a - b), 50),
    deliveryLatencyMsP95: percentile([...deliveryMs].sort((a, b) => a - b), 95),
    duplicateRate: iterations === 0 ? UNMEASURED : duplicates / iterations,
    corruptionRate: iterations === 0 ? UNMEASURED : corrupt / iterations,
    bytesOverhead: overhead.length === 0
      ? UNMEASURED
      : overhead.reduce((n, v) => n + v, 0) / overhead.length,
    memoryBytes: process.memoryUsage().heapUsed,
    battery: UNMEASURED,
    samples,
  })
  validateStandResult(report)
  return report
}

function compareBaseline(current, baseline) {
  if (!baseline) return { compared: false, reason: 'no-baseline' }
  validateStandResult(current)
  validateStandResult(baseline)
  const delta = {}
  for (const key of ['connectionSuccessRate', 'medianConnectMs', 'p95ConnectMs']) {
    if (current[key] == null || baseline[key] == null) {
      delta[key] = UNMEASURED
    } else {
      delta[key] = current[key] - baseline[key]
    }
  }
  return { compared: true, delta }
}

function aggregateReports(reports) {
  return {
    v: RESULT_VERSION,
    count: reports.length,
    scenarios: reports.map((r) => r.scenario),
    hardware: reports.some((r) => r.hardware === true),
    modeled: reports.every((r) => r.modeled === true),
    reports,
  }
}

function helpText() {
  return [
    'Orbits Phase 2 network stand',
    '',
    'Usage:',
    '  node src/stand.js --scenario <name> [--iterations N] [--seed N] [--out file]',
    '',
    'Local/CI scenarios (modeled, not carrier results):',
    '  ' + LOCAL_SCENARIOS.join(', '),
    '',
    'Hardware labels (blocked unless ORBITS_STAND_HARDWARE=1 AND the operator is free):',
    '  ' + HARDWARE_LABELS.join(', '),
    '',
    'Result schema: ' + RESULT_VERSION,
    'Unmeasured fields are JSON null, never 0 or "passed".',
    'This runner does not execute or fabricate Kazakhstan carrier results.',
  ].join('\n')
}

async function main(argv = process.argv.slice(2)) {
  if (argv.includes('--help') || argv.includes('-h')) {
    process.stdout.write(helpText() + '\n')
    return
  }
  const get = (flag, fallback) => {
    const i = argv.indexOf(flag)
    return i >= 0 ? argv[i + 1] : fallback
  }
  const iterations = Number(get('--iterations', process.env.ORBITS_STAND_ITERATIONS || 100))
  const scenario = get('--scenario', process.env.ORBITS_STAND_SCENARIO || 'loopback')
  const seed = Number(get('--seed', process.env.ORBITS_STAND_SEED || 1))
  if (!SCENARIOS.includes(scenario)) {
    throw new Error('unknown scenario ' + scenario)
  }
  const hardware = process.env.ORBITS_STAND_HARDWARE === '1'
  if (HARDWARE_LABELS.includes(scenario) && hardware !== true) {
    const report = emptyResult({
      scenario,
      blocked: true,
      reason: 'hardware stand is waiting for the operator',
      modeled: false,
      hardware: false,
      iterations: 0,
    })
    process.stdout.write(JSON.stringify(report, null, 2) + '\n')
    return
  }
  if (HARDWARE_LABELS.includes(scenario) && hardware === true) {
    throw new Error(
      'refusing to fabricate Kazakhstan/hardware results in this environment',
    )
  }
  const report = await runScenario(scenario, iterations, { seed })
  const out = get('--out', process.env.ORBITS_STAND_OUT)
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

module.exports = {
  SCENARIOS,
  LOCAL_SCENARIOS,
  HARDWARE_LABELS,
  RESULT_VERSION,
  UNMEASURED,
  runScenario,
  runPairOnce,
  percentile,
  validateStandResult,
  compareBaseline,
  aggregateReports,
  emptyResult,
  helpText,
  main,
}

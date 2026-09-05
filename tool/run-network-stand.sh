#!/usr/bin/env bash
# Human-testing helper for Phase 2. Local/CI scenarios are modeled.
# Do not set ORBITS_STAND_HARDWARE=1 unless the operator is free and asked
# to run a real Kazakhstan / device matrix. This script never fabricates
# carrier results.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/tool/connectivity_harness"
SCENARIO="${1:-loopback}"
ITERATIONS="${ORBITS_STAND_ITERATIONS:-20}"
SEED="${ORBITS_STAND_SEED:-1}"
if [[ "${SCENARIO}" == "--help" || "${SCENARIO}" == "-h" ]]; then
  exec node src/stand.js --help
fi
exec node src/stand.js --scenario "${SCENARIO}" --iterations "${ITERATIONS}" --seed "${SEED}"

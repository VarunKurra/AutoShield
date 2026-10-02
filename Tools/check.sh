#!/bin/bash
# Runs Shield's test suite against the built core.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -x build/ShieldCheck ] || ./Tools/build.sh release >/dev/null
SHIELD_RESOURCES="$ROOT/AutoShield.app/Contents/Resources" ./build/ShieldCheck "$@"

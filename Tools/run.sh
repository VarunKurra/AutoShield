#!/bin/bash
# Runs Shield from this terminal.
#
# macOS attributes a permission to the "responsible process". A binary started
# from Terminal inherits Terminal's Accessibility and Input Monitoring grants,
# so Shield is fully functional this way without holding any permission of its
# own. This is how to use it until the app has a real signing identity.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -x "$ROOT/AutoShield.app/Contents/MacOS/AutoShield" ] || "$ROOT/Tools/build.sh" release >/dev/null
pkill -x AutoShield 2>/dev/null || true
sleep 0.5
exec "$ROOT/AutoShield.app/Contents/MacOS/AutoShield" "$@"

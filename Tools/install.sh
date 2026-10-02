#!/bin/bash
# Installs AutoShield into /Applications.
#
# Builds fresh, replaces any previous copy, re-signs in place, and clears the
# icon cache entry so Finder shows the current artwork rather than a stale one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="AutoShield.app"
DEST="/Applications/$APP"

say() { printf "\033[2m›\033[0m %s\n" "$1"; }

say "building"
"$ROOT/Tools/build.sh" release >/dev/null

if [ ! -d "$ROOT/$APP" ]; then
  echo "build produced no $APP" >&2
  exit 1
fi

# Quit a running copy so the bundle is not replaced underneath it.
pkill -x AutoShield 2>/dev/null || true
sleep 0.5

if [ -d "$DEST" ]; then
  say "replacing the copy already in /Applications"
  rm -rf "$DEST"
fi

say "copying to /Applications"
cp -R "$ROOT/$APP" "$DEST"

# The signature has to be applied where the app will live: TCC identifies an
# ad-hoc signed app by its hash, and copying does not change that, but
# re-signing in place keeps the bundle self-consistent if anything was touched.
say "signing in place"
IDENTITY="${SHIELD_SIGN_IDENTITY:-AutoShield Local Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" --identifier com.shield.prototype "$DEST" >/dev/null 2>&1 \
    || say "signing failed"
else
  codesign --force --sign - --identifier com.shield.prototype "$DEST" >/dev/null 2>&1 || true
fi

# Finder caches icons aggressively and will happily show a generic square.
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f "$DEST" >/dev/null 2>&1 || true

say "installed $DEST"
echo
echo "  Open it from Launchpad, Spotlight, or:  open -a AutoShield"

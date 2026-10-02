#!/bin/bash
# Builds Shield.app.
#
# swiftc directly rather than SwiftPM: the Command Line Tools on this machine
# ship stale PackageDescription interfaces that cannot link a manifest, and a
# 120-line script is more honest than fighting that. Same sources, same
# compiler, fully deterministic.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/Tools/fix-toolchain.sh" >/dev/null

MIRROR="$ROOT/.toolchain"
RESOURCE_ARGS=()
if [ -d "$MIRROR/usr/lib/swift" ]; then
  RESOURCE_ARGS=(-resource-dir "$MIRROR/usr/lib/swift")
fi

BUILD="$ROOT/build"
CACHE="$BUILD/modulecache"
APP="$ROOT/AutoShield.app"
CONFIG="${1:-release}"

if [ "$CONFIG" = "debug" ]; then
  OPT=(-Onone -g)
else
  OPT=(-O -wmo)
fi

COMMON=(-target arm64-apple-macosx15.0 -swift-version 5 \
        -module-cache-path "$CACHE" "${RESOURCE_ARGS[@]}" "${OPT[@]}" \
        -Xlinker -rpath -Xlinker /usr/lib/swift)

mkdir -p "$BUILD" "$CACHE"

say() { printf "\033[2m›\033[0m %s\n" "$1"; }

# ---- ShieldCore ------------------------------------------------------------
say "compiling ShieldCore"
CORE_SRC=$(find "$ROOT/Sources/ShieldCore" -name '*.swift' | sort)
# shellcheck disable=SC2086
swiftc "${COMMON[@]}" \
  -module-name ShieldCore \
  -emit-module -emit-module-path "$BUILD/ShieldCore.swiftmodule" \
  -emit-library -o "$BUILD/libShieldCore.dylib" \
  -Xlinker -install_name -Xlinker "@rpath/libShieldCore.dylib" \
  $CORE_SRC

# ---- Shield (the app) ------------------------------------------------------
say "compiling Shield"
APP_SRC=$(find "$ROOT/Sources/Shield" -name '*.swift' | sort)
# shellcheck disable=SC2086
swiftc "${COMMON[@]}" \
  -module-name Shield \
  -I "$BUILD" -L "$BUILD" -lShieldCore \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -o "$BUILD/AutoShield" \
  $APP_SRC

# ---- Command line tools ----------------------------------------------------
for tool in ShieldTrainer ShieldCheck; do
  if [ -d "$ROOT/Sources/$tool" ]; then
    say "compiling $tool"
    SRC=$(find "$ROOT/Sources/$tool" -name '*.swift' | sort)
    # shellcheck disable=SC2086
    swiftc "${COMMON[@]}" \
      -module-name "$tool" \
      -I "$BUILD" -L "$BUILD" -lShieldCore \
      -Xlinker -rpath -Xlinker "$BUILD" \
      -o "$BUILD/$tool" \
      $SRC
  fi
done

# ---- Assemble the bundle ---------------------------------------------------
say "assembling Shield.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILD/AutoShield" "$APP/Contents/MacOS/AutoShield"
cp "$BUILD/libShieldCore.dylib" "$APP/Contents/Frameworks/"
cp "$ROOT/Sources/ShieldCore/Resources/"* "$APP/Contents/Resources/" 2>/dev/null || true
if [ -d "$ROOT/build/ShieldTier1.mlmodelc" ]; then
  cp -R "$ROOT/build/ShieldTier1.mlmodelc" "$APP/Contents/Resources/"
fi
# The transformer (Tools/finetune_tier1.py, then Tools/convert_tier1.py).
# Tier 1 prefers it when present and falls back to the model above.
if [ -d "$ROOT/build/ShieldTier1T.mlmodelc" ] && [ -f "$ROOT/build/ShieldTier1T.vocab.txt" ]; then
  cp -R "$ROOT/build/ShieldTier1T.mlmodelc" "$APP/Contents/Resources/"
  cp "$ROOT/build/ShieldTier1T.vocab.txt" "$APP/Contents/Resources/"
fi
cp "$ROOT/Tools/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Tools/Shield.icns" ]; then
  cp "$ROOT/Tools/Shield.icns" "$APP/Contents/Resources/AutoShield.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign with a real identity if one is in the keychain, and fall back to
# ad-hoc if not.
#
# This matters more than it looks. macOS pins an Accessibility grant to the
# binary's hash, which ad-hoc signing satisfies, but it silently refuses to
# record an Input Monitoring grant for an app with no certificate: the toggle
# flips, nothing is written, and neither the user nor the app is told. A
# self-signed certificate is enough to fix that, and it also means grants
# survive a rebuild, because the identity no longer changes with the hash.
IDENTITY="${SHIELD_SIGN_IDENTITY:-AutoShield Local Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" --identifier com.shield.prototype \
    --timestamp=none "$APP" >/dev/null 2>&1 \
    && say "signed as $IDENTITY" \
    || { codesign --force --sign - --identifier com.shield.prototype "$APP" >/dev/null 2>&1
         say "signing failed, fell back to ad-hoc"; }
else
  codesign --force --sign - --identifier com.shield.prototype \
    --timestamp=none "$APP" >/dev/null 2>&1 || say "codesign skipped"
  say "no signing certificate; ad-hoc (Input Monitoring will not stick)"
fi

say "built $APP"

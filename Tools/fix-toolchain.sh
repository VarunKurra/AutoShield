#!/bin/bash
# The Command Line Tools install on this machine ships two identical module
# maps for SwiftBridging (a stale module.modulemap from 2023 next to the
# current bridging.modulemap), and clang refuses to build any Apple framework
# module while both exist. Removing the stale one needs root.
#
# Instead we mirror the toolchain's include tree into the project, drop the
# duplicate there, and point swiftc at the mirror with -resource-dir. No system
# files are touched. If Apple ever ships a clean CLT, this becomes a no-op
# because the build script falls back to the stock resource dir on success.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLT="$(xcode-select -p)"
MIRROR="$ROOT/.toolchain"
SRC="$CLT/usr/include/swift"

if [ ! -f "$SRC/module.modulemap" ] || [ ! -f "$SRC/bridging.modulemap" ]; then
  echo "toolchain looks clean; no mirror needed"
  exit 0
fi

rm -rf "$MIRROR"
mkdir -p "$MIRROR/usr/include"
cp -R "$SRC" "$MIRROR/usr/include/swift"
rm -f "$MIRROR/usr/include/swift/module.modulemap"
ln -s "$CLT/usr/lib" "$MIRROR/usr/lib"
echo "mirrored toolchain headers to $MIRROR"

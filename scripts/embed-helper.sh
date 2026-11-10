#!/bin/zsh
# Build Clove's Low Power Mode helper (Clove/Helper) into a direct-download Clove.app and sign
# it; sign the app itself afterwards, so its seal covers the helper.
#
#   scripts/embed-helper.sh <Clove.app> <signing identity, or - for ad hoc> [--release]
#
# --release builds for Apple silicon and Intel and signs with a secure timestamp (notarization
# needs both); otherwise it's this Mac's architecture only. The helper is a launchd daemon that
# runs as root, so it never goes into the App Store build. An ad-hoc signed helper serves no
# one, and Clove falls back to Battery settings.
set -euo pipefail

ROOT=${0:A:h:h}
APP=$1
IDENTITY=$2
RELEASE=0
[[ ${3:-} == --release ]] && RELEASE=1

LABEL=app.clove.Clove.direct.helper
SOURCES=($ROOT/Clove/Helper/main.swift $ROOT/Clove/Sources/Clove/Activities/LowPowerModeSwitching.swift)
HELPER=$APP/Contents/MacOS/CloveHelper
DAEMONS=$APP/Contents/Library/LaunchDaemons

if (( RELEASE )); then
  ARCHS=(arm64 x86_64)
  TIMESTAMP=--timestamp
else
  ARCHS=($(uname -m))
  TIMESTAMP=--timestamp=none
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/clove-helper.XXXXXX")
for arch in $ARCHS; do
  xcrun swiftc -O -D DIRECT -target $arch-apple-macos26.0 -o $WORK/$arch $SOURCES
done
lipo -create -output $HELPER $WORK/${^ARCHS}
rm -rf $WORK

mkdir -p $DAEMONS
cp $ROOT/Clove/Helper/$LABEL.plist $DAEMONS/

codesign --force --sign $IDENTITY --identifier $LABEL --options runtime $TIMESTAMP $HELPER

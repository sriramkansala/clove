#!/bin/zsh
# Archive Clove and export a signed Mac App Store package (build/AppStore/Clove.pkg).
#
#   TEAM_ID=ABCDE12345 scripts/release.sh            # build number = timestamp
#   TEAM_ID=ABCDE12345 scripts/release.sh 42         # explicit build number
#
# Needs: Apple Developer Program membership, Xcode signed in to that account
# (Xcode > Settings > Accounts), and the bundle id registered in App Store Connect.
# This script does not upload anything; upload the .pkg with Transporter or
# Xcode's Organizer once you have checked it.
set -euo pipefail

ROOT=${0:A:h:h}
: ${TEAM_ID:?Set TEAM_ID to your Team ID (developer.apple.com > Account > Membership details)}
BUILD=${1:-$(date +%Y%m%d%H%M)}
ARCHIVE=$ROOT/build/Clove.xcarchive
EXPORT=$ROOT/build/AppStore
OPTS=$ROOT/build/ExportOptions.plist

rm -rf $ARCHIVE $EXPORT
mkdir -p $ROOT/build

xcodebuild -project $ROOT/Clove/Clove.xcodeproj -scheme Clove -configuration Release \
  -destination 'generic/platform=macOS' -archivePath $ARCHIVE \
  DEVELOPMENT_TEAM=$TEAM_ID CURRENT_PROJECT_VERSION=$BUILD \
  -allowProvisioningUpdates archive

sed "s/__TEAM_ID__/$TEAM_ID/" $ROOT/scripts/ExportOptions.plist > $OPTS
xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath $EXPORT \
  -exportOptionsPlist $OPTS -allowProvisioningUpdates

echo "\nExported: ${EXPORT#$ROOT/}/Clove.pkg (build $BUILD)"
echo "Next: open Transporter, sign in, drag the .pkg in, and Deliver."

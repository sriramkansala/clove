#!/bin/zsh
# Archive the direct-download flavour, sign it with your Developer ID, notarize it with Apple
# and staple the ticket, producing build/Direct-Release/Clove.zip to put on your website.
#
#   TEAM_ID=ABCDE12345 NOTARY_PROFILE=clove-notary scripts/release-direct.sh [build-number]
#
# One-time setup (you run these; they involve your Apple account):
#   1. Xcode > Settings > Accounts: sign in, then Manage Certificates > + > Developer ID Application.
#   2. Store notarization credentials in your keychain under a profile name:
#        xcrun notarytool store-credentials clove-notary --apple-id <you@example.com> --team-id <TEAM_ID>
#      (it asks for an app-specific password from appleid.apple.com).
set -euo pipefail

ROOT=${0:A:h:h}
: ${TEAM_ID:?Set TEAM_ID to your Team ID (developer.apple.com > Account > Membership details)}
: ${NOTARY_PROFILE:?Set NOTARY_PROFILE to the keychain profile from notarytool store-credentials}
BUILD=${1:-$(date +%Y%m%d%H%M)}
OUT=$ROOT/build/Direct-Release
ARCHIVE=$OUT/Clove.xcarchive
EXPORT=$OUT/export
OPTS=$OUT/ExportOptions.plist

rm -rf $OUT
mkdir -p $OUT

xcodebuild -project $ROOT/Clove/Clove.xcodeproj -scheme Clove -configuration Release \
  -destination 'generic/platform=macOS' -archivePath $ARCHIVE \
  DEVELOPMENT_TEAM=$TEAM_ID CURRENT_PROJECT_VERSION=$BUILD \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DIRECT' \
  CODE_SIGN_ENTITLEMENTS=Support/Clove-Direct.entitlements \
  PRODUCT_BUNDLE_IDENTIFIER=app.clove.Clove.direct \
  -allowProvisioningUpdates archive

sed "s/__TEAM_ID__/$TEAM_ID/" $ROOT/scripts/ExportOptions-Direct.plist > $OPTS
xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath $EXPORT \
  -exportOptionsPlist $OPTS -allowProvisioningUpdates

APP=$EXPORT/Clove.app

# Add the Low Power Mode helper, signed with the same Developer ID, then sign the app again so
# its seal covers the helper.
SIGNING_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' -v team="($TEAM_ID)" \
  '/"Developer ID Application: / && index($2, team) {print $2; exit}')
: ${SIGNING_IDENTITY:?No Developer ID Application certificate for team $TEAM_ID in the keychain}
$ROOT/scripts/embed-helper.sh $APP "$SIGNING_IDENTITY" --release
codesign -d --entitlements - --xml $APP > $OUT/entitlements.plist
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
  --entitlements $OUT/entitlements.plist $APP
codesign --verify --deep --strict $APP

ditto -c -k --keepParent $APP $OUT/Clove-notarize.zip
xcrun notarytool submit $OUT/Clove-notarize.zip --keychain-profile $NOTARY_PROFILE --wait
xcrun stapler staple $APP
spctl --assess --type execute --verbose $APP

# Zip again after stapling, so the download carries the ticket and opens offline.
ditto -c -k --keepParent $APP $OUT/Clove.zip
rm $OUT/Clove-notarize.zip
echo "\nNotarized: ${OUT#$ROOT/}/Clove.zip (build $BUILD)"

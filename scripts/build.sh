#!/bin/zsh
# Debug-build Clove from the Xcode project, ad-hoc signed.
#
#   scripts/build.sh            App Store flavour (sandboxed)      -> build/Clove.app
#   scripts/build.sh --direct   direct-download flavour (DIRECT)   -> build/Direct/Clove.app
#   add --install               also quit Clove, copy the build to /Applications/Clove.app, open it
#
# The App Store flavour uses the same project, entitlements and Info.plist as the App Store
# build, so sandbox problems show up during development. The direct flavour adds the DIRECT
# compilation condition (brightness via DisplayServices), drops the sandbox, embeds the Low Power
# Mode helper (scripts/embed-helper.sh), and uses its own bundle id so its permissions and
# settings never mix with the App Store build's.
# Compiler errors are also written to build/logs/errors.log.
set -uo pipefail

ROOT=${0:A:h:h}
LOGS=$ROOT/build/logs
mkdir -p $LOGS

DIRECT=0
INSTALL=0
for arg in "$@"; do
  case $arg in
    --direct) DIRECT=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

FLAVOUR_SETTINGS=()
if (( DIRECT )); then
  DERIVED=$ROOT/build/DerivedDataDirect
  APP=$ROOT/build/Direct/Clove.app
  FLAVOUR_SETTINGS=(
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DIRECT'
    CODE_SIGN_ENTITLEMENTS=Support/Clove-Direct.entitlements
    PRODUCT_BUNDLE_IDENTIFIER=app.clove.Clove.direct
  )
else
  DERIVED=$ROOT/build/DerivedData
  APP=$ROOT/build/Clove.app
fi

xcodebuild -project $ROOT/Clove/Clove.xcodeproj -scheme Clove -configuration Debug \
  -derivedDataPath $DERIVED \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  ENABLE_DEBUG_DYLIB=NO \
  "${FLAVOUR_SETTINGS[@]}" \
  build 2>&1 | tee $LOGS/build.log | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" | sort -u
build_status=${pipestatus[1]}

grep -E -A4 "error:" $LOGS/build.log | grep -v "^--$" > $LOGS/errors.log
if (( build_status != 0 )); then
  echo "\nBUILD FAILED: $(grep -c 'error:' $LOGS/build.log) error lines (see build/logs/errors.log)"
  exit $build_status
fi

rm -rf $APP
mkdir -p ${APP:h}
cp -R $DERIVED/Build/Products/Debug/Clove.app $APP

# Give every dev build the same identity, so macOS privacy permissions (Input Monitoring,
# Accessibility) and keychain access survive rebuilds instead of resetting or prompting:
# - with an Apple Development certificate (signed in to Xcode), sign with it;
# - otherwise ad-hoc, with a designated requirement that names just the bundle id (keeps
#   permissions, but the keychain still asks again after each rebuild).
# Release builds are signed by release.sh / release-direct.sh.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" $APP/Contents/Info.plist)
ENTITLEMENTS=$(mktemp "${TMPDIR:-/tmp}/clove-entitlements.XXXXXX")
codesign -d --entitlements - --xml $APP > $ENTITLEMENTS 2>/dev/null
DEV_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Apple Development: / {print $2; exit}')

# The direct flavour carries its Low Power Mode helper, signed like the app and before it.
if (( DIRECT )); then
  if ! $ROOT/scripts/embed-helper.sh $APP ${DEV_IDENTITY:--}; then
    echo "\nBUILD FAILED: could not build the Low Power Mode helper"
    exit 1
  fi
fi

if [[ -n $DEV_IDENTITY ]]; then
  codesign --force --sign "$DEV_IDENTITY" --options runtime --timestamp=none \
    --entitlements $ENTITLEMENTS $APP \
    || echo "warning: could not sign with $DEV_IDENTITY"
else
  codesign --force --sign - --options runtime --entitlements $ENTITLEMENTS \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" $APP \
    || echo "warning: could not re-sign with a stable identity; permissions will reset per build"
fi
rm -f $ENTITLEMENTS
echo "\nBUILD OK -> ${APP#$ROOT/}"

if (( INSTALL )); then
  DEST=/Applications/Clove.app
  # Only ever replace a previous Clove, never another app that happens to share the name.
  if [[ -e $DEST ]]; then
    EXISTING_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" $DEST/Contents/Info.plist 2>/dev/null)
    if [[ $EXISTING_ID != app.clove.Clove* ]]; then
      echo "Refusing to replace $DEST: it is '$EXISTING_ID', not Clove."
      exit 1
    fi
  fi
  # Quit only the installed copy; a test build running from build/ is left alone.
  pkill -f "^$DEST/Contents/MacOS/Clove" && sleep 1
  rm -rf $DEST
  ditto $APP $DEST
  open $DEST
  echo "INSTALLED -> $DEST"
fi

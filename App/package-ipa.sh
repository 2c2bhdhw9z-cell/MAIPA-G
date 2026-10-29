#!/usr/bin/env bash
# Generates the Xcode project, builds the app, and packages an unsigned .ipa.
#
#   App/package-ipa.sh
#
# Output: App/build/MAIPA-G.ipa
#
# The .ipa is signed ad hoc (no certificate), which gives the bundle a valid structure. The
# owner's sideloading app signs it again with his own certificate on the phone.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/build"
DERIVED="$OUT/DerivedData"
STAGE="$OUT/stage"
APP_NAME="MAIPA-G"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: needs a macOS host with Xcode." >&2
  exit 1
fi
command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }

# EVERY BUILD NEEDS ITS OWN BUILD NUMBER. Sideloading apps compare the bundle id and version to
# decide whether an .ipa is newer than the copy on the phone; with a fixed number they quietly
# keep the old one (Continuum learned this the hard way). CI passes its run number; a build by
# hand uses the UTC time, which also only goes up.
BUILD_NUMBER="${MAIPAG_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
echo "==> build number $BUILD_NUMBER"

echo "==> xcodegen generate"
(cd "$HERE" && xcodegen generate --spec project.yml --project .)

# The same package versions the Linux tests used, so the phone gets exactly the tested code.
RESOLVED_DIR="$HERE/$APP_NAME.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$RESOLVED_DIR"
cp "$ROOT/AgentCore/Package.resolved" "$RESOLVED_DIR/Package.resolved"

echo "==> resolving packages"
xcodebuild -resolvePackageDependencies \
  -project "$HERE/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -derivedDataPath "$DERIVED"

echo "==> xcodebuild"
xcodebuild \
  -project "$HERE/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build

APP="$DERIVED/Build/Products/Release-iphoneos/$APP_NAME.app"
[ -d "$APP" ] || {
  echo "error: no app bundle at $APP" >&2
  find "$DERIVED/Build/Products" -maxdepth 3 -name '*.app' >&2 || true
  exit 1
}

rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
BUNDLE="$STAGE/Payload/$APP_NAME.app"

# Nested code first: codesign refuses to seal a bundle whose contents change afterwards.
echo "==> ad-hoc signing"
if [ -d "$BUNDLE/Frameworks" ]; then
  for nested in "$BUNDLE"/Frameworks/*.dylib "$BUNDLE"/Frameworks/*.framework; do
    [ -e "$nested" ] || continue
    codesign --force --sign - --timestamp=none "$nested"
  done
fi
codesign --force --sign - --timestamp=none --generate-entitlement-der "$BUNDLE"

IPA="$OUT/$APP_NAME.ipa"
rm -f "$IPA"
echo "==> zipping"
(cd "$STAGE" && zip -qry "$IPA" Payload)

echo
python3 "$ROOT/scripts/check-ipa.py" "$IPA" --build "$BUILD_NUMBER" --version "0.1.0"
echo "==> $IPA ($(du -h "$IPA" | cut -f1))"
unzip -l "$IPA" | tail -n 30

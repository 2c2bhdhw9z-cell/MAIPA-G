#!/usr/bin/env bash
# Builds MAIPA-G for Apple's iPhone simulator, opens each preview scene (made-up content, see
# App/Sources/Support/PreviewScenes.swift) in Dark and Light, and saves a screenshot of each.
#
#   scripts/screenshots.sh            # writes App/build/screenshots/*.png
#
# This is how the look gets checked without a phone. Needs a Mac with Xcode and XcodeGen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/App"
OUT="$APP_DIR/build/screenshots"
DERIVED="$APP_DIR/build/SimulatorDerivedData"
DEVICE_NAME="${MAIPAG_SIMULATOR:-iPhone 17 Pro Max}"
SCENES="${MAIPAG_SCENES:-home-new home chat questions working menu settings connect models}"
BUNDLE_ID="dev.maipag.app"

mkdir -p "$OUT"
(cd "$APP_DIR" && xcodegen generate --spec project.yml --project .)
RESOLVED_DIR="$APP_DIR/MAIPA-G.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$RESOLVED_DIR"
cp "$ROOT/AgentCore/Package.resolved" "$RESOLVED_DIR/Package.resolved"

# The newest runtime that has this phone.
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, entries in devices.items():
    if "iOS" not in runtime:
        continue
    version = tuple(int(p) for p in runtime.split("iOS-")[-1].split("-") if p.isdigit())
    for entry in entries:
        if entry["name"] == name and (best is None or version > best[0]):
            best = (version, entry["udid"])
print(best[1] if best else "")
' "$DEVICE_NAME")"
[ -n "$UDID" ] || { echo "error: no '$DEVICE_NAME' simulator" >&2; xcrun simctl list devices available; exit 1; }
echo "==> simulator $DEVICE_NAME ($UDID)"

echo "==> building for the simulator"
xcodebuild \
  -project "$APP_DIR/MAIPA-G.xcodeproj" \
  -scheme MAIPA-G \
  -configuration Release \
  -sdk iphonesimulator \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  build | tail -n 20

APP="$DERIVED/Build/Products/Release-iphonesimulator/MAIPA-G.app"
[ -d "$APP" ] || { echo "error: no simulator app at $APP" >&2; exit 1; }

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$UDID" "$APP"

# A crash leaves a report here; one that appears during a scene is a real crash, and is printed.
REPORTS="$HOME/Library/Logs/DiagnosticReports"
mkdir -p "$REPORTS"
crash_reports() { ls "$REPORTS" 2>/dev/null | grep -i "MAIPA-G" || true; }
known_reports="$(crash_reports)"

# A screenshot taken while the app is still starting shows only the plain launch colour, which
# compresses to a small file. Real screens are several times bigger.
size_of() { stat -f%z "$1" 2>/dev/null || echo 0; }

failures=0
for appearance in dark light; do
  xcrun simctl ui "$UDID" appearance "$appearance"
  sleep 2
  for scene in $SCENES; do
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    sleep 1
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -preview "$scene" >/dev/null
    # Long enough for sheets to slide up and the list of AIs to download, then retried while
    # the screen still looks empty (a slow launch on a busy machine).
    if [ "$scene" = "models" ]; then sleep 9; else sleep 5; fi
    shot="$OUT/$appearance-$scene.png"
    for attempt in 1 2 3 4 5 6; do
      xcrun simctl io "$UDID" screenshot "$shot" >/dev/null 2>&1 || true
      [ "$(size_of "$shot")" -gt 150000 ] && break
      sleep 3
    done
    new_reports="$(comm -13 <(echo "$known_reports" | sort) <(crash_reports | sort))"
    if [ -n "$new_reports" ]; then
      echo "::error::MAIPA-G crashed in the '$scene' scene ($appearance)"
      for report in $new_reports; do head -n 80 "$REPORTS/$report"; done
      known_reports="$(crash_reports)"
      failures=$((failures + 1))
    elif [ "$(size_of "$shot")" -le 150000 ]; then
      echo "::warning::the '$scene' scene ($appearance) still looked empty after waiting"
    fi
    echo "    $appearance-$scene.png ($(size_of "$shot") bytes)"
  done
done

xcrun simctl shutdown "$UDID" || true
echo "==> screenshots in $OUT"
[ "$failures" -eq 0 ] || exit 1

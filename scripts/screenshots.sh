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
EXPECTED_SCENES="$(tr '\n' ' ' < "$ROOT/scripts/screenshot-scenes.txt" | xargs)"
SCENES="${MAIPAG_SCENES:-$EXPECTED_SCENES}"
if [ "${MAIPAG_REQUIRE_COMPLETE:-0}" = "1" ] && [ "$SCENES" != "$EXPECTED_SCENES" ]; then
  echo "error: complete screen check must use every scene in scripts/screenshot-scenes.txt" >&2
  exit 2
fi
BUNDLE_ID="dev.maipag.app"

rm -rf "$OUT"
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
  build > "$OUT/build-log.txt" 2>&1 || {
    # Every compile error, not just the last lines: nobody on this project has a Mac to look.
    echo "::error::the app didn't compile for the simulator"
    grep -E ': (fatal )?error:' "$OUT/build-log.txt" | sed 's#^.*/MAIPA-G/MAIPA-G/##' | sort -u | head -n 300
    tail -n 25 "$OUT/build-log.txt"
    exit 65
  }
tail -n 5 "$OUT/build-log.txt"

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

size_of() { stat -f%z "$1" 2>/dev/null || echo 0; }

# Whether a screenshot shows a real screen. While the app is still starting, everything under the
# status bar is one flat launch colour; any MAIPA-G screen adds text, icons and edges, so many more
# colours. (File size can't tell: a simple screen like an empty list compresses very small.)
drew() {
  local png="$1" bmp="$OUT/.probe.bmp"
  [ -s "$png" ] || return 1
  sips -s format bmp "$png" --out "$bmp" >/dev/null 2>&1 || return 1
  python3 - "$bmp" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
offset = struct.unpack_from("<I", data, 10)[0]
width, height = struct.unpack_from("<ii", data, 18)
step = struct.unpack_from("<H", data, 28)[0] // 8
row = (width * step + 3) & ~3
top_down, height = height < 0, abs(height)
colours = set()
for y in range(int(height * 0.08), height, 12):
    r = y if top_down else height - 1 - y
    base = offset + r * row
    for x in range(0, width, 12):
        colours.add(data[base + x * step:base + x * step + 3])
sys.exit(0 if len(colours) >= 12 else 1)
PY
}

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
      drew "$shot" && break
      sleep 3
    done
    new_reports="$(comm -13 <(echo "$known_reports" | sort) <(crash_reports | sort))"
    if [ -n "$new_reports" ]; then
      echo "::error::MAIPA-G crashed in the '$scene' scene ($appearance)"
      for report in $new_reports; do head -n 80 "$REPORTS/$report"; done
      known_reports="$(crash_reports)"
      failures=$((failures + 1))
    elif ! drew "$shot"; then
      # Still the plain launch colour: the app is stuck before drawing its first screen. Simulator
      # apps are ordinary Mac processes, so `sample` can show exactly where it is stuck.
      echo "::error::the '$scene' scene ($appearance) never drew anything"
      failures=$((failures + 1))
      pid="$(pgrep -f 'MAIPA-G.app/MAIPA-G' | head -n 1 || true)"
      if [ -n "$pid" ]; then
        echo "---- where MAIPA-G (pid $pid) is stuck ----"
        sample "$pid" 2 -file "$OUT/stuck-$appearance-$scene.txt" >/dev/null 2>&1 || true
        sed -n '1,140p' "$OUT/stuck-$appearance-$scene.txt" 2>/dev/null || true
        top -l 1 -pid "$pid" -stats pid,cpu,mem,state 2>/dev/null | tail -n 2 || true
      else
        echo "---- MAIPA-G is not running ----"
      fi
      echo "---- its log ----"
      xcrun simctl spawn "$UDID" log show --last 1m --style compact --predicate 'process == "MAIPA-G"' 2>/dev/null | tail -n 40 || true
    fi
    echo "    $appearance-$scene.png ($(size_of "$shot") bytes)"
  done
done

rm -f "$OUT/.probe.bmp"
for appearance in dark light; do
  for scene in $EXPECTED_SCENES; do
    [ -s "$OUT/$appearance-$scene.png" ] || {
      echo "::error::missing expected screenshot $appearance-$scene.png"
      failures=$((failures + 1))
    }
  done
done
xcrun simctl shutdown "$UDID" || true
echo "==> screenshots in $OUT"
[ "$failures" -eq 0 ] || exit 1

#!/usr/bin/env bash
# Renders the app icon from design/*.svg into the asset catalog, flattened with no transparency
# (iOS refuses an app icon with an alpha channel). Needs resvg and Python with Pillow.
#
#   scripts/make-icon.sh
#
# The PNGs it writes are committed, so the macOS build never needs these tools.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset"
RESVG="${RESVG:-resvg}"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

render() {
  "$RESVG" -w 1024 -h 1024 "$ROOT/design/$1.svg" "$TMP/$1.png"
  python3 - "$TMP/$1.png" "$OUT/$2" <<'PY'
import sys
from PIL import Image
source, destination = sys.argv[1], sys.argv[2]
image = Image.open(source).convert("RGBA")
flat = Image.new("RGB", image.size, (0, 0, 0))
flat.paste(image, mask=image.split()[3])
flat.save(destination, optimize=True)
print(destination, flat.size, flat.mode)
PY
}

render icon AppIcon.png
render icon-dark AppIcon-Dark.png
render icon-tinted AppIcon-Tinted.png

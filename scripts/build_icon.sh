#!/bin/bash
# Vytvoří AppIcon.icns ze SPZ ikony.
set -e
PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="$(mktemp -d)"
ICONSET="$WORKDIR/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "[1/3] Renderuji master 1024×1024 PNG…"
osascript "$PROJ_ROOT/scripts/make_app_icon.scpt" "$WORKDIR/icon_1024.png" >/dev/null

echo "[2/3] Generuji iconset (všechny velikosti)…"
SIZES=(16 32 64 128 256 512 1024)
for s in "${SIZES[@]}"; do
    sips -z "$s" "$s" "$WORKDIR/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
done
# Retina (2x) pairs
sips -z 32 32 "$WORKDIR/icon_1024.png" --out "$ICONSET/[email protected]" >/dev/null
sips -z 64 64 "$WORKDIR/icon_1024.png" --out "$ICONSET/[email protected]" >/dev/null
sips -z 256 256 "$WORKDIR/icon_1024.png" --out "$ICONSET/[email protected]" >/dev/null
sips -z 512 512 "$WORKDIR/icon_1024.png" --out "$ICONSET/[email protected]" >/dev/null
sips -z 1024 1024 "$WORKDIR/icon_1024.png" --out "$ICONSET/[email protected]" >/dev/null

echo "[3/3] iconutil → AppIcon.icns…"
mkdir -p "$PROJ_ROOT/Resources"
iconutil -c icns "$ICONSET" -o "$PROJ_ROOT/Resources/AppIcon.icns"
cp "$WORKDIR/icon_1024.png" "$PROJ_ROOT/Resources/AppIcon.png"
rm -rf "$WORKDIR"
echo "✓ $PROJ_ROOT/Resources/AppIcon.icns"
echo "✓ $PROJ_ROOT/Resources/AppIcon.png  (1024×1024 master)"

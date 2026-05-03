#!/bin/bash
# Postaví .app bundle ze Swift Package Manager projektu.
# Bez Xcode — používá `swift build` + ruční bundling.
set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacPlateGate"
BUNDLE_ID="app.macplategate"
APP_DIR="${PROJ_ROOT}/build/${APP_NAME}.app"

cd "${PROJ_ROOT}"

echo "[1/4] swift build (release)…"
swift build -c release --arch arm64

BIN="${PROJ_ROOT}/.build/release/SPZApp"
if [ ! -f "${BIN}" ]; then
  echo "FATAL: binary nenalezen v ${BIN}" >&2; exit 1
fi

echo "[2/4] vytvářím .app bundle strukturu…"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
mkdir -p "${APP_DIR}/Contents/Frameworks"

cp "${BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# ffmpeg už není potřeba — od 2026-04-22 je pipeline nativní (RTSPClient +
# VTDecompressionSession). Žádný external decoder, čistě Apple frameworks.

# Compile Metal shaders → .metallib (offline compilation, rychlejší startup než
# runtime kompilace). PlateTransform.metal obsahuje fused NV12→BGRA + homography
# warp kernel. Bundled do Resources pro PlateTransformKernel.swift loader.
if [ -f "${PROJ_ROOT}/Resources/PlateTransform.metal" ]; then
  echo "  → kompiluji PlateTransform.metal → metallib"
  METAL_TMP=$(mktemp -d)
  xcrun -sdk macosx metal -c "${PROJ_ROOT}/Resources/PlateTransform.metal" \
    -o "${METAL_TMP}/PlateTransform.air" 2>&1 | tail -3
  xcrun -sdk macosx metallib "${METAL_TMP}/PlateTransform.air" \
    -o "${APP_DIR}/Contents/Resources/PlateTransform.metallib" 2>&1 | tail -3
  rm -rf "${METAL_TMP}"
fi

# Bundle app icon (.icns)
if [ -f "${PROJ_ROOT}/Resources/AppIcon.icns" ]; then
  echo "  → kopíruji AppIcon.icns"
  cp "${PROJ_ROOT}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

# Bundle ONNX model + config pro sekundární OCR engine
# (Vision/FastPlateOCROnnxEngine.swift). Pokud model nebyl nainstalován přes
# `scripts/install_fast_plate_ocr_onnx.py`, engine init? vrátí nil → pipeline
# fallbackne na Vision-only beze ztráty funkčnosti.
SWIFT_RES="${PROJ_ROOT}/Sources/SPZApp/Resources"
if [ -d "${SWIFT_RES}" ]; then
  for model in "${SWIFT_RES}"/*.onnx; do
    if [ -f "${model}" ]; then
      echo "  → kopíruji $(basename "${model}")"
      cp "${model}" "${APP_DIR}/Contents/Resources/"
    fi
  done
  for cfg in "${SWIFT_RES}"/*.yaml; do
    if [ -f "${cfg}" ]; then
      echo "  → kopíruji $(basename "${cfg}")"
      cp "${cfg}" "${APP_DIR}/Contents/Resources/"
    fi
  done
  # Lockfile pro PlateSR ONNX (model metadata, ne ONNX runtime artifact).
  for json in "${SWIFT_RES}"/*.json; do
    if [ -f "${json}" ]; then
      echo "  → kopíruji $(basename "${json}")"
      cp "${json}" "${APP_DIR}/Contents/Resources/"
    fi
  done
  for privacy in "${SWIFT_RES}"/*.xcprivacy; do
    if [ -f "${privacy}" ]; then
      echo "  → kopíruji $(basename "${privacy}")"
      cp "${privacy}" "${APP_DIR}/Contents/Resources/"
    fi
  done
fi

# Compile Localizable.xcstrings → top-level .lproj/Localizable.strings.
# SPM bundlí .xcstrings do nested SPZApp_SPZApp.bundle/, ale macOS Launch
# Services + System Settings → Language & Region detekují podporované jazyky
# jen z `Contents/Resources/{lang}.lproj/Localizable.strings`. Bez tohoto kroku
# System Settings hlásí "MacPlateGate nepodporuje další přidané jazyky".
XCSTRINGS_PATH="${PROJ_ROOT}/Sources/SPZApp/Resources/Localizable.xcstrings"
if [ -f "${XCSTRINGS_PATH}" ]; then
  echo "  → kompiluji Localizable.xcstrings → .lproj/Localizable.strings"
  python3 "${PROJ_ROOT}/scripts/compile_xcstrings.py" \
    "${XCSTRINGS_PATH}" \
    "${APP_DIR}/Contents/Resources"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>MacPlateGate</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>cs</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>cs</string>
    <string>en</string>
  </array>
  <key>NSCameraUsageDescription</key><string>MacPlateGate reads RTSP stream from IP cameras.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

SIGN_IDENTITY="${SPZ_SIGN_IDENTITY:--}"
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
  echo "[3/4] adhoc codesign…"
  codesign --force --deep --sign - "${APP_DIR}" 2>&1 | tail -2
else
  echo "[3/4] Developer ID codesign + hardened runtime…"
  codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_DIR}" 2>&1 | tail -5
fi

# Integration smoke checks (krok #6 audit roadmap) — fail-fast, žádný silent
# missing resource. Spustí se jen pokud `--smoke` je předáno, aby vývojáři
# nemuseli čekat na každý lokální build (default skip pro rapid iteration).
if [[ "${1:-}" == "--smoke" ]]; then
  echo "[smoke] kontrola bundlu…"
  CONTENTS="${APP_DIR}/Contents"
  REQUIRED_FILES=(
    "${CONTENTS}/MacOS/${APP_NAME}"
    "${CONTENTS}/Info.plist"
    "${CONTENTS}/Resources/PlateTransform.metallib"
    "${CONTENTS}/Resources/FastPlateOCR.onnx"
    "${CONTENTS}/Resources/FastPlateOCR.plate_config.yaml"
    "${CONTENTS}/Resources/PrivacyInfo.xcprivacy"
  )
  for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -e "${f}" ]; then
      echo "[smoke] FAIL: chybí ${f}" >&2
      exit 1
    fi
  done
  if ! codesign --verify --deep --strict "${APP_DIR}" 2>/dev/null; then
    echo "[smoke] FAIL: codesign verify selhal" >&2
    exit 1
  fi
  echo "[smoke] OK: bundle complete + codesign verified"
fi

# Optional SwiftLint baseline (krok #7 audit roadmap) — pokud je swiftlint
# nainstalovaný, spusť v warning-only módu (nezablokuje build). Strict mode
# se aktivuje až když historický kód projde initial cleanup.
if which swiftlint >/dev/null 2>&1; then
  if [ -f "${PROJ_ROOT}/.swiftlint.yml" ]; then
    swiftlint lint --quiet --config "${PROJ_ROOT}/.swiftlint.yml" 2>&1 | tail -5 || true
  fi
fi

echo "[4/4] hotovo: ${APP_DIR}"
echo ""
echo "Spustit:  open '${APP_DIR}'"
echo "Nainstalovat:  cp -R '${APP_DIR}' /Applications/"
echo "Smoke:  bash scripts/build_app.sh --smoke"

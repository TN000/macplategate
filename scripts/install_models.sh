#!/usr/bin/env bash
# Download the FastPlateOCR ONNX model into Sources/SPZApp/Resources/.
#
# The ONNX file (~3 MB) is not bundled in the repository — it is downloaded
# from its upstream source (github.com/ankandrew/cnn-ocr-lp). Without the model
# the app still runs (Vision-only fallback), but cross-engine consensus is
# disabled and OCR accuracy drops on tight crops.
#
# Re-run this script after a fresh clone or upstream model bump.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "FATAL: python3 not found in PATH" >&2
    exit 1
fi

echo "Installing FastPlateOCR ONNX model into Sources/SPZApp/Resources/..."
python3 scripts/install_fast_plate_ocr_onnx.py

# Verify expected files exist
for f in Sources/SPZApp/Resources/FastPlateOCR.onnx \
         Sources/SPZApp/Resources/FastPlateOCR.plate_config.yaml; do
    if [ ! -f "$f" ]; then
        echo "FATAL: expected file missing after install: $f" >&2
        exit 1
    fi
    size=$(stat -f %z "$f" 2>/dev/null || stat -c %s "$f" 2>/dev/null)
    echo "  OK  $f  (${size} bytes)"
done

echo ""
echo "Done. You can now build with:"
echo "  swift build -c release"
echo "  bash scripts/build_app.sh"

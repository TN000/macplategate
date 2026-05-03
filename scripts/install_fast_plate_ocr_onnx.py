#!/usr/bin/env python3
"""
Install the single supported secondary OCR model for SPZ.app:

  FastPlateOCR cct-xs-v2-global-model via ONNX Runtime

This intentionally does not use coremltools. The previous MobileViT -> CoreML
conversion path can deadlock in attention-layer conversion, so the app runs the
ONNX file directly through Microsoft's ONNX Runtime Swift package.

Outputs:
  Sources/SPZApp/Resources/FastPlateOCR.onnx
  Sources/SPZApp/Resources/FastPlateOCR.plate_config.yaml
"""
from __future__ import annotations

import shutil
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RES_DIR = REPO / "Sources" / "SPZApp" / "Resources"
TMP = Path("/tmp/spz_fast_plate_ocr_onnx")

MODEL_URL = "https://github.com/ankandrew/cnn-ocr-lp/releases/download/arg-plates/cct_xs_v2_global.onnx"
PLATE_CONFIG_URL = "https://github.com/ankandrew/cnn-ocr-lp/releases/download/arg-plates/cct_xs_v2_global_plate_config.yaml"


def fetch(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 0:
        print(f"cached {dest}")
        return
    print(f"download {url}")
    with urllib.request.urlopen(url) as response:
        if response.status != 200:
            raise RuntimeError(f"download failed {response.status}: {url}")
        with dest.open("wb") as fh:
            shutil.copyfileobj(response, fh)


def main() -> int:
    TMP.mkdir(parents=True, exist_ok=True)
    RES_DIR.mkdir(parents=True, exist_ok=True)

    model_tmp = TMP / "cct_xs_v2_global.onnx"
    config_tmp = TMP / "cct_xs_v2_global_plate_config.yaml"
    fetch(MODEL_URL, model_tmp)
    fetch(PLATE_CONFIG_URL, config_tmp)

    model_out = RES_DIR / "FastPlateOCR.onnx"
    config_out = RES_DIR / "FastPlateOCR.plate_config.yaml"
    shutil.copyfile(model_tmp, model_out)
    shutil.copyfile(config_tmp, config_out)

    print(f"OK: {model_out} ({model_out.stat().st_size / 1024 / 1024:.2f} MB)")
    print(f"OK: {config_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

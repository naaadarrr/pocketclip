#!/usr/bin/env python3
"""Convert ScreenParser (YOLO11-L, Apache 2.0) to Core ML for Pocketclip.

Direct Ultralytics Core ML export fails on YOLO11 Attention (traced int() on
tensor shapes). This script patches Attention.forward to a shape-safe
scaled_dot_product_attention path, then exports.

Reads models/best.pt and writes:
  models/ScreenParser.mlpackage
  models/screenparser_names.json
  models/ScreenParser.spec.txt
"""
from __future__ import annotations

import json
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODELS = ROOT / "models"
PT = MODELS / "best.pt"
OUT = MODELS / "ScreenParser.mlpackage"
NAMES = MODELS / "screenparser_names.json"
SPEC = MODELS / "ScreenParser.spec.txt"


def patch_attention() -> None:
    import torch
    import torch.nn.functional as F
    from ultralytics.nn.modules.block import Attention

    def forward_export(self, x: torch.Tensor) -> torch.Tensor:
        qkv = self.qkv(x).flatten(2)
        qkv = qkv.reshape(qkv.shape[0], self.num_heads, self.key_dim * 2 + self.head_dim, qkv.shape[-1])
        q, k, v = qkv.split([self.key_dim, self.key_dim, self.head_dim], dim=2)
        if hasattr(F, "scaled_dot_product_attention"):
            x_attn = F.scaled_dot_product_attention(
                q.transpose(-2, -1), k.transpose(-2, -1), v.transpose(-2, -1)
            ).transpose(-2, -1)
        else:
            attn = ((q * self.scale).transpose(-2, -1) @ k).softmax(dim=-1)
            x_attn = v @ attn.transpose(-2, -1)
        x_attn = x_attn.reshape(x.shape) + self.pe(v.reshape(x.shape))
        return self.proj(x_attn)

    Attention.forward = forward_export


def fix_metadata(package: Path) -> None:
    import coremltools as ct

    ml = ct.models.MLModel(str(package))
    spec = ml.get_spec()
    # Ultralytics stamps AGPL on export metadata; ScreenParser weights are Apache 2.0.
    spec.description.metadata.license = "Apache-2.0 (ScreenParser / IBM Research - ETH Zurich)."
    spec.description.metadata.author = "IBM Research - ETH Zurich (ScreenParser)"
    spec.description.metadata.shortDescription = (
        "ScreenParser YOLO11-L UI layout-box detector (55 classes), Apache 2.0."
    )
    ct.models.MLModel(spec, weights_dir=ml.weights_dir).save(str(package))
    SPEC.write_text(str(ct.models.MLModel(str(package))) + "\n")


def main() -> int:
    if not PT.exists():
        print(f"missing weights: {PT}", file=sys.stderr)
        return 1
    from ultralytics import YOLO

    print("loading", PT, "size", PT.stat().st_size)
    patch_attention()
    model = YOLO(str(PT))
    names = model.names
    if isinstance(names, dict):
        payload = {str(k): v for k, v in names.items()}
        ordered = [names[i] for i in sorted(names)]
    else:
        payload = {str(i): n for i, n in enumerate(names)}
        ordered = list(names)
    NAMES.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    print("classes", len(ordered), ":", ", ".join(ordered))

    t0 = time.time()
    exported = model.export(format="coreml", imgsz=1280, nms=False, half=False)
    exported = Path(exported)
    print("export finished in %.1fs -> %s" % (time.time() - t0, exported))

    if OUT.exists() and exported.resolve() != OUT.resolve():
        shutil.rmtree(OUT)
    if exported.resolve() != OUT.resolve():
        shutil.move(str(exported), str(OUT))
    fix_metadata(OUT)
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

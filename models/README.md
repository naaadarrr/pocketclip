# ScreenParser Core ML (visual layout-box detector)

ScreenParser is a YOLO11-L UI layout-box detector (Apache 2.0) trained on web screenshots (55 classes: Button, List Item, Side Bar, Navigation Bar, Text Input, and so on). It complements the Accessibility box tree. Native Mac windows are best-effort.

## Convert

From the project root, with the local `.venv-ml` that has `torch`, `ultralytics`, and `coremltools`:

```
.venv-ml/bin/python models/convert_screenparser.py
```

This reads `models/best.pt` and writes `models/ScreenParser.mlpackage` plus `models/screenparser_names.json`. Direct Ultralytics Core ML export fails on YOLO11 Attention (`int` on traced shapes); the script patches `Attention.forward` first. `./build.sh` copies the package into the app bundle when present.

If conversion is not done, the app still ships: region capture uses the Accessibility containment tree, and the visual detector hook returns no boxes.

## Notes

- Do not bundle `best.pt` or `best.onnx` in the app (conversion only).
- Do not use older OmniParser `icon_detect` / Ultralytics YOLOv8 AGPL weights.
- Input is a 1280×1280 RGB image; output is raw YOLO `(1, 59, 33600)` (xywh in input pixels + 55 class scores). NMS runs in the app.

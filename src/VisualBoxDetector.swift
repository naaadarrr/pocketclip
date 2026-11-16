import AppKit
import CoreML
import Foundation
import ImageIO
import ScreenCaptureKit

// MARK: - Screenshot (once at region-capture start)

struct ScreenShot {
    let frame: NSRect          // AppKit screen frame
    let scale: CGFloat
    let image: CGImage
}

enum ScreenCaptureOnce {
    @available(macOS 14.0, *)
    static func captureAll(excludingOurWindows: Bool = true) async -> [ScreenShot] {
        var out: [ScreenShot] = []
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let myPid = ProcessInfo.processInfo.processIdentifier
            let excluded: [SCWindow] = excludingOurWindows
                ? content.windows.filter { $0.owningApplication?.processID == myPid }
                : []
            for scr in NSScreen.screens {
                let num = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                let displayID = CGDirectDisplayID(num?.uint32Value ?? CGMainDisplayID())
                guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                    continue
                }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let config = SCStreamConfiguration()
                let scale = scr.backingScaleFactor
                let pw = max(display.width, Int((scr.frame.width * scale).rounded()))
                let ph = max(display.height, Int((scr.frame.height * scale).rounded()))
                config.width = pw
                config.height = ph
                config.showsCursor = false
                config.colorSpaceName = CGColorSpace.sRGB
                let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                out.append(ScreenShot(frame: scr.frame, scale: scale, image: full))
            }
        } catch {
            NSLog("PC screen capture for box detector failed: %@", error.localizedDescription)
        }
        return out
    }
}

struct DetectedVisualBox {
    let pixelRect: CGRect      // top-left origin, original image pixel space
    let label: String
    let confidence: Float
}

// MARK: - ScreenParser (YOLO11-L, Apache 2.0) via Core ML
// Isolated hook: RegionPicker calls VisualBoxDetector.detect(shots:windows:).
// If the model is missing or fails to load, this returns [] and AX boxes still work.

enum VisualBoxDetector {
    private static var cached: ScreenParserDetector?
    private static var loadAttempted = false
    private static var loadNote = "not loaded"
    private static let lock = NSLock()

    static var status: String { loadNote }

    static func shared() -> ScreenParserDetector? {
        lock.lock()
        defer { lock.unlock() }
        if loadAttempted { return cached }
        loadAttempted = true
        do {
            let det = try ScreenParserDetector.load()
            cached = det
            loadNote = det.describe()
            NSLog("PC ScreenParser loaded: %@", loadNote)
        } catch {
            loadNote = "ScreenParser unavailable: \(error.localizedDescription)"
            cached = nil
            NSLog("PC ScreenParser not in build: %@", error.localizedDescription)
        }
        return cached
    }

    /// True if a Core ML package is bundled. Does not compile or load the model.
    static var modelPresent: Bool { ScreenParserDetector.locateModel() != nil }

    /// Compile (and optionally infer once) off the main thread at app launch so ⌘⇧2 is not blocked.
    static func prewarm() {
        guard modelPresent else { return }
        DispatchQueue.global(qos: .utility).async {
            let t0 = CACurrentMediaTime()
            guard let det = shared() else { return }
            if let img = dummyImage(side: det.inputSide) {
                _ = det.detect(image: img)
            }
            let ms = Int(((CACurrentMediaTime() - t0) * 1000).rounded())
            NSLog("PC ScreenParser prewarm in %dms (%@)", ms, status)
        }
    }

    private static func dummyImage(side: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.setFillColor(gray: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }

    static func detect(shots: [ScreenShot], windows: [NSRect]) -> [LayoutBox] {
        guard let det = shared() else { return [] }
        var out: [LayoutBox] = []
        for shot in shots {
            let t0 = CACurrentMediaTime()
            let found = det.detect(image: shot.image)
            let ms = Int(((CACurrentMediaTime() - t0) * 1000).rounded())
            NSLog("PC ScreenParser %dx%d → %d boxes in %dms", shot.image.width, shot.image.height, found.count, ms)
            for d in found {
                if d.confidence < ScreenParserDetector.defaultConf { continue }
                let appKit = appKitRectFromPixel(d.pixelRect, shot: shot)
                guard LayoutGeometry.isPlausible(appKit) else { continue }
                let window = windows.first { $0.insetBy(dx: -2, dy: -2).contains(NSPoint(x: appKit.midX, y: appKit.midY)) } ?? shot.frame
                let clipped = appKit.intersection(window)
                guard LayoutGeometry.isPlausible(clipped) else { continue }
                if LayoutGeometry.isTextLeaf(d.label) { continue }
                if LayoutGeometry.isVisualScrap(d.label, frame: clipped) { continue }
                out.append(LayoutBox(
                    id: out.count,
                    appKitFrame: clipped,
                    windowAppKit: window,
                    role: d.label,
                    title: "",
                    source: .visual,
                    confidence: d.confidence,
                    parentId: nil
                ))
            }
        }
        return out
    }

    static func appKitRectFromPixel(_ r: CGRect, shot: ScreenShot) -> NSRect {
        let x = shot.frame.minX + r.minX / shot.scale
        let w = r.width / shot.scale
        let h = r.height / shot.scale
        let y = shot.frame.maxY - r.maxY / shot.scale
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// On-screen window frames in AppKit coords (skip our own overlays).
    static func onScreenWindowFrames() -> [NSRect] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPid = ProcessInfo.processInfo.processIdentifier
        var frames: [NSRect] = []
        for info in raw {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPid else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            if layer > 24 { continue }
            guard let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat else { continue }
            if w < 40 || h < 40 { continue }
            frames.append(appKitRect(fromQuartz: CGRect(x: x, y: y, width: w, height: h)))
        }
        return frames
    }
}

final class ScreenParserDetector {
    static let defaultInputSide = 1280
    static let defaultConf: Float = 0.15
    static let defaultIou: Float = 0.45
    static let maxDetections = 400

    /// 55 UI classes from ScreenParse / ScreenParser (index order). Overridden by names.json if present.
    static let defaultNames: [String] = [
        "Table", "Column/Browser", "Button", "Utility Button", "App Icon",
        "Navigation Bar", "Status Bar", "Search Field", "Toolbar", "Tooltip",
        "Video", "Tab Bar", "Side Bar", "Slider", "Picker",
        "ContextMenu", "DockMenu", "EditMenu", "Image", "Scroll",
        "Switch", "File Icon", "Chart", "Window", "Screen",
        "List", "List Item", "PopUp Menu", "Steppers", "Toggles",
        "Text Input", "Rating Indicator", "Checkbox", "Radiobox", "Select",
        "Avatar", "Badge", "Alert", "Progress bar", "Bottom navigation",
        "Breadcrumb", "Page control", "Link", "Menu", "Pagination",
        "Tab", "Search Bar", "Date-Time picker", "Calendar", "Text",
        "Heading", "Code snippet", "Carousel", "Notification", "Logo"
    ]

    let model: MLModel
    let inputName: String
    let inputSide: Int
    let names: [String]
    let sourceURL: URL

    func describe() -> String {
        "\(sourceURL.lastPathComponent) input=\(inputSide) classes=\(names.count)"
    }

    static func load() throws -> ScreenParserDetector {
        guard let url = locateModel() else {
            throw NSError(domain: "Pocketclip", code: 21, userInfo: [NSLocalizedDescriptionKey: "ScreenParser.mlpackage / .mlmodelc not in app bundle"])
        }
        let compiled: URL
        if url.pathExtension == "mlmodelc" {
            compiled = url
        } else {
            compiled = try MLModel.compileModel(at: url)
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        let model = try MLModel(contentsOf: compiled, configuration: cfg)
        let inputs = model.modelDescription.inputDescriptionsByName
        guard let imageInput = inputs.first(where: { $0.value.type == .image })?.key
                ?? inputs.keys.sorted().first else {
            throw NSError(domain: "Pocketclip", code: 22, userInfo: [NSLocalizedDescriptionKey: "ScreenParser model has no image input"])
        }
        var side = defaultInputSide
        if let c = inputs[imageInput]?.imageConstraint {
            side = max(c.pixelsWide, c.pixelsHigh)
        }
        let names = loadNames(beside: url) ?? defaultNames
        return ScreenParserDetector(model: model, inputName: imageInput, inputSide: side, names: names, sourceURL: url)
    }

    static func locateModel() -> URL? {
        let bundle = Bundle.main
        if let u = bundle.url(forResource: "ScreenParser", withExtension: "mlmodelc") { return u }
        if let u = bundle.url(forResource: "ScreenParser", withExtension: "mlpackage") { return u }
        if let root = bundle.resourceURL {
            let c = root.appendingPathComponent("ScreenParser.mlmodelc")
            if FileManager.default.fileExists(atPath: c.path) { return c }
            let p = root.appendingPathComponent("ScreenParser.mlpackage")
            if FileManager.default.fileExists(atPath: p.path) { return p }
        }
        return nil
    }

    static func loadNames(beside url: URL) -> [String]? {
        let candidates = [
            url.deletingLastPathComponent().appendingPathComponent("screenparser_names.json"),
            Bundle.main.url(forResource: "screenparser_names", withExtension: "json")
        ].compactMap { $0 }
        for u in candidates {
            guard let data = try? Data(contentsOf: u) else { continue }
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                let keys = dict.keys.compactMap { Int($0) }.sorted()
                if !keys.isEmpty {
                    return keys.map { dict[String($0)] ?? "class\($0)" }
                }
            }
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [String], !arr.isEmpty {
                return arr
            }
        }
        return nil
    }

    init(model: MLModel, inputName: String, inputSide: Int, names: [String], sourceURL: URL) {
        self.model = model
        self.inputName = inputName
        self.inputSide = inputSide
        self.names = names
        self.sourceURL = sourceURL
    }

    func detect(image: CGImage) -> [DetectedVisualBox] {
        do {
            let boxed = Self.letterbox(image, to: inputSide)
            guard let inputDesc = model.modelDescription.inputDescriptionsByName[inputName],
                  let constraint = inputDesc.imageConstraint else {
                return []
            }
            // Image is already letterboxed to the model input size; no extra crop/scale.
            let fv = try MLFeatureValue(
                cgImage: boxed.image,
                orientation: .up,
                constraint: constraint,
                options: [:]
            )
            let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: fv])
            let out = try model.prediction(from: provider)
            return decode(out, letterbox: boxed, source: image)
        } catch {
            NSLog("PC ScreenParser infer failed: %@", error.localizedDescription)
            return []
        }
    }

    // MARK: - Letterbox (YOLO-style, pad 114)

    struct Letterbox {
        let image: CGImage
        let scale: CGFloat
        let padX: CGFloat
        let padY: CGFloat
        let side: Int
        let srcW: Int
        let srcH: Int
    }

    static func letterbox(_ image: CGImage, to side: Int) -> Letterbox {
        let sw = image.width, sh = image.height
        let scale = min(CGFloat(side) / CGFloat(sw), CGFloat(side) / CGFloat(sh))
        let nw = (CGFloat(sw) * scale).rounded()
        let nh = (CGFloat(sh) * scale).rounded()
        let padX = ((CGFloat(side) - nw) / 2).rounded()
        let padY = ((CGFloat(side) - nh) / 2).rounded()
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 114 / 255, green: 114 / 255, blue: 114 / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // CGContext origin is bottom-left; place the image in the padded box.
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: padX, y: CGFloat(side) - padY - nh, width: nw, height: nh))
        return Letterbox(image: ctx.makeImage()!, scale: scale, padX: padX, padY: padY, side: side, srcW: sw, srcH: sh)
    }

    func mapBox(_ r: CGRect, letterbox: Letterbox) -> CGRect {
        // r is in letterboxed pixel space, top-left origin.
        let x = (r.minX - letterbox.padX) / letterbox.scale
        let y = (r.minY - letterbox.padY) / letterbox.scale
        let w = r.width / letterbox.scale
        let h = r.height / letterbox.scale
        let clipped = CGRect(x: x, y: y, width: w, height: h)
            .intersection(CGRect(x: 0, y: 0, width: letterbox.srcW, height: letterbox.srcH))
        return clipped
    }

    // MARK: - Output decode (NMS pipeline or raw YOLO)

    func decode(_ out: MLFeatureProvider, letterbox: Letterbox, source: CGImage) -> [DetectedVisualBox] {
        let names = out.featureNames
        // Ultralytics Core ML + nms=True often exports "coordinates" + "confidence".
        if names.contains("coordinates"), names.contains("confidence"),
           let coords = out.featureValue(for: "coordinates")?.multiArrayValue,
           let confs = out.featureValue(for: "confidence")?.multiArrayValue {
            return decodeNMSPipeline(coords: coords, confs: confs, letterbox: letterbox)
        }
        // Raw YOLO: pick the largest multiarray (typically 1×(4+nc)×N or 1×N×(4+nc)).
        var best: MLMultiArray?
        var bestCount = 0
        for name in names {
            guard let arr = out.featureValue(for: name)?.multiArrayValue else { continue }
            let count = arr.count
            if count > bestCount {
                best = arr
                bestCount = count
            }
        }
        if let arr = best {
            return decodeRawYOLO(arr, letterbox: letterbox)
        }
        NSLog("PC ScreenParser unexpected outputs: %@", names.joined(separator: ","))
        return []
    }

    func decodeNMSPipeline(coords: MLMultiArray, confs: MLMultiArray, letterbox: Letterbox) -> [DetectedVisualBox] {
        // coordinates: (N, 4) often xywh normalized 0–1 relative to input side, or xyxy.
        // confidence: (N, C) or (N,).
        let cShape = coords.shape.map { $0.intValue }
        let fShape = confs.shape.map { $0.intValue }
        let n = max(cShape.dropLast().reduce(1, *), cShape.first ?? 0)
        let boxStride = 4
        let classCount = fShape.last == 4 ? 1 : (fShape.last ?? names.count)
        var preds: [Pred] = []
        let side = CGFloat(letterbox.side)

        func cAt(_ i: Int, _ k: Int) -> Double {
            if cShape.count >= 2, cShape.last == 4 {
                return coords[[NSNumber(value: i), NSNumber(value: k)]].doubleValue
            }
            return coords[i * boxStride + k].doubleValue
        }
        func fAt(_ i: Int, _ k: Int) -> Double {
            if fShape.count >= 2, (fShape.last ?? 1) > 1 {
                return confs[[NSNumber(value: i), NSNumber(value: k)]].doubleValue
            }
            return confs[i].doubleValue
        }

        let rows = cShape.count >= 2 && cShape.last == 4 ? cShape[cShape.count - 2] : n
        for i in 0..<rows {
            var cls = 0
            var conf = fAt(i, 0)
            if classCount > 1 {
                var best: Double = -1
                for k in 0..<classCount {
                    let v = fAt(i, k)
                    if v > best { best = v; cls = k }
                }
                conf = best
            }
            if conf < Double(Self.defaultConf) { continue }
            var x = cAt(i, 0), y = cAt(i, 1), w = cAt(i, 2), h = cAt(i, 3)
            // Heuristic: if values look normalized, scale up.
            if x <= 1.5 && y <= 1.5 && w <= 1.5 && h <= 1.5 {
                x *= side; y *= side; w *= side; h *= side
            }
            // If w/h look like x2/y2 (xyxy) rather than width/height.
            let rect: CGRect
            if w > x && h > y && (w > side * 0.02) && (w < side * 1.2) && (h < side * 1.2) && (w - x) < side * 1.2 && (h - y) < side * 1.2 && (w > 2 || h > 2) && (cAt(i, 2) > cAt(i, 0)) {
                // Could be xyxy. If w,h already look like extents > x,y use xyxy.
                // Only treat as xyxy when x2>x1 and y2>y1 and the "width" would be implausibly large as a center box.
                let asXYXY = CGRect(x: x, y: y, width: w - x, height: h - y)
                let asCXCY = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
                // Prefer xywh (YOLO NMS pipeline usually outputs xywh or xyxy in pixels). Use xywh default.
                // If w or h exceed the side substantially when treated as width, it's xyxy.
                if w > side && h > side {
                    rect = asXYXY
                } else {
                    rect = asCXCY
                }
                _ = asXYXY
            } else {
                rect = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
            }
            let mapped = mapBox(rect, letterbox: letterbox)
            if mapped.width >= 2, mapped.height >= 2 {
                preds.append(Pred(rect: mapped, cls: cls, conf: Float(conf)))
            }
        }
        return finalize(preds)
    }

    func decodeRawYOLO(_ arr: MLMultiArray, letterbox: Letterbox) -> [DetectedVisualBox] {
        let shape = arr.shape.map { $0.intValue }
        // Typical: (1, 4+nc, N) or (1, N, 4+nc) or (4+nc, N).
        let dims = shape.filter { $0 > 1 }
        let nc = names.count
        let channels = 4 + nc
        var preds: [Pred] = []
        let side = CGFloat(letterbox.side)

        func emit(x: Double, y: Double, w: Double, h: Double, scoresStart: (Int) -> Double) {
            var cls = 0
            var best: Double = -1
            for k in 0..<nc {
                let v = scoresStart(k)
                if v > best { best = v; cls = k }
            }
            if best < Double(Self.defaultConf) { return }
            var bx = x, by = y, bw = w, bh = h
            if bx <= 1.5, by <= 1.5, bw <= 1.5, bh <= 1.5 {
                bx *= side; by *= side; bw *= side; bh *= side
            }
            let rect = CGRect(x: bx - bw / 2, y: by - bh / 2, width: bw, height: bh)
            let mapped = mapBox(rect, letterbox: letterbox)
            if mapped.width >= 2, mapped.height >= 2 {
                preds.append(Pred(rect: mapped, cls: cls, conf: Float(best)))
            }
        }

        // Flattened access with given layout.
        if let cIdx = shape.lastIndex(of: channels), shape.contains(where: { $0 > channels }) {
            // Identify N and whether channels-first.
            if cIdx == shape.count - 1 {
                // (..., N, 4+nc)
                let n = shape[shape.count - 2]
                for i in 0..<n {
                    let base = i * channels
                    emit(
                        x: arr[base + 0].doubleValue,
                        y: arr[base + 1].doubleValue,
                        w: arr[base + 2].doubleValue,
                        h: arr[base + 3].doubleValue,
                        scoresStart: { k in arr[base + 4 + k].doubleValue }
                    )
                }
            } else {
                // (..., 4+nc, N) — channels first
                let n = shape.last ?? 0
                let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
                let usesFloat = arr.dataType == .float32
                func at(_ ch: Int, _ i: Int) -> Double {
                    let idx = ch * n + i
                    if usesFloat { return Double(ptr[idx]) }
                    return arr[idx].doubleValue
                }
                for i in 0..<n {
                    emit(
                        x: at(0, i), y: at(1, i), w: at(2, i), h: at(3, i),
                        scoresStart: { k in at(4 + k, i) }
                    )
                }
            }
        } else if dims.count >= 2 {
            NSLog("PC ScreenParser raw shape not recognized: %@", shape.map(String.init).joined(separator: "×"))
        }
        return finalize(preds)
    }

    struct Pred {
        var rect: CGRect
        var cls: Int
        var conf: Float
    }

    func finalize(_ preds: [Pred]) -> [DetectedVisualBox] {
        let kept = Self.nms(preds, iou: Self.defaultIou, limit: Self.maxDetections)
        return kept.map { p in
            let name = (p.cls >= 0 && p.cls < names.count) ? names[p.cls] : "Block"
            return DetectedVisualBox(pixelRect: p.rect, label: name, confidence: p.conf)
        }
    }

    static func nms(_ preds: [Pred], iou: Float, limit: Int) -> [Pred] {
        let sorted = preds.sorted { $0.conf > $1.conf }
        var keep: [Pred] = []
        var suppressed = [Bool](repeating: false, count: sorted.count)
        for i in 0..<sorted.count {
            if suppressed[i] { continue }
            let a = sorted[i]
            keep.append(a)
            if keep.count >= limit { break }
            for j in (i + 1)..<sorted.count {
                if suppressed[j] { continue }
                let b = sorted[j]
                if Self.iou(a.rect, b.rect) >= CGFloat(iou) {
                    suppressed[j] = true
                }
            }
        }
        return keep
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull || inter.width <= 0 || inter.height <= 0 { return 0 }
        let union = a.width * a.height + b.width * b.height - inter.width * inter.height
        return (inter.width * inter.height) / max(1, union)
    }
}

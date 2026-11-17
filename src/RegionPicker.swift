import AppKit
import ApplicationServices
import ImageIO
import ScreenCaptureKit

// MARK: - Coordinate helpers
// AppKit: origin at bottom-left of primary screen, Y up.
// AX / CGWindowList: origin at top-left of primary screen, Y down.

private func primaryScreenHeight() -> CGFloat {
    NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
        ?? NSScreen.main?.frame.height
        ?? 0
}

func quartzPoint(fromAppKit p: NSPoint) -> CGPoint {
    CGPoint(x: p.x, y: primaryScreenHeight() - p.y)
}

func appKitPoint(fromQuartz p: CGPoint) -> NSPoint {
    NSPoint(x: p.x, y: primaryScreenHeight() - p.y)
}

func appKitRect(fromQuartz r: CGRect) -> NSRect {
    let topLeft = appKitPoint(fromQuartz: r.origin)
    return NSRect(x: topLeft.x, y: topLeft.y - r.height, width: r.width, height: r.height)
}

func quartzRect(fromAppKit r: NSRect) -> CGRect {
    let topLeft = quartzPoint(fromAppKit: NSPoint(x: r.minX, y: r.maxY))
    return CGRect(x: topLeft.x, y: topLeft.y, width: r.width, height: r.height)
}

// MARK: - Window under cursor (skip our own overlays)

private func windowUnderCursor(appKitPoint: NSPoint) -> (pid: pid_t, windowID: CGWindowID, quartzBounds: CGRect)? {
    let q = quartzPoint(fromAppKit: appKitPoint)
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    let myPid = ProcessInfo.processInfo.processIdentifier
    for info in raw {
        guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPid else { continue }
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        if layer > 24 { continue }
        guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
              let b = info[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
              let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat else { continue }
        let bounds = CGRect(x: x, y: y, width: w, height: h)
        if bounds.width < 40 || bounds.height < 40 { continue }
        if bounds.contains(q) {
            return (pid, wid, bounds)
        }
    }
    return nil
}

// MARK: - Capture crop of an AppKit global rect

@available(macOS 14.0, *)
func captureRectSCK(_ appKitRect: NSRect) async throws -> URL {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let center = NSPoint(x: appKitRect.midX, y: appKitRect.midY)
    let scr = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        ?? NSScreen.main
        ?? NSScreen.screens[0]
    let num = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    let displayID = CGDirectDisplayID(num?.uint32Value ?? CGMainDisplayID())
    guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
        throw NSError(domain: "Pocketclip", code: 11, userInfo: [NSLocalizedDescriptionKey: "no display"])
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    let scale = scr.backingScaleFactor
    let pw = max(display.width, Int((scr.frame.width * scale).rounded()))
    let ph = max(display.height, Int((scr.frame.height * scale).rounded()))
    config.width = pw
    config.height = ph
    config.showsCursor = false
    config.colorSpaceName = CGColorSpace.sRGB
    let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

    let localX = (appKitRect.minX - scr.frame.minX) * scale
    let localY = (scr.frame.maxY - appKitRect.maxY) * scale
    let localW = appKitRect.width * scale
    let localH = appKitRect.height * scale
    var crop = CGRect(x: localX.rounded(.down),
                      y: localY.rounded(.down),
                      width: max(1, localW.rounded(.up)),
                      height: max(1, localH.rounded(.up)))
    crop = crop.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
    guard crop.width >= 1, crop.height >= 1,
          let clipped = full.cropping(to: crop) else {
        throw NSError(domain: "Pocketclip", code: 12, userInfo: [NSLocalizedDescriptionKey: "crop failed"])
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "Pocketclip", code: 13, userInfo: [NSLocalizedDescriptionKey: "png dest"])
    }
    let dpi = 72.0 * Double(scale)
    let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(dest, clipped, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "Pocketclip", code: 14, userInfo: [NSLocalizedDescriptionKey: "png write"])
    }
    return url
}

func captureRectViaTool(_ appKitRect: NSRect, done: @escaping (URL?) -> Void) {
    let q = quartzRect(fromAppKit: appKitRect)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString).png")
    let arg = String(format: "%.0f,%.0f,%.0f,%.0f", q.origin.x, q.origin.y, q.width, q.height)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R", arg, url.path]
    p.terminationHandler = { _ in
        DispatchQueue.main.async {
            done(FileManager.default.fileExists(atPath: url.path) ? url : nil)
        }
    }
    try? p.run()
}

func capturePickedRect(_ appKitRect: NSRect, done: @escaping (URL?) -> Void) {
    if #available(macOS 14.0, *) {
        Task {
            do {
                let u = try await captureRectSCK(appKitRect)
                await MainActor.run { done(u) }
            } catch {
                NSLog("PC region SCK crop failed: %@ — falling back to screencapture -R", error.localizedDescription)
                await MainActor.run { captureRectViaTool(appKitRect, done: done) }
            }
        }
    } else {
        captureRectViaTool(appKitRect, done: done)
    }
}

// MARK: - Capture cursor (distinct plus, not the system crosshair)

private enum RegionCaptureCursor {
    static let plus: NSCursor = makePlus()

    static func apply(arrowOverCancel: Bool) {
        if arrowOverCancel {
            NSCursor.arrow.set()
        } else {
            plus.set()
        }
    }

    private static func makePlus() -> NSCursor {
        // Odd pixel size so the cross sits on a pixel. 41 px @2x ≈ 20.5 pt.
        let pixelSide = 41
        let scale: CGFloat = 2
        let pointSide = CGFloat(pixelSide) / scale
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: pixelSide,
            height: pixelSide,
            bitsPerComponent: 8,
            bytesPerRow: pixelSide * 4,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            return NSCursor.crosshair
        }
        let mid = CGFloat(pixelSide) / 2
        let inset: CGFloat = 6
        func stroke(width: CGFloat, color: CGColor) {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.setLineCap(.square)
            ctx.move(to: CGPoint(x: mid, y: inset))
            ctx.addLine(to: CGPoint(x: mid, y: CGFloat(pixelSide) - inset))
            ctx.move(to: CGPoint(x: inset, y: mid))
            ctx.addLine(to: CGPoint(x: CGFloat(pixelSide) - inset, y: mid))
            ctx.strokePath()
        }
        stroke(width: 7, color: NSColor(calibratedWhite: 0.08, alpha: 0.94).cgColor)
        stroke(width: 3, color: NSColor.white.cgColor)
        guard let cg = ctx.makeImage() else { return NSCursor.crosshair }
        let image = NSImage(cgImage: cg, size: NSSize(width: pointSide, height: pointSide))
        return NSCursor(image: image, hotSpot: NSPoint(x: pointSide / 2, y: pointSide / 2))
    }
}

// MARK: - Overlay UI

private final class RegionOverlayView: NSView {
    var dimColor = NSColor(calibratedWhite: 0, alpha: 0.28)
    var punchColor = NSColor(calibratedWhite: 0, alpha: 0.50)
    var highlight: NSRect?
    /// Dashed for snap/recognition; solid for free-drag selection.
    var highlightDashed = true
    var onMove: ((NSPoint, Bool) -> Void)?
    var onDown: ((NSPoint, Bool) -> Void)?
    var onDrag: ((NSPoint, Bool) -> Void)?
    var onUp: ((NSPoint, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onAlt: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func draw(_ dirty: NSRect) {
        if let h = highlight, h.width >= 1, h.height >= 1 {
            let veil = NSBezierPath(rect: bounds)
            veil.append(NSBezierPath(rect: h))
            veil.windingRule = .evenOdd
            punchColor.setFill()
            veil.fill()
            let dashes: [CGFloat] = [7, 5]
            let border = NSBezierPath(rect: h)
            border.lineWidth = 1
            if highlightDashed {
                border.setLineDash(dashes, count: dashes.count, phase: 0)
            }
            // Soft outer shadow instead of a hard dark inner line.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowOffset = .zero
            shadow.shadowBlurRadius = 2
            shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.35)
            shadow.set()
            NSColor(calibratedWhite: 1, alpha: 0.95).setStroke()
            border.stroke()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            dimColor.setFill()
            bounds.fill()
        }
    }

    override func mouseMoved(with e: NSEvent) {
        onMove?(convert(e.locationInWindow, from: nil), e.modifierFlags.contains(.option))
    }
    override func mouseDragged(with e: NSEvent) {
        onDrag?(convert(e.locationInWindow, from: nil), e.modifierFlags.contains(.option))
    }
    override func mouseDown(with e: NSEvent) {
        if e.buttonNumber != 0 { return }
        onDown?(convert(e.locationInWindow, from: nil), e.modifierFlags.contains(.option))
    }
    override func mouseUp(with e: NSEvent) {
        if e.buttonNumber != 0 { return }
        onUp?(convert(e.locationInWindow, from: nil), e.modifierFlags.contains(.option))
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onCancel?(); return }
        if e.modifierFlags.contains(.option) { onAlt?(true) }
        super.keyDown(with: e)
    }
    override func flagsChanged(with e: NSEvent) {
        onAlt?(e.modifierFlags.contains(.option))
        super.flagsChanged(with: e)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: RegionCaptureCursor.plus)
    }

    override func cursorUpdate(with event: NSEvent) {
        RegionCaptureCursor.plus.set()
    }

    override func mouseEntered(with event: NSEvent) {
        RegionCaptureCursor.plus.set()
    }
}

private final class RegionLabelView: NSView {
    private var text = ""
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let padX: CGFloat = 10
    private static let padY: CGFloat = 4
    private static let textColor = NSColor(calibratedRed: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1)
    private static let capsuleFill = NSColor(calibratedRed: 227 / 255, green: 227 / 255, blue: 229 / 255, alpha: 1)
    private static let capsuleStroke = NSColor(calibratedRed: 198 / 255, green: 198 / 255, blue: 202 / 255, alpha: 1)

    static var textAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byClipping
        return [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: p
        ]
    }

    static func make() -> RegionLabelView {
        let v = RegionLabelView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = capsuleFill.cgColor
        v.layer?.borderWidth = 1
        v.layer?.borderColor = capsuleStroke.cgColor
        v.layer?.masksToBounds = false
        v.layer?.shadowColor = NSColor.black.cgColor
        v.layer?.shadowOpacity = 0.18
        v.layer?.shadowRadius = 8
        v.layer?.shadowOffset = CGSize(width: 0, height: -2)
        v.isHidden = true
        return v
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setText(_ text: String) {
        self.text = text
        let size = (text as NSString).size(withAttributes: Self.textAttributes)
        let height = ceil(size.height) + Self.padY * 2
        setFrameSize(NSSize(
            width: ceil(size.width) + Self.padX * 2,
            height: height
        ))
        layer?.cornerRadius = height / 2
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = (text as NSString).size(withAttributes: Self.textAttributes)
        let rect = NSRect(
            x: Self.padX,
            y: ((bounds.height - size.height) / 2).rounded(.toNearestOrAwayFromZero),
            width: bounds.width - Self.padX * 2,
            height: size.height
        )
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: Self.textAttributes, context: nil)
    }
}

private final class RegionTipCancelButton: NSView {
    var title = "" {
        didSet { needsDisplay = true }
    }
    var onClick: (() -> Void)?
    private var pressed = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseExited(with event: NSEvent) {
        if !pressed { RegionCaptureCursor.plus.set() }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if pressed != inside {
            pressed = inside
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if inside { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = pressed
            ? NSColor(calibratedRed: 228 / 255, green: 228 / 255, blue: 232 / 255, alpha: 0.94)
            : NSColor(calibratedRed: 250 / 255, green: 250 / 255, blue: 252 / 255, alpha: 0.94)
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: inset.height / 2, yRadius: inset.height / 2)
        fill.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor(calibratedWhite: 1, alpha: 0.55).setStroke()
        let top = NSBezierPath()
        top.lineWidth = 1
        top.move(to: NSPoint(x: inset.minX + inset.height / 2, y: inset.minY + 0.5))
        top.line(to: NSPoint(x: inset.maxX - inset.height / 2, y: inset.minY + 0.5))
        top.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedRed: 170 / 255, green: 174 / 255, blue: 182 / 255, alpha: 0.40).setStroke()
        path.lineWidth = 1
        path.stroke()
        let size = (title as NSString).size(withAttributes: RegionTipView.buttonAttributes)
        let rect = NSRect(
            x: 0,
            y: ((bounds.height - size.height) / 2).rounded(.toNearestOrAwayFromZero),
            width: bounds.width,
            height: size.height
        )
        (title as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: RegionTipView.buttonAttributes, context: nil)
    }
}

private final class RegionTipView: NSView {
    private var text = ""
    var onCancel: (() -> Void)?
    private let cancelButton = RegionTipCancelButton(frame: .zero)
    private let blur = NSVisualEffectView(frame: .zero)
    private let face = RegionTipFace(frame: .zero)

    private static let capsuleHeight: CGFloat = 38
    private static let padLeft: CGFloat = 17
    private static let padRight: CGFloat = 6
    private static let gap: CGFloat = 15
    private static let buttonHeight: CGFloat = 28
    private static let buttonPadX: CGFloat = 13
    private static let screenMargin: CGFloat = 12

    static let textColor = NSColor(calibratedRed: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1)
    static let capsuleFill = NSColor(calibratedRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 0.55)
    static let capsuleStroke = NSColor(calibratedRed: 150 / 255, green: 154 / 255, blue: 164 / 255, alpha: 0.50)

    override var isOpaque: Bool { false }

    static func make(_ text: String) -> RegionTipView {
        let v = RegionTipView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        v.layer?.isOpaque = false
        v.blur.material = .popover
        v.blur.blendingMode = .behindWindow
        v.blur.state = .active
        v.blur.appearance = NSAppearance(named: .aqua)
        v.blur.wantsLayer = true
        v.blur.layer?.cornerRadius = capsuleHeight / 2
        v.blur.layer?.masksToBounds = true
        v.blur.autoresizingMask = [.width, .height]
        v.addSubview(v.blur)
        v.face.owner = v
        v.face.autoresizingMask = [.width, .height]
        v.addSubview(v.face)
        v.layer?.cornerRadius = capsuleHeight / 2
        v.layer?.borderWidth = 0
        v.layer?.masksToBounds = false
        v.layer?.shadowColor = NSColor.black.cgColor
        v.layer?.shadowOpacity = 0.14
        v.layer?.shadowRadius = 10
        v.layer?.shadowOffset = CGSize(width: 0, height: -2)
        v.cancelButton.title = L("region.cancel")
        v.cancelButton.onClick = { [weak v] in v?.onCancel?() }
        v.addSubview(v.cancelButton)
        v.setText(text)
        return v
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if cancelButton.frame.contains(point) { return cancelButton }
        return bounds.contains(point) ? self : nil
    }

    func containsCancel(windowPoint: NSPoint) -> Bool {
        cancelButton.frame.contains(convert(windowPoint, from: nil))
    }

    static var textAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = .left
        p.lineBreakMode = .byClipping
        return [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: textColor,
            .paragraphStyle: p
        ]
    }

    static var buttonAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byClipping
        return [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: textColor,
            .paragraphStyle: p
        ]
    }

    func setText(_ text: String) {
        self.text = text
        layoutTip()
        needsDisplay = true
        face.needsDisplay = true
    }

    private func layoutTip() {
        let textSize = (text as NSString).size(withAttributes: Self.textAttributes)
        let btnTextSize = (cancelButton.title as NSString).size(withAttributes: Self.buttonAttributes)
        let btnW = ceil(btnTextSize.width) + Self.buttonPadX * 2
        let width = Self.padLeft + ceil(textSize.width) + Self.gap + btnW + Self.padRight
        setFrameSize(NSSize(width: width, height: Self.capsuleHeight))
        let btnY = ((Self.capsuleHeight - Self.buttonHeight) / 2).rounded(.toNearestOrAwayFromZero)
        blur.frame = bounds
        face.frame = bounds
        face.needsDisplay = true
        cancelButton.frame = NSRect(
            x: width - Self.padRight - btnW,
            y: btnY,
            width: btnW,
            height: Self.buttonHeight
        )
        layer?.cornerRadius = Self.capsuleHeight / 2
        let r = CGRect(origin: .zero, size: NSSize(width: width, height: Self.capsuleHeight))
        layer?.shadowPath = CGPath(roundedRect: r, cornerWidth: Self.capsuleHeight / 2, cornerHeight: Self.capsuleHeight / 2, transform: nil)
    }

    func placeCentered(in bounds: NSRect, visibleTop: CGFloat, margin: CGFloat = 16) {
        var f = frame
        f.origin.x = clampedX(in: bounds, width: f.width)
        f.origin.y = visibleTop - f.height - margin
        frame = f
    }

    func recenterHorizontally() {
        guard let parent = superview else { return }
        var f = frame
        f.origin.x = clampedX(in: parent.bounds, width: f.width)
        frame = f
    }

    private func clampedX(in bounds: NSRect, width: CGFloat) -> CGFloat {
        let side = Self.screenMargin
        if width + side * 2 >= bounds.width {
            return max(0, (bounds.width - width) / 2)
        }
        return max(side, min((bounds.width - width) / 2, bounds.width - width - side))
    }

    func drawFace(_ bounds: NSRect) {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = max(0, inset.height / 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        Self.capsuleFill.setFill()
        bounds.fill()
        NSGradient(colors: [
            NSColor(calibratedWhite: 1, alpha: 0.50),
            NSColor(calibratedWhite: 1, alpha: 0)
        ])?.draw(
            from: NSPoint(x: bounds.midX, y: bounds.minY),
            to: NSPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.45),
            options: []
        )
        NSColor(calibratedWhite: 1, alpha: 0.70).setStroke()
        let highlight = NSBezierPath()
        highlight.lineWidth = 1
        highlight.lineCapStyle = .round
        highlight.move(to: NSPoint(x: inset.minX + radius, y: inset.minY + 0.5))
        highlight.line(to: NSPoint(x: inset.maxX - radius, y: inset.minY + 0.5))
        highlight.stroke()
        NSGraphicsContext.restoreGraphicsState()

        Self.capsuleStroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let textSize = (text as NSString).size(withAttributes: Self.textAttributes)
        let rect = NSRect(
            x: Self.padLeft,
            y: ((bounds.height - textSize.height) / 2).rounded(.toNearestOrAwayFromZero),
            width: ceil(textSize.width),
            height: textSize.height
        )
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: Self.textAttributes, context: nil)
    }
}

/// Draws the tip's tint, sheen, border and label above the blur backdrop.
private final class RegionTipFace: NSView {
    weak var owner: RegionTipView?
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { owner?.drawFace(bounds) }
}

/// Smart region picker — box tree (AX + optional ScreenParser) built once; drag for freeform.
final class RegionPicker {
    static let shared = RegionPicker()

    private var windows: [NSWindow] = []
    private var views: [RegionOverlayView] = []
    private var labels: [RegionLabelView] = []
    private var tips: [RegionTipView] = []
    private var localMonitor: Any?
    private var globalKeyMonitor: Any?
    private var done: ((URL?) -> Void)?
    private var axEnabled = false
    private var starting = false

    private let boxTree = LayoutBoxTree()
    private var axBoxes: [LayoutBox] = []
    private var visualBoxes: [LayoutBox] = []
    private var shots: [ScreenShot] = []
    private var treeGeneration: UInt64 = 0

    private var pointerDown = false
    private var freeDragging = false
    private var startGlobal: NSPoint = .zero
    private var hoverGlobal: NSRect?
    private var hoverLabel: String = ""
    private let dragThreshold: CGFloat = 6
    private var lastMoveAt: CFTimeInterval = 0

    private init() {}

    static func begin(done: @escaping (URL?) -> Void) {
        shared.start(done: done)
    }

    private func start(done: @escaping (URL?) -> Void) {
        cancelActive(callDone: false)
        self.done = done
        starting = true
        boxTree.reset()
        axBoxes = []
        visualBoxes = []
        shots = []
        treeGeneration &+= 1
        let gen = treeGeneration

        if let del = NSApp.delegate as? AppDelegate, let e = del.editor, e.panel.isVisible {
            e.hide()
        }

        axEnabled = AXBoxCollector.isTrusted(prompt: true)
        tlog(axEnabled ? "region picker AX trusted" : "region picker AX unavailable")

        // Overlay first — do not wait for AX waits, screenshots, or Core ML.
        showOverlays()

        let collectAX = axEnabled
        Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = CACurrentMediaTime()
            guard collectAX else {
                NSLog("PC region AX skipped (not trusted)")
                return
            }
            let result = AXBoxCollector.collectAllOnScreen { partial in
                guard let self = self else { return }
                self.publishAX(partial.boxes, log: partial.log, generation: gen)
            }
            let ms = Int(((CACurrentMediaTime() - t0) * 1000).rounded())
            guard let self = self else { return }
            self.publishAX(result.boxes, log: "region tree ready in \(ms)ms — \(result.log)", generation: gen)
        }

        Task { [weak self] in
            let shots: [ScreenShot]
            if #available(macOS 14.0, *) {
                shots = await ScreenCaptureOnce.captureAll(excludingOurWindows: true)
            } else {
                shots = []
            }
            guard let self = self else { return }
            await MainActor.run {
                guard self.done != nil, self.treeGeneration == gen else { return }
                self.shots = shots
            }
            self.runVisualDetector(shots: shots, generation: gen)
        }
    }

    private func publishAX(_ boxes: [LayoutBox], log: String, generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self = self, self.done != nil, self.treeGeneration == generation else { return }
            tlog(log)
        }
        updateTree(ax: boxes, visual: nil, generation: generation)
    }

    private func runVisualDetector(shots: [ScreenShot], generation: UInt64) {
        guard !shots.isEmpty else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let windows = VisualBoxDetector.onScreenWindowFrames()
            let t0 = CACurrentMediaTime()
            let visual = VisualBoxDetector.detect(shots: shots, windows: windows)
            let ms = Int(((CACurrentMediaTime() - t0) * 1000).rounded())
            guard let self = self else { return }
            await MainActor.run {
                guard self.done != nil, self.treeGeneration == generation else { return }
                tlog("region visual merge: \(visual.count) boxes in \(ms)ms (\(VisualBoxDetector.status))")
            }
            self.updateTree(ax: nil, visual: visual, generation: generation)
        }
    }

    /// Merge + parent assignment stay off the main thread; only the swap and hover refresh run on main.
    private func updateTree(ax: [LayoutBox]?, visual: [LayoutBox]?, generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self = self, self.done != nil, self.treeGeneration == generation else { return }
            if let ax { self.axBoxes = ax }
            if let visual { self.visualBoxes = visual }
            let axCopy = self.axBoxes
            let visCopy = self.visualBoxes
            Task.detached(priority: .userInitiated) { [weak self] in
                let built = LayoutBoxTree.build(ax: axCopy, visual: visCopy)
                await MainActor.run { [weak self] in
                    guard let self = self, self.done != nil, self.treeGeneration == generation else { return }
                    self.boxTree.install(built)
                    tlog("region tree ax=\(self.boxTree.axCount) visual=\(self.boxTree.visualCount) total=\(self.boxTree.count)")
                    if !self.freeDragging {
                        self.refreshHover(global: NSEvent.mouseLocation, preferParent: NSEvent.modifierFlags.contains(.option))
                    }
                }
            }
        }
    }

    private func showOverlays() {
        starting = false
        let canSnap = axEnabled || VisualBoxDetector.modelPresent || !boxTree.boxes.isEmpty
        for scr in NSScreen.screens {
            let win = NSWindow(
                contentRect: scr.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: scr
            )
            win.setFrame(scr.frame, display: true)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            win.ignoresMouseEvents = false
            win.acceptsMouseMovedEvents = true
            win.isReleasedWhenClosed = false

            let root = NSView(frame: NSRect(origin: .zero, size: scr.frame.size))
            root.wantsLayer = true

            let overlay = RegionOverlayView(frame: root.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.addTrackingArea(NSTrackingArea(
                rect: overlay.bounds,
                options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .cursorUpdate],
                owner: overlay,
                userInfo: nil
            ))
            overlay.onMove = { [weak self] p, alt in self?.handleMove(view: overlay, local: p, alt: alt) }
            overlay.onDown = { [weak self] p, alt in self?.handleDown(view: overlay, local: p, alt: alt) }
            overlay.onDrag = { [weak self] p, alt in self?.handleDrag(view: overlay, local: p, alt: alt) }
            overlay.onUp = { [weak self] p, alt in self?.handleUp(view: overlay, local: p, alt: alt) }
            overlay.onCancel = { [weak self] in self?.cancelActive(callDone: true) }
            overlay.onAlt = { [weak self] alt in
                guard let self = self, !self.freeDragging else { return }
                self.refreshHover(global: NSEvent.mouseLocation, preferParent: alt)
            }

            let tipText = canSnap ? L("region.tip") : L("region.tip.noax")
            let tip = RegionTipView.make(tipText)
            tip.onCancel = { [weak self] in self?.cancelActive(callDone: true) }
            let visibleTop = scr.visibleFrame.maxY - scr.frame.minY
            tip.placeCentered(in: root.bounds, visibleTop: visibleTop)
            tip.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]

            let label = RegionLabelView.make()

            root.addSubview(overlay)
            root.addSubview(label)
            root.addSubview(tip)
            win.contentView = root
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()

            windows.append(win)
            views.append(overlay)
            labels.append(label)
            tips.append(tip)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        RegionCaptureCursor.apply(arrowOverCancel: isMouseOverCancel())

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .cursorUpdate]) { [weak self] e in
            if e.type == .keyDown, e.keyCode == 53 {
                self?.cancelActive(callDone: true)
                return nil
            }
            if e.type == .cursorUpdate {
                self?.applyCaptureCursor()
                return nil
            }
            if e.type == .flagsChanged {
                let alt = e.modifierFlags.contains(.option)
                self?.refreshHover(global: NSEvent.mouseLocation, preferParent: alt)
            }
            return e
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { DispatchQueue.main.async { self?.cancelActive(callDone: true) } }
        }

        refreshHover(global: NSEvent.mouseLocation, preferParent: NSEvent.modifierFlags.contains(.option))
    }

    private func globalPoint(from view: NSView, local: NSPoint) -> NSPoint {
        let inWindow = view.convert(local, to: nil)
        return view.window?.convertPoint(toScreen: inWindow) ?? inWindow
    }

    private func handleMove(view: RegionOverlayView, local: NSPoint, alt: Bool) {
        applyCaptureCursor()
        if freeDragging { return }
        if pointerDown {
            handleDrag(view: view, local: local, alt: alt)
            return
        }
        let g = globalPoint(from: view, local: local)
        let now = CACurrentMediaTime()
        if now - lastMoveAt < 0.016 { return }
        lastMoveAt = now
        refreshHover(global: g, preferParent: alt)
    }

    private func handleDown(view: RegionOverlayView, local: NSPoint, alt: Bool) {
        applyCaptureCursor()
        pointerDown = true
        freeDragging = false
        startGlobal = globalPoint(from: view, local: local)
        refreshHover(global: startGlobal, preferParent: alt)
    }

    private func handleDrag(view: RegionOverlayView, local: NSPoint, alt: Bool) {
        applyCaptureCursor()
        guard pointerDown else { return }
        let g = globalPoint(from: view, local: local)
        let dist = hypot(g.x - startGlobal.x, g.y - startGlobal.y)
        if !freeDragging && dist >= dragThreshold {
            freeDragging = true
            hoverGlobal = nil
            hoverLabel = ""
            for tip in tips {
                tip.setText(L("region.release"))
                tip.recenterHorizontally()
            }
        }
        if freeDragging {
            let r = NSRect(
                x: min(startGlobal.x, g.x),
                y: min(startGlobal.y, g.y),
                width: abs(g.x - startGlobal.x),
                height: abs(g.y - startGlobal.y)
            )
            setHighlight(global: r, label: nil)
        }
    }

    private func handleUp(view: RegionOverlayView, local: NSPoint, alt: Bool) {
        guard pointerDown else { return }
        pointerDown = false
        let g = globalPoint(from: view, local: local)

        if freeDragging {
            let r = NSRect(
                x: min(startGlobal.x, g.x),
                y: min(startGlobal.y, g.y),
                width: abs(g.x - startGlobal.x),
                height: abs(g.y - startGlobal.y)
            )
            freeDragging = false
            if r.width < 4 || r.height < 4 {
                cancelActive(callDone: true)
                return
            }
            finish(with: r)
            return
        }

        refreshHover(global: g, preferParent: alt)
        if let r = hoverGlobal, r.width >= 4, r.height >= 4 {
            finish(with: r)
            return
        }
        cancelActive(callDone: true)
    }

    private func refreshHover(global: NSPoint, preferParent: Bool) {
        guard !freeDragging else { return }
        guard windowUnderCursor(appKitPoint: global) != nil else {
            setHighlight(global: nil, label: nil)
            return
        }
        if let b = boxTree.hit(at: global, preferParent: preferParent) {
            setHighlight(global: b.appKitFrame, label: nil)
        } else {
            setHighlight(global: nil, label: nil)
        }
    }

    private func setHighlight(global: NSRect?, label: String?) {
        hoverGlobal = global
        hoverLabel = label ?? ""

        var bestIdx: Int?
        var bestArea: CGFloat = 0
        var clippedByIndex: [NSRect?] = Array(repeating: nil, count: views.count)
        for (i, view) in views.enumerated() {
            guard let win = view.window else { continue }
            let screenFrame = win.frame
            if let g = global {
                let local = NSRect(
                    x: g.origin.x - screenFrame.origin.x,
                    y: g.origin.y - screenFrame.origin.y,
                    width: g.width,
                    height: g.height
                )
                let clipped = local.intersection(view.bounds)
                if clipped.width >= 1, clipped.height >= 1 {
                    clippedByIndex[i] = clipped
                    let area = clipped.width * clipped.height
                    if area > bestArea {
                        bestArea = area
                        bestIdx = i
                    }
                }
                view.highlight = clippedByIndex[i]
            } else {
                view.highlight = nil
            }
            view.highlightDashed = !freeDragging
            view.needsDisplay = true
        }

        let sizeText: String?
        if let g = global, g.width >= 1, g.height >= 1 {
            let px = capturePixelSize(of: g)
            sizeText = "\(px.width) × \(px.height)"
        } else {
            sizeText = nil
        }

        for (i, labelView) in labels.enumerated() {
            if let text = sizeText, i == bestIdx, let box = clippedByIndex[i] {
                labelView.setText(text)
                placeSizeLabel(labelView, under: box, in: views[i].bounds, avoiding: tips.indices.contains(i) ? tips[i].frame : nil)
                labelView.isHidden = false
            } else {
                labelView.isHidden = true
            }
        }
    }

    /// Pixel size of the PNG that `captureRectSCK` would write: backing-scale
    /// pixels, with width/height rounded up the same way as the crop.
    private func capturePixelSize(of appKitRect: NSRect) -> (width: Int, height: Int) {
        let center = NSPoint(x: appKitRect.midX, y: appKitRect.midY)
        let scr = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let scale = scr?.backingScaleFactor ?? 1
        return (
            width: max(1, Int((appKitRect.width * scale).rounded(.up))),
            height: max(1, Int((appKitRect.height * scale).rounded(.up)))
        )
    }

    private func placeSizeLabel(_ label: RegionLabelView, under box: NSRect, in bounds: NSRect, avoiding avoid: NSRect?) {
        let size = label.frame.size
        let gap: CGFloat = 6
        let margin: CGFloat = 8
        func position(below: Bool) -> NSRect {
            var x = box.minX
            var y = below ? (box.minY - gap - size.height) : (box.maxY + gap)
            x = min(max(x, margin), max(margin, bounds.maxX - size.width - margin))
            y = min(max(y, margin), max(margin, bounds.maxY - size.height - margin))
            return NSRect(origin: NSPoint(x: x, y: y), size: size)
        }
        var frame = position(below: true)
        let belowFits = box.minY - gap - size.height >= margin
        if !belowFits {
            frame = position(below: false)
        }
        if let avoid, !avoid.isEmpty, frame.intersects(avoid.insetBy(dx: -2, dy: -2)) {
            let alt = position(below: !belowFits)
            if !alt.intersects(avoid.insetBy(dx: -2, dy: -2)) || (belowFits && alt.minY >= margin) {
                frame = alt
            }
        }
        label.frame = frame
    }

    private func applyCaptureCursor() {
        RegionCaptureCursor.apply(arrowOverCancel: isMouseOverCancel())
    }

    private func finish(with appKitRect: NSRect) {
        tlog(String(format: "region picked %.0fx%.0f", appKitRect.width, appKitRect.height))
        let callback = done
        done = nil
        tearDownOverlay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            capturePickedRect(appKitRect) { url in
                callback?(url)
            }
        }
    }

    private func isMouseOverCancel() -> Bool {
        let screen = NSEvent.mouseLocation
        for tip in tips {
            guard let win = tip.window else { continue }
            if tip.containsCancel(windowPoint: win.convertPoint(fromScreen: screen)) {
                return true
            }
        }
        return false
    }

    private func cancelActive(callDone: Bool) {
        starting = false
        let callback = done
        done = nil
        tearDownOverlay()
        if callDone { callback?(nil) }
    }

    private func tearDownOverlay() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
        views.removeAll()
        labels.removeAll()
        tips.removeAll()
        shots = []
        axBoxes = []
        visualBoxes = []
        boxTree.reset()
        treeGeneration &+= 1
        pointerDown = false
        freeDragging = false
        hoverGlobal = nil
        NSCursor.arrow.set()
    }
}

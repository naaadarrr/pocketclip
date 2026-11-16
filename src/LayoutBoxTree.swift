import AppKit
import Foundation

// MARK: - Layout box tree
// Geometric containment tree of UI layout boxes (cards, sections, buttons, rows).
// Built once at region-capture start; hover is a cheap point-in-rect test.

enum BoxSource: String {
    case ax
    case visual
}

struct LayoutBox {
    let id: Int
    let appKitFrame: NSRect
    let windowAppKit: NSRect
    let role: String
    let title: String
    let source: BoxSource
    let confidence: Float
    let parentId: Int?

    var area: CGFloat { max(1, appKitFrame.width * appKitFrame.height) }

    func with(id: Int? = nil, parentId: Int?, windowAppKit: NSRect? = nil) -> LayoutBox {
        LayoutBox(
            id: id ?? self.id,
            appKitFrame: appKitFrame,
            windowAppKit: windowAppKit ?? self.windowAppKit,
            role: role,
            title: title,
            source: source,
            confidence: confidence,
            parentId: parentId
        )
    }
}

enum LayoutGeometry {
    /// Minimum size to keep a box in the tree at all.
    static let minEdge: CGFloat = 8
    /// Default snap floor (~24–32 pt). Text leaves and smaller scraps are not snap targets.
    static let minSnapEdge: CGFloat = 28
    /// Tappable controls (buttons, links, fields) may be a bit smaller.
    static let minControlEdge: CGFloat = 18
    static let minControlArea: CGFloat = 400
    static let maxWindowFrac: CGFloat = 0.92

    static func normalizedRole(_ role: String) -> String {
        var r = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if r.hasPrefix("ax") { r = String(r.dropFirst(2)) }
        return r.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    /// Text nodes and similar leaves — never hover targets; promote to a container.
    static func isTextLeaf(_ role: String) -> Bool {
        switch normalizedRole(role) {
        case "statictext", "static text", "text", "heading", "tooltip",
             "code snippet", "codesnippet":
            return true
        default:
            return false
        }
    }

    static func isTappableControl(_ role: String) -> Bool {
        switch normalizedRole(role) {
        case "button", "utility button", "link",
             "checkbox", "check box", "radiobutton", "radio button", "radiobox",
             "switch", "toggles", "popupbutton", "pop up button",
             "popup menu", "popupmenu", "combobox", "combo box",
             "textfield", "text field", "textarea", "text area", "text input",
             "search field", "search bar", "slider", "steppers", "incrementor",
             "disclosuretriangle", "disclosure triangle", "menuitem", "menu item",
             "tab", "image":
            return true
        default:
            return false
        }
    }

    /// Visual-detector leftovers that should not become hover targets.
    static func isVisualScrap(_ role: String, frame: NSRect) -> Bool {
        let r = normalizedRole(role)
        switch r {
        case "text", "heading", "tooltip", "code snippet", "codesnippet":
            return true
        case "badge", "app icon", "file icon", "avatar", "logo",
             "page control", "rating indicator":
            return frame.width < 40 || frame.height < 40
        default:
            return false
        }
    }

    static func isNearFullWindow(_ r: NSRect, window: NSRect) -> Bool {
        r.width > window.width * maxWindowFrac && r.height > window.height * maxWindowFrac
    }

    /// Hover / click target: layout containers and tappable controls, not text leaves or slivers.
    static func isUsefulSnapTarget(_ box: LayoutBox) -> Bool {
        let r = box.appKitFrame
        let window = box.windowAppKit
        guard r.width.isFinite, r.height.isFinite, r.width >= minEdge, r.height >= minEdge else { return false }
        if isNearFullWindow(r, window: window) { return false }
        if isTextLeaf(box.role) { return false }
        if box.source == .visual && isVisualScrap(box.role, frame: r) { return false }

        let w = r.width, h = r.height
        let aspect = max(w / max(1, h), h / max(1, w))
        let n = normalizedRole(box.role)
        let isBar = [
            "toolbar", "navigation bar", "status bar", "tab bar",
            "bottom navigation", "search bar", "row", "list item"
        ].contains(n)
        let barOK = (isBar || aspect > 8) && w > window.width * 0.35 && h >= 22 && h < window.height * 0.3

        if isTappableControl(box.role) {
            if w >= minControlEdge && h >= minControlEdge && w * h >= minControlArea { return true }
            if barOK { return true }
            return false
        }

        if w >= minSnapEdge && h >= minSnapEdge {
            if aspect > 14 { return barOK }
            return true
        }
        return barOK
    }

    static func isPlausible(_ r: NSRect) -> Bool {
        r.width >= minEdge && r.height >= minEdge && r.width.isFinite && r.height.isFinite
    }

    static func iou(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull || inter.width <= 0 || inter.height <= 0 { return 0 }
        let union = a.width * a.height + b.width * b.height - inter.width * inter.height
        return (inter.width * inter.height) / max(1, union)
    }

    /// A strictly contains B (slightly padded) and is meaningfully larger.
    static func strictlyContains(_ outer: NSRect, _ inner: NSRect) -> Bool {
        let o = outer.insetBy(dx: -0.5, dy: -0.5)
        guard o.minX <= inner.minX, o.minY <= inner.minY,
              o.maxX >= inner.maxX, o.maxY >= inner.maxY else { return false }
        let oa = outer.width * outer.height
        let ia = inner.width * inner.height
        return oa > ia * 1.02
    }
}

final class LayoutBoxTree {
    private(set) var boxes: [LayoutBox] = []

    var count: Int { boxes.count }
    var axCount: Int { boxes.reduce(0) { $0 + ($1.source == .ax ? 1 : 0) } }
    var visualCount: Int { boxes.reduce(0) { $0 + ($1.source == .visual ? 1 : 0) } }

    func reset() {
        boxes = []
    }

    func install(_ newBoxes: [LayoutBox]) {
        boxes = newBoxes
    }

    func rebuild(ax: [LayoutBox], visual: [LayoutBox]) {
        boxes = Self.build(ax: ax, visual: visual)
    }

    /// Off-main-thread: merge + assign parents. Swap in via `install` on the main thread.
    static func build(ax: [LayoutBox], visual: [LayoutBox]) -> [LayoutBox] {
        assignParents(merge(ax: ax, visual: visual))
    }

    /// Smallest *useful* snap target containing the point.
    /// Text leaves and tiny scraps are skipped, so this already promotes to a container.
    /// Option/Alt walks to the next useful ancestor of the current highlight.
    func hit(at point: NSPoint, preferParent: Bool) -> LayoutBox? {
        var best: LayoutBox?
        for b in boxes {
            guard b.appKitFrame.insetBy(dx: -0.5, dy: -0.5).contains(point) else { continue }
            guard LayoutGeometry.isUsefulSnapTarget(b) else { continue }
            if best == nil || b.area < best!.area {
                best = b
            }
        }
        guard let pick = best else { return nil }
        if preferParent, let ancestor = nextUsefulAncestor(of: pick) {
            return ancestor
        }
        return pick
    }

    func nextUsefulAncestor(of box: LayoutBox) -> LayoutBox? {
        var current = box
        var hops = 0
        while hops < 12, let pid = current.parentId, let parent = self.box(id: pid) {
            hops += 1
            if LayoutGeometry.isUsefulSnapTarget(parent), parent.area > current.area * 1.05 {
                return parent
            }
            current = parent
        }
        return nil
    }

    func box(id: Int) -> LayoutBox? {
        if id >= 0, id < boxes.count, boxes[id].id == id { return boxes[id] }
        return boxes.first { $0.id == id }
    }

    /// Prefer a tight, sensible AX frame when one is present; fill gaps with visual boxes.
    /// Drops text leaves and tiny visual scraps so they never become hover targets.
    static func merge(ax: [LayoutBox], visual: [LayoutBox]) -> [LayoutBox] {
        var out: [LayoutBox] = []
        out.reserveCapacity(ax.count + visual.count)

        func append(_ b: LayoutBox, dedupeIoU: CGFloat) -> Bool {
            guard LayoutGeometry.isPlausible(b.appKitFrame) else { return false }
            if LayoutGeometry.isTextLeaf(b.role) { return false }
            if b.source == .visual && LayoutGeometry.isVisualScrap(b.role, frame: b.appKitFrame) {
                return false
            }
            // Keep near-full-window boxes as tree roots, but not tiny leftovers.
            if !LayoutGeometry.isNearFullWindow(b.appKitFrame, window: b.windowAppKit)
                && !LayoutGeometry.isUsefulSnapTarget(b)
                && !LayoutGeometry.isTappableControl(b.role) {
                // Allow slightly-small containers into the tree only if both edges clear minEdge * 2.
                // Otherwise they just create tiny hover-adjacent wrappers.
                let r = b.appKitFrame
                if r.width < LayoutGeometry.minSnapEdge || r.height < LayoutGeometry.minSnapEdge {
                    return false
                }
            }
            for e in out {
                if LayoutGeometry.iou(e.appKitFrame, b.appKitFrame) >= dedupeIoU {
                    return false
                }
            }
            let next = LayoutBox(
                id: out.count,
                appKitFrame: b.appKitFrame,
                windowAppKit: b.windowAppKit,
                role: b.role,
                title: b.title,
                source: b.source,
                confidence: b.confidence,
                parentId: nil
            )
            out.append(next)
            return true
        }

        for b in ax {
            _ = append(b, dedupeIoU: 0.95)
        }

        for b in visual {
            let role = b.role.lowercased()
            let winFracW = b.appKitFrame.width / max(1, b.windowAppKit.width)
            let winFracH = b.appKitFrame.height / max(1, b.windowAppKit.height)
            if (role == "screen" || role == "window") && winFracW > 0.92 && winFracH > 0.92 {
                continue
            }
            var skip = false
            for e in out where e.source == .ax {
                if LayoutGeometry.iou(e.appKitFrame, b.appKitFrame) >= 0.80 {
                    skip = true
                    break
                }
            }
            if skip { continue }
            _ = append(b, dedupeIoU: 0.90)
        }
        return out
    }

    /// Parent = smallest strictly containing box.
    static func assignParents(_ boxes: [LayoutBox]) -> [LayoutBox] {
        let n = boxes.count
        guard n > 0 else { return [] }
        var parentOf = [Int?](repeating: nil, count: n)
        let order = (0..<n).sorted { boxes[$0].area < boxes[$1].area }
        for (idx, i) in order.enumerated() {
            let inner = boxes[i].appKitFrame
            var bestJ: Int?
            var bestArea = CGFloat.greatestFiniteMagnitude
            var k = idx + 1
            while k < n {
                let j = order[k]
                k += 1
                let outer = boxes[j].appKitFrame
                if outer.width * outer.height >= bestArea { continue }
                if LayoutGeometry.strictlyContains(outer, inner) {
                    bestJ = j
                    bestArea = outer.width * outer.height
                }
            }
            parentOf[i] = bestJ
        }
        return (0..<n).map { i in
            boxes[i].with(id: i, parentId: parentOf[i])
        }
    }
}

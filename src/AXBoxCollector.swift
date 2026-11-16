import AppKit
import ApplicationServices
import Foundation

// MARK: - Accessibility layout-box collector
// Built once at region-capture start. Recursively walks AX children, including AXWebArea.
//
// Enablement (targeted, documented):
//   1. Always set AXManualAccessibility on the application element.
//      Electron (and some Chromium builds) use this to build the in-window / web tree
//      without the window-animation side effects of AXEnhancedUserInterface.
//   2. Do not set AXEnhancedUserInterface by default. That flag is what VoiceOver sets
//      on Chrome and can change window chrome / animations.
//   3. After a short wait, if a known Chromium *browser* still has an empty AXWebArea,
//      set AXEnhancedUserInterface on that app only, wait again, and re-walk.
//      This fallback is logged.

enum AXBoxCollector {
    static let minEdge: CGFloat = 8
    static let maxNodesPerWindow = 12_000
    static let maxDepth = 40
    static let messagingTimeout: Float = 1.0
    /// Emit `ax partial` by this wall-clock deadline even if one app is still stuck.
    static let firstWaveBudget: TimeInterval = 1.5
    /// Give slow-but-healthy apps this long to join the ready tree; then abandon stragglers.
    static let totalBudget: TimeInterval = 2.8

    static func isTrusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    struct Result {
        let boxes: [LayoutBox]
        let log: String
        let usedEnhancedUI: [String]
    }

    private struct PerApp {
        var boxes: [LayoutBox]
        var note: String
        var usedEnhanced: Bool
        var chromiumNeedsRetry: Bool
    }

    /// Heap-retained so a late finish from an abandoned hung AX call cannot write into stack memory.
    private final class Session {
        let lock = NSLock()
        var byPid: [pid_t: PerApp] = [:]
        var pending = 0
    }

    private static let lingerLock = NSLock()
    private static var lingering: [Session] = []

    private static func retainIfPending(_ session: Session) {
        session.lock.lock()
        let pending = session.pending
        session.lock.unlock()
        guard pending > 0 else { return }
        lingerLock.lock()
        lingering.append(session)
        lingerLock.unlock()
    }

    /// Walks each on-screen app in isolation. One hung AX call is abandoned at the
    /// first-wave / total budget; other apps' boxes are still published as a partial
    /// and then as the ready tree. Visual merge is unchanged and arrives separately.
    static func collectAllOnScreen(onPartial: ((Result) -> Void)? = nil) -> Result {
        let t0 = CACurrentMediaTime()

        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return Result(boxes: [], log: "ax: no window list", usedEnhancedUI: [])
        }

        struct Win {
            let pid: pid_t
            let quartz: CGRect
        }

        let myPid = ProcessInfo.processInfo.processIdentifier
        var wins: [Win] = []
        var pids: [pid_t] = []
        var pidSet = Set<pid_t>()
        for info in raw {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPid else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            if layer > 24 { continue }
            guard let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat else { continue }
            if w < 40 || h < 40 { continue }
            wins.append(Win(pid: pid, quartz: CGRect(x: x, y: y, width: w, height: h)))
            if pidSet.insert(pid).inserted { pids.append(pid) }
        }

        var bundleByPid: [pid_t: String] = [:]
        var nameByPid: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if pidSet.contains(app.processIdentifier) {
                bundleByPid[app.processIdentifier] = app.bundleIdentifier ?? ""
                nameByPid[app.processIdentifier] = app.localizedName ?? ""
            }
        }

        if pids.isEmpty {
            let ms = Int(((CACurrentMediaTime() - t0) * 1000).rounded())
            let empty = Result(boxes: [], log: "ax partial windows=0 apps=0 boxes=0 in \(ms)ms", usedEnhancedUI: [])
            onPartial?(empty)
            return Result(boxes: [], log: "ax windows=0 apps=0 boxes=0 in \(ms)ms", usedEnhancedUI: [])
        }

        let session = Session()
        session.pending = pids.count
        let firstGroup = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        for pid in pids {
            let appWins = wins.filter { $0.pid == pid }.map { $0.quartz }
            firstGroup.enter()
            queue.async {
                let one = collectPidFirstWave(pid: pid, windowQuartz: appWins, bundleByPid: bundleByPid, nameByPid: nameByPid)
                session.lock.lock()
                session.byPid[pid] = one
                session.pending -= 1
                session.lock.unlock()
                firstGroup.leave()
            }
        }

        _ = firstGroup.wait(timeout: .now() + firstWaveBudget)

        let firstMs = Int(((CACurrentMediaTime() - t0) * 1000).rounded())
        let firstSnap = snapshot(session, allPids: pids, bundleByPid: bundleByPid, nameByPid: nameByPid)
        onPartial?(Result(
            boxes: firstSnap.boxes,
            log: partialLog(windows: wins.count, apps: pids.count, boxes: firstSnap.boxes.count, ms: firstMs, ok: firstSnap.ok, stuck: firstSnap.stuck),
            usedEnhancedUI: []
        ))

        let retryPids: [pid_t] = firstSnap.finished.compactMap { pid, one in
            one.chromiumNeedsRetry ? pid : nil
        }
        if !retryPids.isEmpty {
            let secondGroup = DispatchGroup()
            for pid in retryPids {
                let appWins = wins.filter { $0.pid == pid }.map { $0.quartz }
                secondGroup.enter()
                queue.async {
                    let retried = collectPidSecondWave(pid: pid, windowQuartz: appWins, prior: sessionResult(session, pid: pid), bundleByPid: bundleByPid, nameByPid: nameByPid)
                    session.lock.lock()
                    session.byPid[pid] = retried
                    session.lock.unlock()
                    secondGroup.leave()
                }
            }
            let remaining = max(0.05, totalBudget - (CACurrentMediaTime() - t0))
            _ = secondGroup.wait(timeout: .now() + remaining)
        }

        let leftover = max(0.05, totalBudget - (CACurrentMediaTime() - t0))
        _ = firstGroup.wait(timeout: .now() + leftover)

        retainIfPending(session)

        let ms = Int(((CACurrentMediaTime() - t0) * 1000).rounded())
        let snap = snapshot(session, allPids: pids, bundleByPid: bundleByPid, nameByPid: nameByPid)
        var log = "ax windows=\(wins.count) apps=\(pids.count) boxes=\(snap.boxes.count) in \(ms)ms ok=\(snap.ok)/\(pids.count)"
        if !snap.stuck.isEmpty {
            log += " stuck=\(snap.stuck.count) (\(snap.stuck.joined(separator: ", ")))"
        }
        if !snap.notes.isEmpty {
            log += "; \(snap.notes.joined(separator: "; "))"
        }
        return Result(boxes: snap.boxes, log: log, usedEnhancedUI: snap.usedEnhanced)
    }

    private struct Snap {
        var boxes: [LayoutBox]
        var ok: Int
        var stuck: [String]
        var notes: [String]
        var usedEnhanced: [String]
        var finished: [pid_t: PerApp]
    }

    private static func sessionResult(_ session: Session, pid: pid_t) -> PerApp? {
        session.lock.lock()
        let v = session.byPid[pid]
        session.lock.unlock()
        return v
    }

    private static func snapshot(_ session: Session, allPids: [pid_t], bundleByPid: [pid_t: String], nameByPid: [pid_t: String]) -> Snap {
        session.lock.lock()
        let finished = session.byPid
        session.lock.unlock()
        var boxes: [LayoutBox] = []
        boxes.reserveCapacity(512)
        var notes: [String] = []
        var used: [String] = []
        var stuck: [String] = []
        for pid in allPids {
            let name = label(pid, bundleByPid, nameByPid)
            if let one = finished[pid] {
                boxes.append(contentsOf: one.boxes)
                notes.append(one.note)
                if one.usedEnhanced { used.append(name) }
            } else {
                stuck.append(name)
                notes.append("\(name): stuck")
            }
        }
        return Snap(boxes: boxes, ok: finished.count, stuck: stuck, notes: notes, usedEnhanced: used, finished: finished)
    }

    private static func partialLog(windows: Int, apps: Int, boxes: Int, ms: Int, ok: Int, stuck: [String]) -> String {
        var s = "ax partial windows=\(windows) apps=\(apps) boxes=\(boxes) in \(ms)ms ok=\(ok)/\(apps)"
        if !stuck.isEmpty {
            s += " stuck=\(stuck.count) (\(stuck.joined(separator: ", ")))"
        }
        return s
    }

    private static func collectPidFirstWave(pid: pid_t, windowQuartz: [CGRect], bundleByPid: [pid_t: String], nameByPid: [pid_t: String]) -> PerApp {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let err = setBoolAttr(app, "AXManualAccessibility", true)
        let name = label(pid, bundleByPid, nameByPid)
        var boxes: [LayoutBox] = []
        var nextId = 0
        for q in windowQuartz {
            let collected = walkWindow(app: app, windowQuartz: q, startId: nextId)
            nextId += collected.count
            boxes.append(contentsOf: collected)
        }
        let bid = bundleByPid[pid] ?? ""
        var needsRetry = false
        if isChromiumBrowser(bid), webAreaPopulated(app) == false {
            needsRetry = true
        }
        return PerApp(
            boxes: boxes,
            note: "\(name): manual=\(describe(err))",
            usedEnhanced: false,
            chromiumNeedsRetry: needsRetry
        )
    }

    private static func collectPidSecondWave(pid: pid_t, windowQuartz: [CGRect], prior: PerApp?, bundleByPid: [pid_t: String], nameByPid: [pid_t: String]) -> PerApp {
        let name = label(pid, bundleByPid, nameByPid)
        var kept = prior ?? PerApp(boxes: [], note: "\(name): manual=?", usedEnhanced: false, chromiumNeedsRetry: true)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        usleep(150_000)
        let err = setBoolAttr(app, "AXEnhancedUserInterface", true)
        kept.note += "; empty AXWebArea after AXManualAccessibility; set AXEnhancedUserInterface=\(describe(err))"
        kept.usedEnhanced = true
        usleep(250_000)
        var boxes: [LayoutBox] = []
        var nextId = 0
        for q in windowQuartz {
            let collected = walkWindow(app: app, windowQuartz: q, startId: nextId)
            nextId += collected.count
            boxes.append(contentsOf: collected)
        }
        kept.boxes = boxes
        kept.chromiumNeedsRetry = false
        return kept
    }


    // MARK: - Enablement helpers

    /// Chromium *browsers* only — not Electron apps, which honor AXManualAccessibility.
    static func isChromiumBrowser(_ bundleId: String) -> Bool {
        let id = bundleId.lowercased()
        if id.hasPrefix("com.google.chrome") { return true }
        if id.hasPrefix("com.brave.browser") { return true }
        if id.hasPrefix("com.microsoft.edgemac") { return true }
        if id.hasPrefix("com.operasoftware.opera") { return true }
        if id.hasPrefix("com.vivaldi") { return true }
        if id.hasPrefix("company.thebrowser.browser") { return true } // Arc
        if id.hasPrefix("org.chromium.chromium") { return true }
        if id.hasPrefix("com.dia.browser") { return true }
        if id == "org.mozilla.firefox" { return false }
        return false
    }

    @discardableResult
    static func setBoolAttr(_ el: AXUIElement, _ name: String, _ value: Bool) -> AXError {
        AXUIElementSetAttributeValue(el, name as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    static func describe(_ err: AXError) -> String {
        err == .success ? "ok" : "err\(err.rawValue)"
    }

    static func label(_ pid: pid_t, _ bundles: [pid_t: String], _ names: [pid_t: String]) -> String {
        let b = bundles[pid] ?? ""
        if !b.isEmpty { return b }
        let n = names[pid] ?? ""
        return n.isEmpty ? "pid\(pid)" : n
    }

    /// nil = no AXWebArea found; true/false = whether it has children.
    static func webAreaPopulated(_ app: AXUIElement) -> Bool? {
        var budget = 800
        guard let web = firstWebArea(app, depth: 0, budget: &budget) else { return nil }
        return !children(web).isEmpty
    }

    static func firstWebArea(_ el: AXUIElement, depth: Int, budget: inout Int) -> AXUIElement? {
        if budget <= 0 || depth > 14 { return nil }
        budget -= 1
        if role(el) == "AXWebArea" { return el }
        for c in children(el) {
            if let w = firstWebArea(c, depth: depth + 1, budget: &budget) { return w }
        }
        return nil
    }

    // MARK: - Walk

    static func walkWindow(app: AXUIElement, windowQuartz: CGRect, startId: Int) -> [LayoutBox] {
        let root = matchingWindow(app: app, windowQuartz: windowQuartz) ?? app
        let windowAppKit = appKitRect(fromQuartz: windowQuartz)
        var out: [LayoutBox] = []
        var visited = 0

        func walk(_ el: AXUIElement, depth: Int) {
            if visited >= maxNodesPerWindow || depth > maxDepth { return }
            visited += 1
            let r = role(el)
            if !shouldSkipRole(r), let f = frame(el) {
                let clipped = f.intersection(windowQuartz)
                if LayoutGeometry.isPlausible(clipped), clipped.intersects(windowQuartz) {
                    let appKit = appKitRect(fromQuartz: clipped)
                    if LayoutGeometry.isPlausible(appKit) {
                        let roleName = r.isEmpty ? "Group" : r
                        // Tiny text scraps are not kept; larger text leaves may
                        // still enter the tree but are never snap targets.
                        let tinyText = LayoutGeometry.isTextLeaf(roleName)
                            && (appKit.width < LayoutGeometry.minSnapEdge
                                || appKit.height < LayoutGeometry.minSnapEdge)
                        if !tinyText {
                            out.append(LayoutBox(
                                id: startId + out.count,
                                appKitFrame: appKit,
                                windowAppKit: windowAppKit,
                                role: roleName,
                                title: title(el),
                                source: .ax,
                                confidence: 1,
                                parentId: nil
                            ))
                        }
                    }
                }
            }
            for c in children(el) {
                walk(c, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return out
    }

    static func shouldSkipRole(_ role: String) -> Bool {
        switch role {
        case "AXApplication", "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem",
             "AXHelpTag", "AXGrowArea":
            return true
        default:
            return false
        }
    }

    static func matchingWindow(app: AXUIElement, windowQuartz: CGRect) -> AXUIElement? {
        guard let wins = copyAttr(app, kAXWindowsAttribute as String) as? [AXUIElement] else { return nil }
        var best: (AXUIElement, CGFloat)?
        for w in wins {
            guard let f = frame(w) else { continue }
            let inter = f.intersection(windowQuartz)
            let area = inter.width * inter.height
            let union = f.union(windowQuartz)
            let iou = area / max(1, union.width * union.height)
            let originDist = hypot(f.origin.x - windowQuartz.origin.x, f.origin.y - windowQuartz.origin.y)
            let sizeDist = hypot(f.width - windowQuartz.width, f.height - windowQuartz.height)
            let score = iou * 1000 - originDist - sizeDist * 0.25
            if best == nil || score > best!.1 { best = (w, score) }
        }
        return best?.0
    }

    // MARK: - AX attribute helpers

    static func copyAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success else { return nil }
        return ref
    }

    static func role(_ el: AXUIElement) -> String {
        (copyAttr(el, kAXRoleAttribute as String) as? String) ?? ""
    }

    static func title(_ el: AXUIElement) -> String {
        if let t = copyAttr(el, kAXTitleAttribute as String) as? String, !t.isEmpty { return t }
        if let t = copyAttr(el, kAXDescriptionAttribute as String) as? String, !t.isEmpty { return t }
        if let t = copyAttr(el, kAXValueAttribute as String) as? String, !t.isEmpty {
            return String(t.prefix(40))
        }
        return ""
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        if let posRef = copyAttr(el, kAXPositionAttribute as String),
           let sizeRef = copyAttr(el, kAXSizeAttribute as String) {
            var pos = CGPoint.zero, size = CGSize.zero
            let posOK = AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
            let sizeOK = AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            if posOK && sizeOK && size.width.isFinite && size.height.isFinite {
                return CGRect(origin: pos, size: size)
            }
        }
        if let frameRef = copyAttr(el, "AXFrame"), CFGetTypeID(frameRef) == AXValueGetTypeID() {
            var r = CGRect.zero
            if AXValueGetValue(frameRef as! AXValue, .cgRect, &r) { return r }
        }
        return nil
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func add(_ arr: [AXUIElement]?) {
            guard let arr = arr else { return }
            for c in arr {
                if !out.contains(where: { CFEqual($0, c) }) {
                    out.append(c)
                }
            }
        }
        add(copyAttr(el, kAXChildrenAttribute as String) as? [AXUIElement])
        add(copyAttr(el, kAXVisibleChildrenAttribute as String) as? [AXUIElement])
        add(copyAttr(el, "AXContents") as? [AXUIElement])
        return out
    }
}

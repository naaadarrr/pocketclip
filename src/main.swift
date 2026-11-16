import AppKit
import WebKit
import AVFoundation
import Carbon.HIToolbox
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

var T0 = CACurrentMediaTime()
let pcLogURL: URL = {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pocketclip/perf.log")
    try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    return u
}()
func tlog(_ s: String) {
    let ms = (CACurrentMediaTime() - T0) * 1000
    NSLog("PC T+%4.0fms %@", ms, s)
    let line = String(format: "PC T+%4.0fms %@\n", ms, s)
    let existing = (try? String(contentsOf: pcLogURL, encoding: .utf8)) ?? ""
    try? (existing + line).write(to: pcLogURL, atomically: true, encoding: .utf8)
}
let sharedPool = WKProcessPool()
let canvasBG = NSColor(srgbRed: 0x12/255.0, green: 0x13/255.0, blue: 0x14/255.0, alpha: 1)
let canvasBGLight = NSColor(srgbRed: 0xec/255.0, green: 0xea/255.0, blue: 0xe6/255.0, alpha: 1)
func canvasSolidColor() -> NSColor { gridLight ? canvasBGLight : canvasBG }
/// Fixed 960×620 pt editor window. Uniformly shrinks to 80%×85% of the screen, keeping aspect.
func editorDefaultSize(in vis: NSRect) -> NSSize {
    let defW: CGFloat = 960, defH: CGFloat = 620
    let scale = min(1, (vis.width * 0.8) / defW, (vis.height * 0.85) / defH)
    return NSSize(width: (defW * scale).rounded(), height: (defH * scale).rounded())
}
func imgInfo(_ u: URL) -> (w: CGFloat, h: CGFloat, dpr: CGFloat)? {
    guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let pw = p[kCGImagePropertyPixelWidth] as? Int, let ph = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
    let dpi = (p[kCGImagePropertyDPIWidth] as? Double) ?? 72; let dpr = max(1, CGFloat(dpi / 72))
    return (CGFloat(pw) / dpr, CGFloat(ph) / dpr, dpr) }
func L(_ k: String) -> String { NSLocalizedString(k, comment: "") }
let extDir = Bundle.main.resourceURL!.appendingPathComponent("ext")

// Native sfx player for events outside the editor page (capture). Same files, same volume 0.4.
var players: [String: AVAudioPlayer] = [:]
func warmSfx(_ names: [String] = ["capture"]) {
    for n in names {
        if players[n] != nil { continue }
        guard let p = try? AVAudioPlayer(contentsOf: extDir.appendingPathComponent("assets/sfx/\(n).mp3")) else { continue }
        p.volume = 0.4; p.prepareToPlay(); players[n] = p
    }
}
func sfx(_ n: String) {
    warmSfx([n])
    players[n]?.currentTime = 0; players[n]?.play()
}

enum Mode { case region, window, screen
    var args: [String] { switch self { case .region: return ["-i","-x"]; case .window: return ["-i","-w","-x"]; case .screen: return ["-x"] } } }

/// In-process fullscreen capture (ScreenCaptureKit) for the display under the mouse.
@available(macOS 14.0, *)
func captureScreenSCK() async throws -> URL {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let mouse = NSEvent.mouseLocation
    let scr = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    let num = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    let displayID = CGDirectDisplayID(num?.uint32Value ?? CGMainDisplayID())
    guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
        throw NSError(domain: "Pocketclip", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"])
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    // SCDisplay width/height can be points on some OS builds; force pixel size via backingScaleFactor.
    let scale = scr.backingScaleFactor
    let pw = max(display.width, Int((scr.frame.width * scale).rounded()))
    let ph = max(display.height, Int((scr.frame.height * scale).rounded()))
    config.width = pw
    config.height = ph
    config.showsCursor = true
    config.colorSpaceName = CGColorSpace.sRGB
    NSLog("PC sck target %dx%d scale=%.1f display=%dx%d", pw, ph, scale, display.width, display.height)
    let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "Pocketclip", code: 2, userInfo: [NSLocalizedDescriptionKey: "png dest"])
    }
    let dpi = 72.0 * Double(scr.backingScaleFactor)
    let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(dest, cg, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "Pocketclip", code: 3, userInfo: [NSLocalizedDescriptionKey: "png write"])
    }
    return url
}

func captureViaTool(_ m: Mode, done: @escaping (URL?) -> Void) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString).png")
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = m.args + [url.path]
    p.terminationHandler = { _ in DispatchQueue.main.async { done(FileManager.default.fileExists(atPath: url.path) ? url : nil) } }
    try? p.run()
}

func capture(_ m: Mode, done: @escaping (URL?) -> Void) {
    if m == .region {
        // Smart region picker (AX snap + freeform drag). Not screencapture -i.
        tlog("region picker begin")
        RegionPicker.begin(done: done)
        return
    }
    if m == .screen {
        if #available(macOS 14.0, *) {
            Task {
                let t = CACurrentMediaTime()
                do {
                    let u = try await captureScreenSCK()
                    let ms = (CACurrentMediaTime() - t) * 1000
                    await MainActor.run {
                        tlog(String(format: "capture done (sck %.0fms)", ms))
                        done(u)
                    }
                } catch {
                    await MainActor.run {
                        tlog("sck failed: \(error.localizedDescription); falling back to screencapture")
                        captureViaTool(m, done: done)
                    }
                }
            }
            return
        }
    }
    captureViaTool(m, done: done)
}

/// Tiny 1×1 PNG used to prewarm the editor page at launch without a real shot.
func placeholderPNG() -> URL {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pocketclip/placeholder.png")
    if !FileManager.default.fileExists(atPath: u.path) {
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 1x1 black PNG
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        try? Data(base64Encoded: b64)?.write(to: u)
    }
    return u
}

func shim(dataURL: String, dpr: CGFloat, cssW: Int, cssH: Int, histTip: String, emptyTip: String, hasHist: Bool) -> String {
  let reduceTrans = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
  return """
(() => {
  const store = { screenshotDataUrl: \(jsonStr(dataURL)), screenshotDpr: \(dpr), screenshotCssWidth: \(cssW), screenshotCssHeight: \(cssH) };
  const noop = { addListener() {}, removeListener() {} };
  const base = location.href.replace(/editor\\/editor\\.html.*$/, "");
  window.chrome = {
    runtime: { lastError: undefined, getURL: p => base + p, onMessage: noop, sendMessage() {} },
    storage: { onChanged: noop, local: {
      get(keys, cb) { const r = {}; (Array.isArray(keys) ? keys : [keys]).forEach(k => { if (k in store) r[k] = store[k]; }); if (cb) { cb(r); } return Promise.resolve(r); },
      set(o, cb) { Object.assign(store, o); cb && cb(); return Promise.resolve(); },
      remove(keys, cb) { cb && cb(); return Promise.resolve(); } } }
  };
  const post = (type, data) => window.webkit.messageHandlers.pc.postMessage({ type, data });
  const toDataURL = b => new Promise(res => { const fr = new FileReader(); fr.onload = () => res(fr.result); fr.readAsDataURL(b); });
  const cw = {
    async write(items) { const b = await items[0].getType("image/png"); post("copy", await toDataURL(b)); },
    async writeText(text) { post("copyText", String(text ?? "")); return Promise.resolve(); }
  };
  try { Object.defineProperty(navigator, "clipboard", { value: cw, configurable: true }); } catch (_) {}
  window.pcUI = { eyedropper: \(jsonStr(L("editor.eyedropper"))), copied: \(jsonStr(L("history.copied"))) };
  const st = document.createElement("style");
  st.textContent = ".topbar{padding:0 16px 0 92px !important;height:52px;box-sizing:border-box;border-radius:0 0 14px 14px}";
  document.documentElement.appendChild(st);
  const oc = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () { if (this.download) { post("save", this.href); return; } return oc.call(this); };
  // History button (left of Copy) + ⌘Y
  const histTip = \(jsonStr(histTip)), emptyTip = \(jsonStr(emptyTip)), backLabel = \(jsonStr(L("editor.back")));
  st.textContent += ".pc-hist{width:32px!important;padding:0!important;border-radius:50%!important}.pc-hist svg{width:18px;height:18px}.pc-back[hidden],.pc-hist[hidden]{display:none!important}.pc-back,.pc-back:hover,.pc-back:active{background:none!important;box-shadow:none!important;border:none!important;padding:0!important;width:28px!important;min-width:28px!important;margin-right:4px;color:rgba(255,255,255,.62)!important;transition:color .12s}.pc-back:hover{color:#fff!important}.pc-hist.is-empty{opacity:.38;cursor:default}.pc-hist.is-active{background:linear-gradient(180deg,#4a4a50 0%,#424248 45%,#3e3e44 100%)!important;box-shadow:inset 0 1px 0 rgba(255,255,255,.3),0 0 0 1px rgba(255,255,255,.22)!important}";
  window.pcSetHistory = has => { const b = document.getElementById("btn-pc-history"); if (!b) return; b.classList.toggle("is-empty", !has); b.setAttribute("data-tooltip", has ? histTip : emptyTip); b.dataset.has = has ? "1" : ""; };
  st.textContent += "body.pc-history #stage,body.pc-history .draw-toolbar,body.pc-history #crop-box{visibility:hidden!important}body.pc-history,body.pc-history #stage-wrap{background:transparent!important;background-image:none!important}";
  window.pcSetHistActive = on => { document.body.classList.toggle("pc-history", on); const b = document.getElementById("btn-pc-history"); if (b) b.classList.toggle("is-active", on);
    const k = document.getElementById("btn-pc-back"), m = document.getElementById("view-meta"); if (k) k.hidden = !on; if (b) b.hidden = on;
    if (m) { if (on) { if (m.dataset.pcOrig === undefined) m.dataset.pcOrig = m.textContent; m.textContent = window.pcHistLabel || ""; } else if (m.dataset.pcOrig !== undefined) { m.textContent = m.dataset.pcOrig; delete m.dataset.pcOrig; } } };
  // Opening the editor must not leave History selected or show its tooltip/toast.
  window.pcIdleHistoryButton = () => { if (document.body.classList.contains("pc-history")) return; const b = document.getElementById("btn-pc-history"); if (!b) return; b.classList.remove("is-active"); if (document.activeElement === b) b.blur(); };
  window.pcSetReduceTransparency = on => { document.documentElement.classList.toggle("pc-reduce-transparency", !!on); if (document.body) document.body.classList.toggle("pc-reduce-transparency", !!on); };
  window.pcSetReduceTransparency(\(reduceTrans));
  const openHist = () => { const b = document.getElementById("btn-pc-history"); if (b && b.dataset.has) post("history", ""); };
  document.addEventListener("DOMContentLoaded", () => {
    const sg = document.getElementById("stage"); if (sg) { const ck = () => { if (sg.classList.contains("is-ready")) { post("ready", ""); mo.disconnect(); } }; const mo = new MutationObserver(ck); mo.observe(sg, { attributes: true, attributeFilter: ["class"] }); ck(); }
    const rep = () => post("theme", document.body.dataset.theme || "dark"); rep();
    new MutationObserver(rep).observe(document.body, { attributes: true, attributeFilter: ["data-theme"] });
    const copy = document.getElementById("btn-copy"); if (!copy) return;
    const b = document.createElement("button"); b.type = "button"; b.id = "btn-pc-history"; b.className = "top-btn pc-hist"; b.setAttribute("data-tip", "bottom"); b.setAttribute("aria-label", "History");
    b.innerHTML = '<svg class="top-btn__icon top-btn__icon--fill" viewBox="0 0 256 256" fill="currentColor" aria-hidden="true"><path d="M134,80v44.6l37.09,22.25a6,6,0,0,1-6.18,10.3l-40-24A6,6,0,0,1,122,128V80a6,6,0,0,1,12,0Zm-6-46A93.4,93.4,0,0,0,61.51,61.56c-8.58,8.68-16,17-23.51,25.8V64a6,6,0,0,0-12,0v40a6,6,0,0,0,6,6H72a6,6,0,0,0,0-12H44.73C52.86,88.29,60.79,79.35,70,70a82,82,0,1,1,1.7,117.62,6,6,0,1,0-8.24,8.72A94,94,0,1,0,128,34Z"></path></svg>';
    b.addEventListener("click", e => { if (e.isTrusted) openHist(); }); copy.parentNode.insertBefore(b, copy);
    const k = document.createElement("button"); k.type = "button"; k.id = "btn-pc-back"; k.className = "top-btn pc-back"; k.hidden = true; k.setAttribute("aria-label", backLabel);
    k.innerHTML = '<svg class="top-btn__icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 12H5"/><path d="M11 6l-6 6 6 6"/></svg>'; k.setAttribute("data-tooltip", backLabel + "  Esc"); k.setAttribute("data-tip", "bottom"); k.addEventListener("click", e => { if (e.isTrusted) post("back", ""); });
    const meta = document.getElementById("view-meta"); meta.parentNode.insertBefore(k, meta); window.pcSetHistory(\(hasHist));
    window.pcIdleHistoryButton(); requestAnimationFrame(() => window.pcIdleHistoryButton && pcIdleHistoryButton());
  });
  document.addEventListener("keydown", e => { if (e.metaKey && !e.shiftKey && !e.altKey && e.key.toLowerCase() === "y") { e.preventDefault(); e.stopPropagation(); openHist(); } }, true);
  // Autosave annotated version: base (#canvas) + strokes (#draw), 0.5s after the last edit.
  let t = 0, last = "";
  const save = () => { const a = document.getElementById("canvas"), d = document.getElementById("draw"); if (!a || !d || !a.width) return;
    const o = document.createElement("canvas"); o.width = a.width; o.height = a.height; const x = o.getContext("2d"); x.drawImage(a, 0, 0); x.drawImage(d, 0, 0, a.width, a.height);
    const u = o.toDataURL("image/png"); if (last && u !== last) post("autosave", u); last = u; };
  const kick = () => { clearTimeout(t); t = setTimeout(save, 500); };
  ["mouseup", "pointerup", "keyup", "click"].forEach(ev => document.addEventListener(ev, kick, true));
  window.addEventListener("load", () => setTimeout(save, 800));
})();
"""
}
func jsonStr(_ s: String) -> String { String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!.dropFirst().dropLast().description }

// Drag the window from the top bar's empty area (left/middle); the right side holds Clear/Copy/Download.
final class DragWebView: WKWebView {
    static let barH: CGFloat = 52, buttonsW: CGFloat = 390
    // History back arrow sits just after the traffic-light inset (padding-left 92, width 28).
    // Clicks there must reach the page instead of starting a window drag.
    var historyBackEnabled = false
    static let backMinX: CGFloat = 86
    static let backMaxX: CGFloat = 140
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let fromTop = isFlipped ? p.y : bounds.height - p.y
        if fromTop < Self.barH && p.x < bounds.width - Self.buttonsW {
            if historyBackEnabled && p.x >= Self.backMinX && p.x < Self.backMaxX {
                super.mouseDown(with: e)
                return
            }
            if e.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: e) }
            return
        }
        super.mouseDown(with: e)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    // History grid is behind this view so the back-arrow tooltip can paint over the cards.
    // Clicks below the top bar must fall through to the grid.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if historyBackEnabled {
            let local = convert(point, from: superview)
            let fromTop = isFlipped ? local.y : bounds.height - local.y
            if fromTop >= Self.barH { return nil }
        }
        return super.hitTest(point)
    }
}
final class Editor: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    let panel: NSPanel; let web: WKWebView; var onLoad: (() -> Void)?; var home: NSScreen
    var histURL: URL?; var keepFrame = false; var startInHistory = false; var onPick: ((URL) -> Void)?
    var pageReady = false; var terminated = false; var swapGen = 0
    let root = NSView(); let fx = NSVisualEffectView()
    lazy var grid = HistoryGrid(open: { [weak self] u in self?.present(u, hist: u); self?.setHistory(false) }, close: { [weak self] in self?.setHistory(false) })
    var inHistory: Bool { !grid.isHidden && grid.superview != nil }
    func setHistory(_ on: Bool) {
        if on && History.items().isEmpty { return }
        if grid.superview == nil {
            grid.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: root.bounds.height - DragWebView.barH)
            grid.autoresizingMask = [.width, .height]
            // Behind the webview: HTML tooltips in the top bar can hang over the cards.
            root.addSubview(grid, positioned: .below, relativeTo: web)
        }
        grid.isHidden = !on
        paintHistoryGrid()
        applyCanvasBackdrop()
        if on { grid.reload(); panel.makeFirstResponder(grid) } else { panel.makeFirstResponder(web) }
        (web as? DragWebView)?.historyBackEnabled = on
        let label = String(format: L("history.count"), History.items().count)
        web.evaluateJavaScript("window.pcHistLabel = \(jsonStr(label)); window.pcSetHistActive && pcSetHistActive(\(on))")
    }
    /// Keep the History clock idle/unfocused so opening the editor does not show its tip.
    func idleHistoryButton() {
        guard !inHistory, !startInHistory else { return }
        web.evaluateJavaScript("window.pcIdleHistoryButton && pcIdleHistoryButton()")
    }
    /// History grid sits behind the transparent WKWebView so top-bar tooltips can overlay cards.
    /// Frost mode: clear so the same .titlebar vibrancy shows through as the editor home.
    /// Reduce Transparency: same solid fallback as the editor canvas.
    func paintHistoryGrid() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if reduce {
            grid.layer?.backgroundColor = canvasSolidColor().cgColor
            grid.layer?.isOpaque = true
        } else {
            grid.layer?.backgroundColor = NSColor.clear.cgColor
            grid.layer?.isOpaque = false
        }
    }
    func load(_ image: URL, hist: URL?) {
        histURL = hist; let image = hist.map(History.best) ?? image
        guard let info = imgInfo(image) else { return }
        pageReady = false; terminated = false
        let uc = web.configuration.userContentController; uc.removeAllUserScripts()
        uc.addUserScript(WKUserScript(source: shim(dataURL: image.absoluteString, dpr: info.dpr, cssW: Int(info.w), cssH: Int(info.h), histTip: L("editor.history"), emptyTip: L("editor.history.empty"), hasHist: !History.items().isEmpty), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.loadFileURL(URL(string: "editor/editor.html?capturing=1", relativeTo: extDir)!.absoluteURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }
    /// Swap image in the already-loaded page (no navigation). Falls back to full load if JS bridge missing.
    func swap(_ image: URL, hist: URL?) {
        histURL = hist; let image = hist.map(History.best) ?? image
        guard let info = imgInfo(image) else { return }
        tlog("swap image")
        // Fire-and-forget: pcLoadShot is async and posts "ready" itself. Returning a Promise
        // to evaluateJavaScript often surfaces WKError code 5 even on success.
        let js = """
        (function(){
          if (typeof pcLoadShot !== 'function') return 'missing';
          pcLoadShot(\(jsonStr(image.absoluteString)), \(info.dpr), \(Int(info.w)), \(Int(info.h)));
          return 'ok';
        })()
        """
        let shot = image; let h = hist
        web.evaluateJavaScript(js) { [weak self] r, err in
            if let err = err {
                NSLog("PC swap js err %@ — reloading", "\(err)")
                self?.pageReady = false
                self?.load(shot, hist: h)
                return
            }
            if (r as? String) == "missing" {
                NSLog("PC swap missing pcLoadShot — reloading")
                self?.pageReady = false
                self?.load(shot, hist: h)
            }
        }
        // Safety net: if ready never arrives, reload once.
        self.swapGen += 1; let gen = self.swapGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, self.swapGen == gen, !self.revealed, self.panel.isVisible else { return }
            NSLog("PC swap timeout — reloading")
            self.pageReady = false
            self.load(shot, hist: h)
        }
    }
    func layoutWindow(preferMouseScreen: Bool) {
        if preferMouseScreen {
            let mouse = NSEvent.mouseLocation
            home = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        }
        let vis = home.visibleFrame
        let sz = editorDefaultSize(in: vis)
        if !keepFrame {
            panel.setFrame(NSRect(x: vis.midX - sz.width/2, y: vis.midY - sz.height/2, width: sz.width, height: sz.height), display: false)
        }
    }
    func recenter() { if keepFrame { return }; let v = home.visibleFrame, f = panel.frame; panel.setFrameOrigin(NSPoint(x: (v.midX - f.width/2).rounded(), y: (v.midY - f.height/2).rounded())) }
    /// Present a shot: reuse the live page when possible; hide→show with fade-in after paint.
    func present(_ image: URL, hist: URL? = nil, frame: NSRect? = nil) {
        if inHistory { setHistory(false) }
        idleHistoryButton()
        revealed = false
        panel.alphaValue = 0
        if let f = frame { panel.setFrame(f, display: false); keepFrame = true }
        else { keepFrame = false }
        let resolved = hist.map(History.best) ?? image
        layoutWindow(preferMouseScreen: frame == nil)
        if pageReady { swap(resolved, hist: hist) } else { load(resolved, hist: hist) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless()
        recenter()
        DispatchQueue.main.async { [weak self] in self?.recenter() }
        tlog("panel shown (reuse=\(pageReady ? 1 : 0))")
        NSLog("PC editor frame %@ screen %@", NSStringFromRect(panel.frame), panel.screen?.localizedName ?? "nil")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.reveal("fallback") }
    }
    func hide() {
        panel.orderOut(nil)
        panel.alphaValue = 0
        revealed = false
        tlog("panel hidden (kept alive)")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func windowDidBecomeKey(_ notification: Notification) { idleHistoryButton() }
    /// Build the single long-lived editor (panel + WKWebView). Call warm() at launch to preload the page.
    override init() {
        tlog("editor init (singleton)")
        let cfg = WKWebViewConfiguration(); cfg.processPool = sharedPool
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let mouse = NSEvent.mouseLocation
        let scr = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = scr.visibleFrame; home = scr
        let sz = editorDefaultSize(in: vis)
        web = DragWebView(frame: NSRect(origin: .zero, size: sz), configuration: cfg)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: sz), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        cfg.userContentController.add(self, name: "pc")
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        if web.layer != nil { web.layer?.isOpaque = false; web.layer?.backgroundColor = NSColor.clear.cgColor }
        let tb = NSToolbar(identifier: "pc"); tb.showsBaselineSeparator = false; panel.toolbar = tb; panel.toolbarStyle = .unified
        panel.titlebarSeparatorStyle = .none; panel.backgroundColor = .clear; panel.isOpaque = false; panel.alphaValue = 0; panel.appearance = NSAppearance(named: .darkAqua)
        panel.titlebarAppearsTransparent = true; panel.titleVisibility = .hidden; panel.level = .floating
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        root.frame = NSRect(origin: .zero, size: sz)
        fx.frame = root.bounds; fx.autoresizingMask = [.width, .height]
        fx.blendingMode = .behindWindow; fx.material = .titlebar; fx.state = .active
        fx.appearance = NSAppearance(named: .darkAqua)
        web.frame = root.bounds; web.autoresizingMask = [.width, .height]
        root.addSubview(fx); root.addSubview(web); panel.contentView = root
        applyCanvasBackdrop()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(canvasDisplayOptionsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        panel.setFrame(NSRect(x: vis.midX - sz.width/2, y: vis.midY - sz.height/2, width: sz.width, height: sz.height), display: false)
    }
    /// Frosted canvas behind the letterbox and History. Hidden only when Reduce Transparency is on.
    func applyCanvasBackdrop() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let solid = canvasSolidColor()
        if reduce {
            panel.isOpaque = true
            panel.backgroundColor = solid
            fx.isHidden = true
            // History is viewed through a transparent WKWebView; keep under-page clear
            // so the grid's solid fallback (and cards) remain visible.
            web.underPageBackgroundColor = inHistory ? .clear : solid
        } else {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            fx.isHidden = false
            // Mid-weight frost: more veil than .hudWindow, lighter than .headerView.
            fx.material = .titlebar
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.appearance = NSAppearance(named: gridLight ? .aqua : .darkAqua)
            web.underPageBackgroundColor = .clear
        }
        web.evaluateJavaScript("window.pcSetReduceTransparency && pcSetReduceTransparency(\(reduce))")
        if inHistory { paintHistoryGrid() }
    }
    @objc func canvasDisplayOptionsChanged(_ notification: Notification) { applyCanvasBackdrop() }
    /// Preload editor.html so the first real capture only swaps the image.
    func warm() {
        let ph = placeholderPNG()
        tlog("editor warm start")
        load(ph, hist: nil)
    }
    var revealed = false
    func reveal(_ why: String) {
        if revealed { return }
        guard panel.isVisible else { tlog("reveal deferred (not visible, \(why))"); return }
        revealed = true; tlog("reveal (\(why))")
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.12; panel.animator().alphaValue = 1 }
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        tlog("didFinish"); pageReady = true; recenter(); keepFrame = true
        if startInHistory || inHistory { reveal("didFinish") }
        if startInHistory { startInHistory = false; setHistory(true) }
        if inHistory { web.evaluateJavaScript("pcSetHistActive(true)") }
        onLoad?()
    }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { NSLog("PC fail %@", "\(e)"); pageReady = false; onLoad?() }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { NSLog("PC fail %@", "\(e)"); pageReady = false; onLoad?() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("PC web content terminated — will rebuild on next present")
        pageReady = false; terminated = true
    }
    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        if let b = msg.body as? [String: String], b["type"] == "ready" { tlog("image rendered"); pageReady = true; reveal("ready")
            idleHistoryButton()
            if ProcessInfo.processInfo.environment["PC_TAINT"] != nil { web.evaluateJavaScript("(()=>{try{return document.querySelector('canvas').toDataURL().length}catch(e){return 'ERR '+e}})()") { r, _ in NSLog("PC taint check %@", "\(r ?? "nil")") } }
            return }
        if let b = msg.body as? [String: String], b["type"] == "history" { NSLog("PC msg history (in=%d)", inHistory ? 1 : 0); setHistory(!inHistory); return }
        if let b = msg.body as? [String: String], b["type"] == "back" { setHistory(false); return }
        if let b = msg.body as? [String: String], b["type"] == "theme" { let l = b["data"] == "light"; if l != gridLight { gridLight = l; applyCanvasBackdrop(); if inHistory { paintHistoryGrid(); grid.reload() } }; return }
        // Text copy (eyedropper). Must not close the editor — only the main Copy button does.
        if let b = msg.body as? [String: String], b["type"] == "copyText", let s = b["data"] {
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(s, forType: .string)
            return
        }
        guard let b = msg.body as? [String: String], let s = b["data"], let i = s.range(of: "base64,"), let png = Data(base64Encoded: String(s[i.upperBound...])) else { return }
        if b["type"] == "autosave" { if let h = histURL { try? png.write(to: History.annotated(h)); NotificationCenter.default.post(name: History.changed, object: nil) }; return }
        if b["type"] == "copy" {
            let pb = NSPasteboard.general; pb.clearContents(); pb.setData(png, forType: .png)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.hide() }
            return
        }
        if b["type"] == "save" {
            ExportFile.present(over: panel, write: { url in try png.write(to: url) }) { ok in
                if ok { sfx("done") }
            }
        }
    }
    func snapshot(to path: String, done: @escaping () -> Void) {
        web.takeSnapshot(with: nil) { img, _ in
            let fv = self.panel.contentView!.superview!
            let out = NSImage(size: fv.bounds.size); out.lockFocus()
            NSColor.black.setFill(); fv.bounds.fill()
            img?.draw(in: self.web.frame)
            if self.inHistory, let rep = self.grid.bitmapImageRepForCachingDisplay(in: self.grid.bounds) {
                self.grid.cacheDisplay(in: self.grid.bounds, to: rep); rep.draw(in: self.grid.convert(self.grid.bounds, to: fv)) }
            for t in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let btn = self.panel.standardWindowButton(t), let rep = btn.bitmapImageRepForCachingDisplay(in: btn.bounds) else { continue }
                btn.cacheDisplay(in: btn.bounds, to: rep)
                let r = btn.convert(btn.bounds, to: fv)
                rep.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            out.unlockFocus()
            let img: NSImage? = out
            if let t = img?.tiffRepresentation, let p = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) { try? p.write(to: URL(fileURLWithPath: path)) }
            done()
        }
    }
}


// MARK: - Export: native save panel for Download (editor top bar + history).
enum ExportFile {
    static let lastDirKey = "lastExportDirectory"
    static var busy = false
    static func suggestedName() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return "screenshot-\(f.string(from: Date())).png"
    }
    static func directory() -> URL {
        if let p = UserDefaults.standard.string(forKey: lastDirKey) {
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &dir), dir.boolValue {
                return URL(fileURLWithPath: p, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
    static func present(over window: NSWindow?, write: @escaping (URL) throws -> Void, done: ((Bool) -> Void)? = nil) {
        if busy { return }
        busy = true
        let sp = NSSavePanel()
        sp.allowedContentTypes = [.png]
        sp.canCreateDirectories = true
        sp.isExtensionHidden = false
        sp.nameFieldStringValue = suggestedName()
        sp.directoryURL = directory()
        let finish: (NSApplication.ModalResponse) -> Void = { r in
            defer { busy = false; if let p = window as? NSPanel { p.worksWhenModal = true } }
            guard r == .OK, let url = sp.url else { done?(false); return }
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try write(url)
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: lastDirKey)
                done?(true)
            } catch {
                NSLog("PC export failed %@", "\(error)")
                done?(false)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window, window.isVisible {
            if let p = window as? NSPanel { p.worksWhenModal = false }
            window.makeKeyAndOrderFront(nil)
            sp.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(sp.runModal())
        }
    }
}

// MARK: - History: raw PNG of every capture, newest 100 kept.
enum History {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pocketclip/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }()
    static let limit = 100
    static let changed = Notification.Name("PCHistoryChanged")
    static func annotated(_ u: URL) -> URL { u.deletingPathExtension().appendingPathExtension("annotated.png") }
    @discardableResult static func save(_ src: URL) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let d = dir.appendingPathComponent("\(f.string(from: Date())).png"); try? FileManager.default.copyItem(at: src, to: d); prune(); return d
    }
    static func items() -> [(url: URL, date: Date)] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "png" && !$0.lastPathComponent.hasSuffix(".annotated.png") }
            .map { u in (u, (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent > $1.0.lastPathComponent }
    }
    static func remove(_ u: URL) { try? FileManager.default.removeItem(at: u); try? FileManager.default.removeItem(at: annotated(u)) }
    static func best(_ u: URL) -> URL { let a = annotated(u); return FileManager.default.fileExists(atPath: a.path) ? a : u }
    static func prune() { for it in items().dropFirst(limit) { remove(it.url) } }
    static func copy(_ u: URL) {
        guard let d = try? Data(contentsOf: u) else { return }
        let pb = NSPasteboard.general; pb.clearContents(); pb.setData(d, forType: .png)
        if let img = NSImage(data: d) { pb.writeObjects([img]) }
    }
}

/// Scale a Phosphor-regular SVG path (256 viewBox) into an AppKit fill path.
func phosphorIconPath(_ d: String, origin: NSPoint, size: CGFloat, viewBox: CGFloat = 256) -> NSBezierPath {
    let s = size / viewBox
    func T(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: origin.x + x * s, y: origin.y + y * s) }
    let path = NSBezierPath()
    path.windingRule = .evenOdd
    var i = d.startIndex
    func skipSep() {
        while i < d.endIndex {
            let c = d[i]
            if c == "," || c == " " || c == "\t" || c == "\n" || c == "\r" { i = d.index(after: i) } else { break }
        }
    }
    func peek() -> Character? { skipSep(); return i < d.endIndex ? d[i] : nil }
    func readNum() -> CGFloat {
        skipSep()
        let start = i
        if i < d.endIndex, d[i] == "+" || d[i] == "-" { i = d.index(after: i) }
        while i < d.endIndex, d[i] >= "0", d[i] <= "9" { i = d.index(after: i) }
        if i < d.endIndex, d[i] == "." {
            let n = d.index(after: i)
            if n < d.endIndex, d[n] >= "0", d[n] <= "9" {
                i = n
                while i < d.endIndex, d[i] >= "0", d[i] <= "9" { i = d.index(after: i) }
            }
        }
        if i < d.endIndex, d[i] == "e" || d[i] == "E" {
            i = d.index(after: i)
            if i < d.endIndex, d[i] == "+" || d[i] == "-" { i = d.index(after: i) }
            while i < d.endIndex, d[i] >= "0", d[i] <= "9" { i = d.index(after: i) }
        }
        return CGFloat(Double(d[start..<i]) ?? 0)
    }
    func isNumStart(_ c: Character) -> Bool { c == "+" || c == "-" || c == "." || (c >= "0" && c <= "9") }
    func appendArc(from p1: NSPoint, rx rawRx: CGFloat, ry rawRy: CGFloat, rot: CGFloat, large: Bool, sweep: Bool, to p2: NSPoint) {
        var rx = abs(rawRx), ry = abs(rawRy)
        if rx < 1e-8 || ry < 1e-8 || (abs(p1.x - p2.x) < 1e-8 && abs(p1.y - p2.y) < 1e-8) {
            path.line(to: T(p2.x, p2.y)); return
        }
        let phi = rot * .pi / 180
        let cosφ = Darwin.cos(phi), sinφ = Darwin.sin(phi)
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1p = cosφ * dx + sinφ * dy
        let y1p = -sinφ * dx + cosφ * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let k = sqrt(lambda); rx *= k; ry *= k }
        let sign: CGFloat = (large != sweep) ? 1 : -1
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = sign * sqrt(max(0, num / max(den, 1e-12)))
        let cxp = coef * (rx * y1p) / ry
        let cyp = coef * -(ry * x1p) / rx
        let cx = cosφ * cxp - sinφ * cyp + (p1.x + p2.x) / 2
        let cy = sinφ * cxp + cosφ * cyp + (p1.y + p2.y) / 2
        func vecAng(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let d = hypot(ux, uy) * hypot(vx, vy)
            var a = acos(max(-1, min(1, (ux * vx + uy * vy) / max(d, 1e-12))))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let θ1 = vecAng(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var Δθ = vecAng((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && Δθ > 0 { Δθ -= 2 * .pi }
        if sweep && Δθ < 0 { Δθ += 2 * .pi }
        let n = max(1, Int(ceil(abs(Δθ) / (.pi / 2) - 1e-6)))
        let δ = Δθ / CGFloat(n)
        let t = tan(δ / 4)
        let alpha = sin(δ) * (sqrt(4 + 3 * t * t) - 1) / 3
        var a0 = θ1
        var start = p1
        for _ in 0..<n {
            let a1 = a0 + δ
            func pt(_ a: CGFloat) -> NSPoint {
                NSPoint(
                    x: cx + rx * Darwin.cos(a) * cosφ - ry * Darwin.sin(a) * sinφ,
                    y: cy + rx * Darwin.cos(a) * sinφ + ry * Darwin.sin(a) * cosφ
                )
            }
            func tanv(_ a: CGFloat) -> (CGFloat, CGFloat) {
                (
                    -rx * Darwin.sin(a) * cosφ - ry * Darwin.cos(a) * sinφ,
                    -rx * Darwin.sin(a) * sinφ + ry * Darwin.cos(a) * cosφ
                )
            }
            let end = pt(a1)
            let (tx0, ty0) = tanv(a0)
            let (tx1, ty1) = tanv(a1)
            path.curve(
                to: T(end.x, end.y),
                controlPoint1: T(start.x + alpha * tx0, start.y + alpha * ty0),
                controlPoint2: T(end.x - alpha * tx1, end.y - alpha * ty1)
            )
            a0 = a1
            start = end
        }
    }
    var cur = NSPoint.zero, sub = NSPoint.zero, cmd: Character = "M"
    while let c = peek() {
        if c.isLetter { cmd = c; i = d.index(after: i) }
        else if cmd == "M" { cmd = "L" }
        else if cmd == "m" { cmd = "l" }
        switch cmd {
        case "M", "m":
            let rel = cmd == "m"
            let x = readNum(), y = readNum()
            cur = rel ? NSPoint(x: cur.x + x, y: cur.y + y) : NSPoint(x: x, y: y)
            path.move(to: T(cur.x, cur.y)); sub = cur
        case "L", "l":
            let rel = cmd == "l"
            let x = readNum(), y = readNum()
            cur = rel ? NSPoint(x: cur.x + x, y: cur.y + y) : NSPoint(x: x, y: y)
            path.line(to: T(cur.x, cur.y))
        case "H", "h":
            let x = readNum()
            cur.x = cmd == "h" ? cur.x + x : x
            path.line(to: T(cur.x, cur.y))
        case "V", "v":
            let y = readNum()
            cur.y = cmd == "v" ? cur.y + y : y
            path.line(to: T(cur.x, cur.y))
        case "A", "a":
            let rx = readNum(), ry = readNum(), rot = readNum()
            let large = readNum() != 0, sweep = readNum() != 0
            let x = readNum(), y = readNum()
            let dest = cmd == "a" ? NSPoint(x: cur.x + x, y: cur.y + y) : NSPoint(x: x, y: y)
            appendArc(from: cur, rx: rx, ry: ry, rot: rot, large: large, sweep: sweep, to: dest)
            cur = dest
        case "Z", "z":
            path.close(); cur = sub
        default:
            fatalError("unsupported SVG path command \(cmd)")
        }
    }
    return path
}

// Native replica of the editor's .top-btn / .top-btn--primary (editor.css): League Gothic 18px, 0.04em tracking,
// 32px high, gradient #303034→#2c2c30→#2a2a2e, inset highlights, Phosphor regular 256-unit fill icons at 16px.
let gothic: NSFont = {
    if let d = try? Data(contentsOf: extDir.appendingPathComponent("editor/fonts/LeagueGothic-latin.woff2")),
       let ds = CTFontManagerCreateFontDescriptorsFromData(d as CFData) as? [CTFontDescriptor], let f = ds.first {
        return CTFontCreateWithFontDescriptor(f, 18, nil) as NSFont }
    return NSFont(name: "Impact", size: 18) ?? .boldSystemFont(ofSize: 18) }()
final class PillButton: NSView {
    enum Kind { case copy, download }
    let kind: Kind; var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var onClick: () -> Void = {}; var hot = false { didSet { needsDisplay = true } }; var down = false { didSet { needsDisplay = true } }
    init(_ kind: Kind, _ title: String) { self.kind = kind; self.title = title; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    var pad: CGFloat { kind == .download ? 16 : 12 }; var gap: CGFloat { kind == .download ? 7 : 6 }; var radius: CGFloat { kind == .download ? 10 : 8 }
    var label: NSAttributedString { NSAttributedString(string: title, attributes: [.font: gothic, .foregroundColor: NSColor.white, .kern: 0.72]) }
    override var intrinsicContentSize: NSSize { NSSize(width: (pad * 2 + 16 + gap + label.size().width).rounded(.up), height: 32) }
    func sizeToFit() { setFrameSize(intrinsicContentSize) }
    override func updateTrackingAreas() { trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)) }
    override func mouseEntered(with e: NSEvent) { hot = true }
    override func mouseExited(with e: NSEvent) { hot = false; down = false }
    override func mouseDown(with e: NSEvent) { down = true }
    override func mouseUp(with e: NSEvent) { if down, bounds.contains(convert(e.locationInWindow, from: nil)) { onClick() }; down = false }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    func hex(_ v: Int) -> NSColor { NSColor(srgbRed: CGFloat(v >> 16 & 255)/255, green: CGFloat(v >> 8 & 255)/255, blue: CGFloat(v & 255)/255, alpha: 1) }
    override func draw(_ r: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        let (stops, top, bot): ([Int], CGFloat, CGFloat) = down ? ([0x26262a, 0x2a2a2e, 0x2e2e32], 0.14, 0.32) : hot ? ([0x38383c, 0x323236, 0x303034], 0.26, 0.26) : ([0x303034, 0x2c2c30, 0x2a2a2e], 0.22, 0.28)
        NSGradient(colors: stops.map(hex), atLocations: [0, down ? 0.55 : 0.45, 1], colorSpace: .sRGB)!.draw(in: shape, angle: 90)
        NSGraphicsContext.saveGraphicsState(); shape.addClip()
        NSColor(white: 1, alpha: top).setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSColor(white: 0, alpha: bot).setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
        // icon: Phosphor regular 256-unit paths scaled to 16px
        let ox = pad, oy = (bounds.height - 16) / 2
        let d = kind == .copy
            ? "M216,34H88a6,6,0,0,0-6,6V82H40a6,6,0,0,0-6,6V216a6,6,0,0,0,6,6H168a6,6,0,0,0,6-6V174h42a6,6,0,0,0,6-6V40A6,6,0,0,0,216,34ZM162,210H46V94H162Zm48-48H174V88a6,6,0,0,0-6-6H94V46H210Z"
            : "M222,144v64a6,6,0,0,1-6,6H40a6,6,0,0,1-6-6V144a6,6,0,0,1,12,0v58H210V144a6,6,0,0,1,12,0Zm-98.24,4.24a6,6,0,0,0,8.48,0l40-40a6,6,0,0,0-8.48-8.48L134,129.51V32a6,6,0,0,0-12,0v97.51L92.24,99.76a6,6,0,0,0-8.48,8.48Z"
        let ic = phosphorIconPath(d, origin: NSPoint(x: ox, y: oy), size: 16)
        NSColor.white.setFill(); ic.fill()
        let l = label, ls = l.size()
        l.draw(at: NSPoint(x: pad + 16 + gap, y: ((bounds.height - ls.height) / 2).rounded()))
    }
}
func setPill(_ b: PillButton, _ t: String) { b.title = t }
var forceHoverFirst = false
var gridLight = false  // mirrors editor body[data-theme]

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class HistoryCell: NSView {
    let url: URL; weak var owner: HistoryGrid?
    let thumb = NSImageView(), label = NSTextField(labelWithString: "")
    lazy var copyBtn: PillButton = { let b = PillButton(.copy, L("history.copy")); b.onClick = { [weak self] in self?.doCopy() }; return b }()
    lazy var dlBtn: PillButton = { let b = PillButton(.download, L("history.download")); b.onClick = { [weak self] in self?.doDownload() }; return b }()
    var hovering = false { didSet { copyBtn.isHidden = !hovering; dlBtn.isHidden = !hovering; applyTheme() } }
    func applyTheme() {
        if gridLight {
            layer?.backgroundColor = NSColor(white: 1, alpha: hovering ? 0.75 : 0.55).cgColor
            layer?.borderColor = NSColor(white: 0, alpha: hovering ? 0.12 : 0.06).cgColor
            label.textColor = NSColor(srgbRed: 0.27, green: 0.25, blue: 0.23, alpha: 0.8); thumb.layer?.backgroundColor = NSColor(white: 0, alpha: 0.04).cgColor
        } else {
            layer?.backgroundColor = NSColor(white: 0.085, alpha: 1).cgColor
            layer?.borderColor = NSColor(white: 1, alpha: hovering ? 0.10 : 0.05).cgColor
            label.textColor = NSColor(white: 1, alpha: 0.6); thumb.layer?.backgroundColor = NSColor(white: 0.05, alpha: 1).cgColor
        }
    }
    init(url: URL, date: Date, owner: HistoryGrid) {
        self.url = url; self.owner = owner; super.init(frame: .zero); wantsLayer = true
        layer?.cornerRadius = 10; layer?.backgroundColor = NSColor(white: 0.085, alpha: 1).cgColor; layer?.borderWidth = 1
        thumb.wantsLayer = true; thumb.layer?.cornerRadius = 7; thumb.layer?.masksToBounds = true
        thumb.imageScaling = .scaleProportionallyUpOrDown; thumb.layer?.backgroundColor = NSColor(white: 0.05, alpha: 1).cgColor
        DispatchQueue.global(qos: .userInitiated).async {
            var px = ""
            if let src = CGImageSourceCreateWithURL(History.best(url) as CFURL, nil) {
                if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any], let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int { px = "\(w)×\(h)" }
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 520, kCGImageSourceCreateThumbnailWithTransform: true]
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    let img = NSImage(cgImage: cg, size: .zero); DispatchQueue.main.async { self.thumb.image = img } }
            }
            let df = DateFormatter(); df.doesRelativeDateFormatting = true; df.dateStyle = .short; df.timeStyle = .short
            let t = df.string(from: date) + (px.isEmpty ? "" : "  ·  " + px)
            DispatchQueue.main.async { self.label.stringValue = t }
        }
        label.font = .systemFont(ofSize: 11); label.textColor = NSColor(white: 1, alpha: 0.6); label.lineBreakMode = .byTruncatingTail
        for v in [thumb, label, copyBtn, dlBtn] as [NSView] { addSubview(v) }
        let m = NSMenu()
        for (t, s) in [(L("history.copy"), #selector(doCopy)), (L("history.download"), #selector(doDownload)), (L("history.open"), #selector(doOpen)), (L("history.reveal"), #selector(doReveal))] { m.addItem(withTitle: t, action: s, keyEquivalent: "").target = self }
        m.addItem(.separator()); m.addItem(withTitle: L("history.delete"), action: #selector(doDelete), keyEquivalent: "").target = self
        m.addItem(withTitle: L("history.clear") + "…", action: #selector(doClearAll), keyEquivalent: "").target = self
        menu = m; hovering = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout(); let b = bounds
        thumb.frame = NSRect(x: 8, y: 8, width: b.width - 16, height: b.height - 36)
        label.frame = NSRect(x: 10, y: b.height - 24, width: b.width - 20, height: 16)
        for x in [copyBtn, dlBtn] { x.sizeToFit() }
        dlBtn.frame.origin = NSPoint(x: b.width - dlBtn.frame.width - 14, y: 14)
        copyBtn.frame.origin = NSPoint(x: dlBtn.frame.minX - copyBtn.frame.width - 8, y: 14)
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    func syncHover() { guard let w = window else { hovering = false; return }; hovering = (forceHoverFirst && owner?.cells.first === self) || bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil)) }
    override func mouseEntered(with e: NSEvent) { syncHover() }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseUp(with e: NSEvent) { if e.clickCount == 1, bounds.contains(convert(e.locationInWindow, from: nil)) { doOpen() } }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    @objc func doCopy() {
        History.copy(History.best(url)); sfx("capture"); flash(copyBtn, L("history.copied"), L("history.copy"))
    }
    @objc func doDownload() {
        let src = History.best(url)
        ExportFile.present(over: window, write: { dest in try Data(contentsOf: src).write(to: dest) }) { [weak self] ok in
            guard let self, ok else { return }
            sfx("done")
            flash(self.dlBtn, L("history.saved"), L("history.download"))
        }
    }
    func flash(_ b: PillButton, _ on: String, _ off: String) {
        setPill(b, on); needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { setPill(b, off); self.needsLayout = true }
    }
    @objc func doClearAll() { owner?.clearAll() }
    @objc func doOpen() { owner?.open(url) }
    @objc func doReveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @objc func doDelete() { History.remove(url); NotificationCenter.default.post(name: History.changed, object: nil); owner?.reload(); if History.items().isEmpty { owner?.close() } }
}

// In-window history grid: replaces the editor canvas below the top bar (one window for everything).
final class HistoryGrid: NSView {
    let scroll = NSScrollView(), doc = FlippedView()
    let empty = NSTextField(labelWithString: L("history.empty")), clearBtn = NSButton(), count = NSTextField(labelWithString: "")
    var cells: [HistoryCell] = []; let open: (URL) -> Void; let close: () -> Void
    init(open: @escaping (URL) -> Void, close: @escaping () -> Void) {
        self.open = open; self.close = close; super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
        count.font = .systemFont(ofSize: 12); count.textColor = NSColor(white: 1, alpha: 0.45)
        clearBtn.title = L("history.clear"); clearBtn.bezelStyle = .rounded; clearBtn.target = self; clearBtn.action = #selector(clearAll)
        empty.font = .systemFont(ofSize: 14); empty.textColor = NSColor(white: 1, alpha: 0.45); empty.alignment = .center
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = doc
        let m = NSMenu(); m.addItem(withTitle: L("history.clear"), action: #selector(clearAll), keyEquivalent: "").target = self; menu = m
        for v in [scroll, empty] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor)])
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(relayout), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(forName: History.changed, object: nil, queue: .main) { [weak self] _ in if self?.isHidden == false { self?.reload() } }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == UInt16(kVK_Escape) || (e.modifierFlags.contains(.command) && e.charactersIgnoringModifiers == "y") { close() } else { super.keyDown(with: e) }
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if !isHidden, e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "y" { close(); return true }
        return super.performKeyEquivalent(with: e)
    }
    func reload() {
        cells.forEach { $0.removeFromSuperview() }
        let its = History.items(); cells = its.map { HistoryCell(url: $0.url, date: $0.date, owner: self) }; cells.forEach(doc.addSubview)
        if forceHoverFirst { cells.first?.hovering = true }
        empty.textColor = gridLight ? NSColor(white: 0, alpha: 0.45) : NSColor(white: 1, alpha: 0.45)
        empty.isHidden = !its.isEmpty; clearBtn.isEnabled = !its.isEmpty
        count.stringValue = its.isEmpty ? "" : String(format: L("history.count"), its.count); relayout()
    }
    @objc func relayout() {
        let w = scroll.contentView.bounds.width, gap: CGFloat = 12, n = max(1, Int((w + gap) / (240 + gap)))
        let cw = ((w - gap * CGFloat(n - 1)) / CGFloat(n)).rounded(.down), ch = (cw * 0.62 + 36).rounded()
        for (i, c) in cells.enumerated() { c.frame = NSRect(x: CGFloat(i % n) * (cw + gap), y: CGFloat(i / n) * (ch + gap), width: cw, height: ch) }
        DispatchQueue.main.async { self.cells.forEach { $0.syncHover() } }
        let rows = (cells.count + n - 1) / n
        doc.frame = NSRect(x: 0, y: 0, width: w, height: max(scroll.contentView.bounds.height, CGFloat(rows) * (ch + gap)))
    }
    @objc func clearAll() {
        guard let win = window else { return }
        let a = NSAlert(); a.messageText = L("history.clear.confirm"); a.addButton(withTitle: L("history.clear")); a.addButton(withTitle: L("perm.later"))
        a.beginSheetModal(for: win) { r in
            if r == .alertFirstButtonReturn { History.items().forEach { History.remove($0.url) }; NotificationCenter.default.post(name: History.changed, object: nil); self.reload(); self.close() } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var item: NSStatusItem!; var editor: Editor?
    @discardableResult func ensureEditor() -> Editor {
        if let e = editor, !e.terminated { return e }
        if editor != nil { NSLog("PC recreating editor after webview death") }
        let e = Editor(); editor = e; return e
    }
    func applicationDidFinishLaunching(_ n: Notification) {
        warmSfx(["capture"])
        ensureEditor().warm()
        VisualBoxDetector.prewarm()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(contentsOf: Bundle.main.url(forResource: "menubar", withExtension: "png") ?? extDir.appendingPathComponent("icons/icon16.png")); icon?.size = NSSize(width: 18, height: 18)
        item.button?.image = icon ?? NSImage(systemSymbolName: "scissors", accessibilityDescription: "Pocketclip")
        let menu = NSMenu()
        add(menu, L("menu.region"), "2", #selector(region), [.command, .shift]); add(menu, L("menu.window"), "3", #selector(window), [.command, .shift]); add(menu, L("menu.screen"), "f", #selector(screen))
        menu.addItem(.separator()); add(menu, L("menu.history"), "h", #selector(showHistory), [.command, .shift])
        menu.addItem(.separator()); let rl = menu.addItem(withTitle: L("menu.restart"), action: #selector(relaunch), keyEquivalent: ""); rl.target = self
        menu.addItem(withTitle: L("menu.quit"), action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        registerHotkeys()
        NotificationCenter.default.addObserver(forName: History.changed, object: nil, queue: .main) { [weak self] _ in
            let has = !History.items().isEmpty; self?.editor?.web.evaluateJavaScript("window.pcSetHistory && pcSetHistory(\(has))") }
        let a = CommandLine.arguments
        if a.contains("--dump-strings") { for k in ["menu.region","menu.window","menu.screen","menu.restart","menu.quit","menu.history","history.title","perm.title","perm.open","perm.later"] { print(k, "=", L(k)) }; exit(0) }
        forceHoverFirst = a.contains("--hover-first")
        // Perf: --bench-screen N runs N fullscreen captures after warm (2s gap).
        if let i = a.firstIndex(of: "--bench-screen") {
            let n = (i+1 < a.count ? Int(a[i+1]) : nil) ?? 3
            for k in 1...n {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 * Double(k)) {
                    T0 = CACurrentMediaTime(); tlog("bench-screen \(k)"); self.screen()
                }
            }
        }
        // Debug: --open X [--history-mode] [--switch-first] --snapshot P   |   --history --snapshot P (menu route)
        let snap = a.firstIndex(of: "--snapshot").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
        var e: Editor?
        if let i = a.firstIndex(of: "--open"), i+1 < a.count { T0 = CACurrentMediaTime(); tlog("--open start"); let u = URL(fileURLWithPath: a[i+1]); e = show(u, hist: u.path.hasPrefix(History.dir.path) ? u : nil)
            if ProcessInfo.processInfo.environment["PC_REOPEN"] != nil { for k in 1...3 { DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 * Double(k)) { T0 = CACurrentMediaTime(); tlog("warm reopen \(k)"); _ = self.show(u, hist: nil); if k == 1, let d = ProcessInfo.processInfo.environment["PC_EARLYSHOT"] { for ms in [60, 150, 230] { DispatchQueue.main.asyncAfter(deadline: .now() + Double(ms)/1000) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-x", "\(d)/early-\(ms).png"]; try? p.run(); tlog("earlyshot \(ms)") } } } } } } }
        else if a.contains("--history") { e = showHistory() }
        if let e = e, let out = snap {
            let base = (out as NSString).deletingPathExtension, menuRoute = a.contains("--history") && !a.contains("--open")
            var step = 0
            e.onLoad = { DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                step += 1
                if step == 1 && menuRoute { e.snapshot(to: out) {}; return }
                if step == 1 && a.contains("--test-draw") {
                    // Simulated stroke to exercise annotation autosave
                    e.web.evaluateJavaScript("""
                    (() => { const c = [...document.querySelectorAll('canvas')].reverse().find(x => x.getBoundingClientRect().width > 50) || document.getElementById('draw'); const r = c.getBoundingClientRect();
                    const ev = (t, x, y) => c.dispatchEvent(new MouseEvent(t, { bubbles: true, button: 0, buttons: 1, clientX: r.left + x, clientY: r.top + y }));
                    ev('mousedown', 40, 40); for (let i = 1; i < 30; i++) ev('mousemove', 40 + i * 8, 40 + i * 5); ev('mouseup', 280, 190); document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true })); return c.id })()
                    """) { r, err in NSLog("PC test-draw on %@ %@", "\(r ?? "nil")", "\(err.map { "\($0)" } ?? "")") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSLog("PC annotated exists %d", e.histURL.map { FileManager.default.fileExists(atPath: History.annotated($0).path) } == true ? 1 : 0); e.snapshot(to: out) {} }
                    return
                }
                if step == 1 {
                    e.snapshot(to: out) {
                        guard a.contains("--history-mode") else { return }
                        e.setHistory(true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            NSLog("PC history-mode %d frame %@ windows %d", e.inHistory ? 1 : 0, NSStringFromRect(e.panel.frame), NSApp.windows.filter { $0.isVisible }.count)
                            e.snapshot(to: base + "-history.png") {
                                if a.contains("--switch-first"), let c = e.grid.cells.last { c.doOpen() } } } }
                } else if step == 2 {
                    NSLog("PC switched to %@ history-mode %d frame %@ windows %d", e.histURL?.lastPathComponent ?? "-", e.inHistory ? 1 : 0, NSStringFromRect(e.panel.frame), NSApp.windows.filter { $0.isVisible }.count)
                    e.snapshot(to: base + "-switched.png") {}
                } } }
        }
    }
    func add(_ m: NSMenu, _ t: String, _ k: String, _ s: Selector, _ mods: NSEvent.ModifierFlags = [.option, .shift]) { let it = m.addItem(withTitle: t, action: s, keyEquivalent: k); it.keyEquivalentModifierMask = mods; it.target = self }
    func go(_ m: Mode) {
        T0 = CACurrentMediaTime(); tlog("hotkey")
        if !CGPreflightScreenCaptureAccess() {
            let asked = UserDefaults.standard.bool(forKey: "askedSC")
            if !asked { UserDefaults.standard.set(true, forKey: "askedSC"); CGRequestScreenCaptureAccess() }
            let a = NSAlert(); a.messageText = L("perm.title")
            a.informativeText = L("perm.body")
            a.addButton(withTitle: L("perm.open")); a.addButton(withTitle: L("perm.later"))
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
            return
        }
        capture(m) { if let u = $0 { tlog("capture done"); sfx("capture"); let h = History.save(u); NotificationCenter.default.post(name: History.changed, object: nil); _ = self.show(u, hist: h) } } }
    // Menu route: reuse a visible editor (switch it to history mode) or open one on the newest capture in history mode.
    @discardableResult @objc func showHistory() -> Editor? {
        if let e = editor, e.panel.isVisible {
            NSApp.activate(ignoringOtherApps: true); e.panel.makeKeyAndOrderFront(nil); e.setHistory(true); return e
        }
        guard let newest = History.items().first?.url else { return nil }
        let e = show(newest, hist: newest); e.startInHistory = true; return e
    }
    func validateMenuItem(_ m: NSMenuItem) -> Bool { m.action == #selector(showHistory) ? !History.items().isEmpty : true }
    @objc func relaunch() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundlePath)\""]; try? p.run(); NSApp.terminate(nil)
    }
    @objc func region() { go(.region) }
    @objc func window() { go(.window) }
    @objc func screen() { go(.screen) }
    @discardableResult func show(_ u: URL, hist: URL? = nil, frame: NSRect? = nil) -> Editor {
        let e = ensureEditor()
        e.present(u, hist: hist, frame: frame)
        return e
    }
    func registerHotkeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, ud in
            var id = EventHotKeyID(); GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let d = Unmanaged<AppDelegate>.fromOpaque(ud!).takeUnretainedValue()
            switch id.id { case 1: d.region(); case 2: d.window(); default: d.screen() }; return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        for (i, k, m) in [(1, kVK_ANSI_2, cmdKey|shiftKey), (2, kVK_ANSI_3, cmdKey|shiftKey), (3, kVK_ANSI_F, optionKey|shiftKey)] {
            var ref: EventHotKeyRef?; RegisterEventHotKey(UInt32(k), UInt32(m), EventHotKeyID(signature: OSType(0x50434C50), id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
        }
    }
}
let app = NSApplication.shared; let del = AppDelegate(); app.delegate = del; app.setActivationPolicy(.accessory); app.run()

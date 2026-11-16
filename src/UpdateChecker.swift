import AppKit

/// Lightweight update check against the latest GitHub release.
/// - Automatic: on launch and at most once per 24h while running; silent on errors, honors "Skip This Version".
/// - Manual: menu bar "Check for Updates…"; always reports the result.
/// Debug override (harmless, local only): `defaults write local.nadar.pocketclip PCUpdateDebugLatest 9.9`
/// makes the check pretend the latest release is that version, so the update notice can be previewed
/// without publishing a release. Clear with `defaults delete local.nadar.pocketclip PCUpdateDebugLatest`.
final class UpdateChecker {
    static let shared = UpdateChecker()
    private let api = URL(string: "https://api.github.com/repos/naaadarrr/pocketclip/releases/latest")!
    private let releasesPage = URL(string: "https://github.com/naaadarrr/pocketclip/releases/latest")!
    private let lastCheckKey = "PCUpdateLastCheck", skipKey = "PCUpdateSkipVersion", debugKey = "PCUpdateDebugLatest"
    private let interval: TimeInterval = 24 * 60 * 60
    private var timer: Timer?, busy = false

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.check(manual: false) }
        // Wake hourly; only actually query once the 24h window has passed.
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let last = UserDefaults.standard.double(forKey: self.lastCheckKey)
            if Date().timeIntervalSince1970 - last >= self.interval { self.check(manual: false) }
        }
    }

    /// Compares dotted numeric versions ("0.10" > "0.9"); returns true if a is newer than b.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            var t = s.trimmingCharacters(in: .whitespaces); if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
            return t.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func check(manual: Bool) {
        if busy { return }; busy = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        if let fake = UserDefaults.standard.string(forKey: debugKey), !fake.isEmpty {
            busy = false; handle(latest: fake, page: releasesPage, manual: manual); return
        }
        var req = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Pocketclip/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = json?["tag_name"] as? String
            let page = (json?["html_url"] as? String).flatMap(URL.init(string:)) ?? self.releasesPage
            DispatchQueue.main.async {
                self.busy = false
                guard ok, let tag = tag, err == nil else {
                    NSLog("PC update check failed: %@", err?.localizedDescription ?? "status \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                    if manual { self.alert(title: L("update.error.title"), body: L("update.error.body")) }
                    return
                }
                self.handle(latest: tag, page: page, manual: manual)
            }
        }.resume()
    }

    private func handle(latest tag: String, page: URL, manual: Bool) {
        let latest = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        guard UpdateChecker.isNewer(latest, than: current) else {
            if manual { alert(title: L("update.uptodate.title"), body: String(format: L("update.uptodate.body"), current)) }
            return
        }
        if !manual && UserDefaults.standard.string(forKey: skipKey) == latest { return }
        let a = NSAlert()
        a.messageText = String(format: L("update.available.title"), latest)
        a.informativeText = String(format: L("update.available.body"), current)
        a.addButton(withTitle: L("update.download")); a.addButton(withTitle: L("update.later")); a.addButton(withTitle: L("update.skip"))
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(page)
        case .alertThirdButtonReturn: UserDefaults.standard.set(latest, forKey: skipKey)
        default: break
        }
    }

    private func alert(title: String, body: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = body; a.addButton(withTitle: L("update.ok"))
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
}

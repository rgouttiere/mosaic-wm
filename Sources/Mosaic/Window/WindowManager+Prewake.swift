import AppKit

/// Wake the apps of the parked workspaces the moment ⌘⌥ goes down — a fraction of a second before
/// the workspace digit. macOS naps an app that has been idle a little while, and the first
/// accessibility call into a napping app pays its wake-up: 35–70 ms measured (WhatsApp 44,
/// KeePassXC 70, the Safari web apps 62–64, Slack 35), against 0.1–0.6 ms once it is awake. That
/// first call used to be the unpark write of the switch. Now it is one cheap position read per app,
/// off the main thread, while the finger is still on its way to the digit.
final class Prewake {
    weak var wm: WindowManager?
    private var monitors: [Any] = []
    private var last = Date.distantPast
    private let queue = DispatchQueue(label: "mosaic.prewake", qos: .userInteractive)

    func start() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if f.contains(.command), f.contains(.option) { self?.fire() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) { monitors.append(l) }
    }

    /// Also callable directly (the drag-switch list, `mosaic prewake`).
    func fire() {
        guard Config.shared.prewakeParked, let wm, Date().timeIntervalSince(last) > 1.5 else { return }
        last = Date()
        let targets = wm.prewakeTargets()
        guard !targets.isEmpty else { return }
        Perf.count("prewake.apps", targets.count)
        queue.async {
            for el in targets {
                var v: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v)
            }
        }
    }
}

extension WindowManager {
    /// One window per app that has windows ONLY in parked workspaces — an app on screen is awake.
    func prewakeTargets() -> [AXUIElement] {
        var shownPids = Set<pid_t>()
        for (did, n) in shownOnDisplay where screen(forDisplayID: did) != nil {
            spaces[n]?.root?.forEachLeaf { if let w = $0.window { shownPids.insert(w.pid) } }
        }
        var seen = Set<pid_t>(), out: [AXUIElement] = []
        let shown = Set(shownOnDisplay.values)
        for (sid, ws) in spaces where !shown.contains(sid) {
            ws.root?.forEachLeaf { leaf in
                guard let w = leaf.window, !shownPids.contains(w.pid), seen.insert(w.pid).inserted else { return }
                out.append(w.element)
            }
        }
        return out
    }
}

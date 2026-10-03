import AppKit

/// Park by hiding (opt-in, `hideConfinedApps`). The window server keeps ~40 px of a window pushed
/// off-screen and alpha is dead, so the classic park leaves a sliver the tiles cover.
/// `NSRunningApplication.hide()` has none of that — one call per app, nothing on screen — but hides
/// EVERY window of the app, so only an app confined to the parked workspace qualifies. Measured
/// against the move (2026-10-03, six ws1⇄ws2 round trips each): a switch averaged 382 ms vs 180,
/// peaked at 1.4 s vs 0.65 — the apps redraw on unhide and every AX call to one that is waking up
/// stalls the main thread. Hence off by default; the mechanics stay correct for whoever wants it.
extension WindowManager {
    /// Apps whose every managed window sits in `space`, minus `foreignPids` (apps that also show
    /// something unmanaged, a native full-screen window, the scratchpad, ourselves). Pure, tested.
    static func confinedPids(windowsByPid: [pid_t: Set<UInt64>], space: UInt64, foreignPids: Set<pid_t>) -> Set<pid_t> {
        Set(windowsByPid.compactMap { pid, spaces in spaces == [space] && !foreignPids.contains(pid) ? pid : nil })
    }

    private func pidsByWorkspace() -> [pid_t: Set<UInt64>] {
        var out: [pid_t: Set<UInt64>] = [:]
        for (sid, st) in spaces { st.root?.forEachLeaf { if let w = $0.window { out[w.pid, default: []].insert(sid) } } }
        return out
    }

    /// Hide the apps confined to `ws` before its windows are arranged off-screen; the hidden ones
    /// are skipped by `windowRect(forTile:)`, so they stay on their tiles, invisible.
    func hideConfinedApps(parking ws: SpaceState) {
        guard Config.shared.hideConfinedApps, let sid = workspaceID(of: ws), let root = ws.root else { return }
        var managed = Set<CGWindowID>()
        var unsafe = Set<pid_t>([ProcessInfo.processInfo.processIdentifier])
        for (_, st) in spaces {
            st.root?.forEachLeaf { if let id = $0.window?.lastKnownID { managed.insert(id) } }
        }
        // Never hide an app with a native full-screen window (a Space game). A confined app has all
        // its windows HERE, so this workspace's leaves are the only ones worth the AX read — asking
        // every workspace put a 650 ms round trip to an app still waking from its own unhide on the
        // critical path of the switch.
        root.forEachLeaf { if let w = $0.window, w.isFullscreen { unsafe.insert(w.pid) } }
        if let bundle = scratchpadBundleID,
           let scratch = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            unsafe.insert(scratch.processIdentifier)
        }
        for w in onScreenSnapshot(maxAge: 1) where !managed.contains(w.id) && w.bounds.width >= 50 && w.bounds.height >= 50 {
            unsafe.insert(w.pid)   // shows something we do not manage (a palette, a picture-in-picture)
        }
        let confined = Self.confinedPids(windowsByPid: pidsByWorkspace(), space: sid, foreignPids: unsafe)
        var named: [String] = []
        root.forEachLeaf { leaf in
            guard let w = leaf.window, confined.contains(w.pid), !ManagedWindow.parkHiddenPids.contains(w.pid) else { return }
            ManagedWindow.parkHiddenPids.insert(w.pid)
            w.app.hide()
            named.append(w.appName)
        }
        if !named.isEmpty {
            rememberHiddenPids()
            Log.event("park ws\(sid): hid \(named.joined(separator: ", ")) (confined to it)")
        }
    }

    /// Hiding the frontmost app makes macOS activate the next one in its own order — Alacritty on
    /// another monitor, which focus-sync then adopted: "the focus stays on Alacritty instead of
    /// following me". Make the incoming workspace's window frontmost BEFORE the outgoing is hidden.
    func activateBeforeHiding(_ ws: SpaceState) {
        guard Config.shared.hideConfinedApps,
              let w = (ws.focused ?? ws.root?.firstLeaf())?.window, let id = AX.windowID(w.element) else { return }
        AX.makeMain(w.element)
        w.activateApp()
        focusAssertedAt = Date()   // what follows in the next moments is our own echo
        focusAssertedID = id
        focusAssertedPID = w.app.processIdentifier
    }

    func unhideApps(for ws: SpaceState) {
        guard let root = ws.root else { return }
        var named: [String] = []
        root.forEachLeaf { leaf in
            guard let w = leaf.window, ManagedWindow.parkHiddenPids.contains(w.pid) else { return }
            ManagedWindow.parkHiddenPids.remove(w.pid)
            w.app.unhide()
            named.append(w.appName)
        }
        if !named.isEmpty {
            rememberHiddenPids()
            if let sid = workspaceID(of: ws) { Log.event("unpark ws\(sid): unhid \(named.joined(separator: ", "))") }
        }
    }

    func unhideAllParked() {
        for pid in ManagedWindow.parkHiddenPids { NSRunningApplication(processIdentifier: pid)?.unhide() }
        ManagedWindow.parkHiddenPids.removeAll()
        rememberHiddenPids()
    }

    // MARK: - Surviving our own death

    /// The pids we currently hold hidden, on disk, one per line — rewritten on every change and
    /// removed when empty. A run that ends without applicationWillTerminate (kill -9, a crash,
    /// `launchctl kickstart -k`) cannot unhide them itself; the next run does, from this file.
    static let hiddenPidsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mosaic/.hidden-pids")

    private func rememberHiddenPids() {
        let pids = ManagedWindow.parkHiddenPids
        if pids.isEmpty {
            try? FileManager.default.removeItem(at: Self.hiddenPidsURL)
        } else {
            let text = pids.sorted().map(String.init).joined(separator: "\n") + "\n"
            try? text.write(to: Self.hiddenPidsURL, atomically: true, encoding: .utf8)
        }
    }

    static func parseHiddenPids(_ text: String) -> [pid_t] {
        text.split(whereSeparator: \.isNewline).compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Unhide what a previous run left hidden. Returns how many apps it had to unhide.
    @discardableResult
    func unhideLeftoversFromPreviousRun() -> Int {
        guard let text = try? String(contentsOf: Self.hiddenPidsURL, encoding: .utf8) else { return 0 }
        try? FileManager.default.removeItem(at: Self.hiddenPidsURL)
        var named: [String] = []
        for pid in Self.parseHiddenPids(text) {
            guard let app = NSRunningApplication(processIdentifier: pid), app.isHidden else { continue }
            app.unhide()
            named.append(app.localizedName ?? "pid \(pid)")
        }
        if !named.isEmpty { Log.event("unhid \(named.count) app(s) the previous run left hidden: \(named.joined(separator: ", "))") }
        return named.count
    }
}

import AppKit

extension WindowManager {
    // MARK: - Persistence

    func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        // v2: keys are workspace numbers (1-9). Legacy files keyed by macOS Space id (huge
        // numbers) are silently dropped here — a one-time reset of persisted layouts on upgrade.
        for (key, space) in state.spaces {
            if let id = UInt64(key), id >= 1, id <= 9 { savedState[id] = space }
        }
        scratchpadBundleID = state.scratchpadBundle
        savedShownByMonitor = state.shownByMonitor ?? []
        NSLog("Mosaic: loaded \(savedState.count) saved workspace layout(s)")
    }

    /// Restore EVERY saved workspace at once, at launch. In the emulated model all windows share
    /// one on-screen Space, so a lazy per-visit restore lets the first-visited workspace swallow
    /// every other workspace's currently-open windows. Instead: build all saved trees from ONE
    /// shared pool of open windows (each window matched to the workspace it was saved in), then
    /// show the first non-empty workspace on each monitor and park the rest. Windows for apps
    /// that haven't relaunched yet are simply absent from a tree and re-adopted by reconcile
    /// later; windows opened since the save fall through to the active workspace as usual.
    func restoreSavedWorkspaces() {
        guard !savedState.isEmpty else { return }
        // Build launch routing hints from EVERY saved window first, so apps that relaunch after
        // us (reboot) can still be routed to their workspace even though they're absent from the
        // pool right now. Cleared a few seconds later (in startObserving).
        for (id, saved) in savedState {
            var wins: [SavedWindow] = []
            flattenSaved(saved.tree, into: &wins)
            for sw in wins {
                guard let b = sw.bundleID else { continue }
                if let t = sw.title { restoreHints["\(b)\u{1}\(t)"] = Int(id) }
                restoreHints[b] = Int(id)   // weaker bundle-only fallback
            }
        }
        var pool = AX.managedWindows().compactMap(ManagedWindow.init).filter {
            !isFloating($0) && !$0.isFullscreen && $0.app.bundleIdentifier != scratchpadBundleID
        }
        for (id, saved) in savedState.sorted(by: { $0.key < $1.key }) {
            guard let tree = saved.tree, let root = rebuild(tree, pool: &pool) else { continue }
            let st = SpaceState(displayID: assignedDisplay(forWorkspace: Int(id)) ?? 0)
            st.mode = mode(named: saved.mode)
            st.root = root
            st.focused = root.firstVisibleLeaf()   // honor the saved tab selection, not always tab 0
            spaces[id] = st
            wireTabCallbacks(root)
        }
        // Drop ONLY the entries we actually rebuilt (their windows were consumed from the pool).
        // Keep the rest: their apps weren't running yet, so they stay in savedState for the lazy
        // restoreSaved() path on first switch AND for saveNow() to keep persisting — otherwise a
        // workspace whose apps start slower than Mosaic loses its tab/split structure every reboot.
        for id in spaces.keys { savedState[id] = nil }
        observer.watchForClose(AX.managedWindows().compactMap(ManagedWindow.init))

        // Show the workspace each monitor showed last session (by left→right monitor index);
        // else the first non-empty workspace pinned to it; else its default. Park the rest. Never
        // leaves a monitor showing an empty workspace while a populated one it owns sits parked.
        for (i, did) in orderedDisplays().enumerated() {
            guard let scr = screen(forDisplayID: did) else { continue }
            let owned = (1...9).filter { assignedDisplay(forWorkspace: $0) == did }
            let remembered = savedShownByMonitor.indices.contains(i) ? savedShownByMonitor[i] : 0
            let n: Int
            if remembered >= 1, remembered <= 9, assignedDisplay(forWorkspace: remembered) == did {
                n = remembered   // exact restored view
            } else {
                n = owned.first { spaces[UInt64($0)]?.root != nil } ?? defaultWorkspaceNumber(for: scr)
            }
            shownOnDisplay[did] = UInt64(n)
            workspace(n, on: scr).displayID = did   // ensure it exists and is homed here
        }
        activeSpaceID = screenUnderMouse().flatMap { shownOnDisplay[displayID(of: $0)] }
        reassertAllWorkspaces()
        updateFocusIndicator()
        if let scr = screenUnderMouse() { showWorkspaceIndicator(for: scr) }
        NSLog("Mosaic: restored \(spaces.count) workspace(s) at launch")
    }

    /// Collect every leaf window of a saved tree (depth-first) — used to build launch hints.
    func flattenSaved(_ node: SavedNode?, into out: inout [SavedWindow]) {
        guard let node else { return }
        if let w = node.window { out.append(w); return }
        for c in node.children ?? [] { flattenSaved(c, into: &out) }
    }

    /// If a just-appeared window matches a launch hint, route it to the workspace it was saved
    /// in (creating/parking as needed) instead of the active one. Returns true if it was routed.
    /// Consumes the hint so a second window of the same app doesn't chase it.
    func routeByHint(_ window: ManagedWindow) -> Bool {
        guard !restoreHints.isEmpty, let b = window.app.bundleIdentifier else { return false }
        let strong = "\(b)\u{1}\(window.title)"
        // Consume the key we actually matched. Clearing only `strong` left the weaker bundle-only
        // fallback in place, so every later window of the same app (any relaunch whose live title
        // differs from the saved one) kept matching it and got yanked to the saved workspace for the
        // ~20s until the hints expire.
        let key = restoreHints[strong] != nil ? strong : b
        guard let n = restoreHints[key], n >= 1, n <= 9,
              UInt64(n) != activeSpaceID else { return false }
        restoreHints[key] = nil
        placeOnWorkspace(window, n: n)
        return true
    }

    /// Debounced save of all known layouts (live + not-yet-restored).
    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Keep a copy of the layout as it was a few minutes ago, next to the live one.
    ///
    /// Saves run constantly, so by the time you notice a layout has been mangled — a wake that
    /// scattered windows across workspaces, say — the good version has long since been written
    /// over. A copy that is only refreshed once it is older than the interval below always spans
    /// an event like that: restore it with `cp state.json.prev state.json` while Mosaic is NOT
    /// running, then relaunch.
    func rollStateBackup() {
        let fm = FileManager.default
        let prev = stateURL.deletingLastPathComponent().appendingPathComponent("state.json.prev")
        guard fm.fileExists(atPath: stateURL.path) else { return }
        if let attrs = try? fm.attributesOfItem(atPath: prev.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 300 { return }   // still recent enough
        try? fm.removeItem(at: prev)
        try? fm.copyItem(at: stateURL, to: prev)
    }

    func saveNow() {
        saveWork?.cancel()   // disarm any pending debounced save so it can't overwrite this
        var out: [String: SavedSpace] = [:]
        // Keyed by workspace number — the stable identity in the emulated model (no CGS Space
        // id, no monitor fingerprint, no desktop ordinal needed).
        for (id, st) in spaces {
            guard let root = st.root else { continue }
            out[String(id)] = SavedSpace(displayID: st.displayID,
                                         mode: modeName(st.mode),
                                         tree: serialize(root),
                                         displayUUID: nil, spaceOrdinal: nil)
        }
        // Keep layouts for workspaces we haven't restored yet this session.
        for (id, saved) in savedState where spaces[id] == nil {
            out[String(id)] = saved
        }
        // Which workspace is shown on each monitor, left→right, so a restart restores the view.
        let shown = orderedDisplays().map { Int(shownOnDisplay[$0] ?? 0) }
        let state = SavedState(spaces: out, assignments: nil,
                               assignmentApps: nil, scratchpadBundle: scratchpadBundleID,
                               shownByMonitor: shown)
        rollStateBackup()
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: .atomic)   // crash-safe
        } catch {
            NSLog("Mosaic: could not save state: \(error)")
        }
    }

    func serialize(_ node: Container) -> SavedNode {
        if let window = node.window {
            return SavedNode(window: SavedWindow(windowID: AX.windowID(window.element),
                                                 bundleID: window.app.bundleIdentifier,
                                                 title: window.title),
                             layout: nil, ratios: nil, selected: nil, stacked: nil, children: nil)
        }
        return SavedNode(window: nil,
                         layout: layoutName(node.layout),
                         ratios: node.ratios.map(Double.init),
                         selected: node.selected,
                         stacked: node.stacked,
                         children: node.children.map(serialize))
    }

    /// Rebuild a saved workspace (keyed by its number) by matching its windows to open ones.
    func restoreSaved(_ id: UInt64, on screen: NSScreen) -> Bool {
        guard let saved = savedState[id], let savedTree = saved.tree else { return false }
        var pool = captureWindows(on: screen)
        guard !pool.isEmpty else { return false }

        guard let root = rebuild(savedTree, pool: &pool) else { return false }

        let st = SpaceState(displayID: displayID(of: screen))   // place it on the current monitor
        st.mode = mode(named: saved.mode)
        st.root = root
        spaces[id] = st
        activeSpaceID = id
        focused = root.firstLeaf()
        savedState[id] = nil   // consumed — it's now live

        // Windows opened since the layout was saved → append them.
        for window in pool { insert(window) }

        if let r = self.root { wireTabCallbacks(r) }
        observer.watchForClose(captureWindows(on: screen))
        render()
        NSLog("Mosaic: restored workspace \(id)")
        return true
    }

    func rebuild(_ saved: SavedNode, pool: inout [ManagedWindow]) -> Container? {
        if let sw = saved.window {
            guard let match = takeMatch(sw, from: &pool) else { return nil }
            return Container(window: match)
        }
        let kids = (saved.children ?? []).compactMap { rebuild($0, pool: &pool) }
        if kids.isEmpty { return nil }
        if kids.count == 1 { return kids[0] }   // collapse branches that lost windows
        let container = Container(layout: layout(named: saved.layout), children: kids)
        if let ratios = saved.ratios, ratios.count == kids.count {
            container.ratios = ratios.map { CGFloat($0) }
        }
        container.selected = min(max(saved.selected ?? 0, 0), kids.count - 1)
        container.stacked = saved.stacked ?? false
        return container
    }

    /// Find a live window matching a saved one (by id, then bundle+title, then bundle)
    /// and remove it from the pool so it isn't reused.
    func takeMatch(_ sw: SavedWindow, from pool: inout [ManagedWindow]) -> ManagedWindow? {
        // Match by id, but only if the bundle also agrees: a saved CGWindowID is stable only while
        // the app keeps running (Persistence.swift), and macOS REUSES ids across a reboot — an id
        // alone can collide with an unrelated app's window and graft the wrong app into a saved slot.
        if let wid = sw.windowID,
           let i = pool.firstIndex(where: { AX.windowID($0.element) == wid
                                            && (sw.bundleID == nil || $0.app.bundleIdentifier == sw.bundleID) }) {
            return pool.remove(at: i)
        }
        if let b = sw.bundleID, let t = sw.title,
           let i = pool.firstIndex(where: { $0.app.bundleIdentifier == b && $0.title == t }) {
            return pool.remove(at: i)
        }
        // Bundle-only fallback: only when it's UNAMBIGUOUS (exactly one window of that app
        // left in the pool) — otherwise we'd grab an arbitrary same-app window.
        if let b = sw.bundleID {
            let matches = pool.indices.filter { pool[$0].app.bundleIdentifier == b }
            if matches.count == 1 { return pool.remove(at: matches[0]) }
        }
        return nil
    }

    func modeName(_ m: Mode) -> String {
        switch m {
        case .columns: return "columns"; case .grouped: return "grouped"
        case .tabbed: return "tabbed"; case .masterStack: return "master-stack"
        }
    }
    func mode(named s: String) -> Mode {
        switch s.lowercased() {
        case "grouped": return .grouped; case "tabbed": return .tabbed
        case "master-stack", "masterstack", "master": return .masterStack
        default: return .columns
        }
    }
    func layoutName(_ l: Container.Layout) -> String {
        switch l { case .splitH: return "splitH"; case .splitV: return "splitV"; case .tabbed: return "tabbed" }
    }
    func layout(named s: String?) -> Container.Layout {
        switch s?.lowercased() { case "splitv": return .splitV; case "tabbed": return .tabbed; default: return .splitH }
    }

    // MARK: - Helpers

    /// `onScreen` lets a caller that already enumerated the on-screen window ids this pass
    /// (e.g. reconcile) thread its snapshot in, instead of paying a second identical
    /// CGWindowList enumeration microseconds later. Defaults to a fresh enumeration.
    func captureWindows(on screen: NSScreen, onScreen: Set<CGWindowID>? = nil) -> [ManagedWindow] {
        let __perf = DispatchTime.now(); defer { Perf.record("captureWindows", since: __perf) }
        // The window list carries each window's owner, so we know which apps have anything on
        // screen at all — and the filter below discards every window that isn't. Asking the others
        // for their windows was a round trip per app, on a dozen apps, ~1.4 times a second.
        let snapshot = onScreenSnapshot(maxAge: onScreen == nil ? 0 : snapshotTTL)
        let onScreen = onScreen ?? Set(snapshot.map { $0.id })
        return AX.managedWindows(limitedTo: Set(snapshot.map { $0.pid }))
            .compactMap(ManagedWindow.init)
            .filter { window in
                // Order matters: reject via cheap local checks and the on-screen gate BEFORE the
                // cross-process isFullscreen / frame reads, so off-Space windows (most of a
                // multi-desktop session) don't each waste an AXFullScreen IPC to then be discarded.
                guard !isFloating(window) else { return false }                        // local: rules / floatingApps
                guard let wid = AX.windowID(window.element), onScreen.contains(wid) else { return false }
                guard !window.isFullscreen else { return false }                       // IPC — now only for on-screen wins
                if window.app.bundleIdentifier == scratchpadBundleID { return false }   // scratchpad app floats
                guard let axFrame = window.frame else { return false }
                let cocoaFrame = Geometry.flip(axFrame)
                return screen.frame.contains(CGPoint(x: cocoaFrame.midX, y: cocoaFrame.midY))
            }
    }

    func isFloating(_ window: ManagedWindow) -> Bool {
        // An explicit per-app rule wins both ways: float:true floats, float:false pins to tiling
        // (overrides floatingApps AND the auto-dialog heuristic below).
        if let ruled = ruleFor(window)?.float { return ruled }
        if floatingApps.contains(window.appName.lowercased()) { return true }
        if let bundle = window.app.bundleIdentifier?.lowercased(), floatingApps.contains(bundle) { return true }
        if Config.shared.autoFloatDialogs, isDialogLike(window) { return true }
        return false
    }

    /// Heuristic (AeroSpace): a standard-subrole window with no native full-screen button is
    /// almost always a dialog / palette / settings panel — float it. Apps listed in
    /// `alwaysTileApps` are excepted: they lack the button but are windows you work in
    /// (terminals, by default). Only consulted when `autoFloatDialogs` is on.
    func isDialogLike(_ window: ManagedWindow) -> Bool {
        let always = Config.shared.alwaysTileApps
        if always.contains(window.appName.lowercased()) { return false }
        if let b = window.app.bundleIdentifier?.lowercased(), always.contains(b) { return false }
        return !AX.hasFullscreenButton(window.element)
    }

    func clamp(_ v: CGFloat) -> CGFloat { min(0.9, max(0.1, v)) }

    /// The tiling area of a screen = its visible frame minus the configured outer gap,
    /// minus a top strip reserved for an external bar (e.g. sketchybar).
    ///
    /// `externalBarTop` is the bar's height. We only reserve what macOS doesn't already
    /// reserve at the top (menu bar / notch safe-area), so a notched built-in display —
    /// which already keeps 32px clear — gets little or no extra strip, while external
    /// monitors that reserve nothing get the full bar height. This keeps the gap uniform
    /// across a mixed multi-monitor setup instead of double-counting the notch.
    func layoutRect(_ screen: NSScreen) -> NSRect {
        var r = screen.visibleFrame.insetBy(dx: Config.shared.outerGap, dy: Config.shared.outerGap)
        let bar = Config.shared.externalBarTop
        if bar > 0 {
            let alreadyReserved = screen.frame.maxY - screen.visibleFrame.maxY  // menu bar / notch
            var extra = max(0, bar - alreadyReserved)
            // Sole notched built-in: the external bar is shifted BELOW the notch (sketchybar
            // y_offset), so its whole height sits inside the tiling area. Reserve that offset too,
            // else tiles slide under the bar. Same condition as the sketchybar-side notch offset:
            // exactly one display AND it has a notch (safe-area top inset > 0).
            if NSScreen.screens.count == 1, screen.safeAreaInsets.top > 0 {
                extra += Config.shared.notchBarOffset
            }
            r.size.height -= extra   // Cocoa origin is bottom-left → shrinking height frees the TOP
        }
        return r
    }

    /// The screen under the mouse (or the main/first screen). `nil` only in a screenless state
    /// — all displays asleep mid-reconfiguration, or a headless Mac — where the old
    /// `NSScreen.screens[0]` fallback trapped. Callers guard and no-op when there's no screen.
    func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

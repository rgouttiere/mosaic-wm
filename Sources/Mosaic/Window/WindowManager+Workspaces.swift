import AppKit

extension WindowManager {
    // MARK: - i3-style numbered workspaces (v2: emulated — park/unpark, no CGS)

    /// Switch to workspace `n` (1-9) on ITS pinned monitor (model A): each workspace has a home
    /// monitor, so ⌘⌥5 goes to whichever monitor workspace 5 belongs to, parks whatever that
    /// monitor shows now, and places workspace 5 there (empty on first use, or restored from
    /// disk) — then moves focus/cursor onto that monitor. No macOS Space transition, just two
    /// off-screen ↔ on-screen `arrange` passes.
    func switchToWorkspace(_ n: Int) {
        let __perf = DispatchTime.now(); defer { Perf.record("switch", since: __perf) }
        guard let screen = homeScreen(forWorkspace: n) ?? screenUnderMouse() else { return }
        let did = displayID(of: screen)
        let target = UInt64(n)
        guard shownOnDisplay[did] != target else {   // already shown on its monitor → just retarget
            activeSpaceID = target
            warpMouseToWorkspace(target, on: screen)
            updateFocusIndicator()
            // The focused workspace still changed (keyboard moved to this monitor), so emit state —
            // else the menu bar / sketchybar / status.json and workspaceRecency stay on the old one.
            showWorkspaceIndicator(for: screen)
            return
        }

        // Park the outgoing workspace off the target monitor. No coverParkedSlivers() here: it only
        // re-raises the OTHER monitors' workspaces (unchanged by this switch, already covering their
        // own slivers), while the incoming's own render below raises it above the sliver it leaves.
        focusIndicator.hide()
        if let outgoing = shownOnDisplay[did], let ws = spaces[outgoing] { parkWorkspace(ws) }
        scratchpadVisible = false

        // Place workspace n on its monitor: restore from disk on first load, else unpark.
        shownOnDisplay[did] = target
        activeSpaceID = target
        clearAttention(n)   // visiting it dismisses its badge
        if spaces[target] == nil, restoreSaved(target, on: screen) {
            // restoreSaved built the tree, set focus, and rendered it on-screen
        } else {
            let ws = workspace(n, on: screen)
            unparkWorkspace(ws, on: screen, raise: false)   // render() below raises — don't raise twice
            if ws.focused == nil { ws.focused = ws.root?.firstLeaf() }
            render()
        }
        if let ws = spaces[target] { liftAppsAboveParked(ws) }   // multi-app: beat macOS' app-layer order
        layoutResizeHandles()
        showWorkspaceIndicator(for: screen)
        warpMouseToWorkspace(target, on: screen)
        focusIndicator.pulse()
        reassertShownTabApps()   // opt-in: fix cross-app tab groups left wrong on OTHER shown monitors
    }

    /// With intrinsic numbering there is nothing to "assign" — the ⌘⌥⌃1-9 binding just
    /// switches, like ⌘⌥1-9. Kept so an existing binding stays useful.
    func assignWorkspace(_ n: Int) { switchToWorkspace(n) }

    /// Bounce to the previous workspace (i3 back-and-forth): recency[0] is current, [1] prior.
    func workspaceBack() {
        guard workspaceRecency.count >= 2 else { return }
        switchToWorkspace(workspaceRecency[1])
    }

    /// Cycle to the next/prev workspace ON THE MONITOR UNDER THE MOUSE, among the ones that matter
    /// there (named or non-empty). Lets Ctrl+←/→ flip through a screen's real workspaces without
    /// landing on empty unnamed slots or jumping to another monitor — the natural replacement for
    /// macOS' now-defunct "move a space" gesture in the emulated model. No-op with fewer than two.
    func cycleWorkspace(next: Bool) {
        guard let screen = screenUnderMouse() ?? NSScreen.main else { return }
        let did = displayID(of: screen)
        let candidates = (1...9).filter {
            assignedDisplay(forWorkspace: $0) == did
                && (Config.shared.workspaceNames[$0] != nil || spaces[UInt64($0)]?.root != nil)
        }
        guard candidates.count >= 2 else { return }
        let current = currentWorkspace(for: screen).flatMap { workspaceNumber(for: $0) }
        let target: Int
        if let idx = current.flatMap({ candidates.firstIndex(of: $0) }) {
            target = candidates[(idx + (next ? 1 : -1) + candidates.count) % candidates.count]
        } else {
            target = next ? candidates[0] : candidates[candidates.count - 1]   // from a non-candidate view
        }
        if target != current { switchToWorkspace(target) }
    }

    /// Schematic workspace overview (exposé): a grid of workspaces, each drawn with its
    /// windows as scaled rectangles. Pick one to jump.
    /// From the exposé (a typed jump-hint): switch to workspace `n` and focus window `w`, selecting
    /// its tab if it's in a group. render() raises it and activates its app.
    func focusManagedWindow(_ w: ManagedWindow, onWorkspace n: Int) {
        switchToWorkspace(n)
        var target: Container?
        spaces[UInt64(n)]?.root?.forEachLeaf { if $0.window === w { target = $0 } }
        guard let t = target else { return }
        focused = t
        render()
    }

    func showExpose(commitOnCmdRelease: Bool = false) {
        guard let screen = screenUnderMouse() else { return }
        let current = currentWorkspace(for: screen).flatMap { workspaceNumber(for: $0) }
        let ordered = spaces.keys.compactMap { workspaceNumber(for: $0) }.sorted()
        let shownWs = Set(shownOnDisplay.values.map { Int($0) })   // workspaces on a monitor right now
        var wss: [ExposeWorkspace] = []
        for n in ordered {
            let sid = UInt64(n)
            // Place every workspace in ITS home monitor's column, and compute tile geometry from
            // the tree itself (a pure dry-run into the home monitor's layout rect) rather than
            // reading window frames: a parked workspace's windows are clamped to a ~1px corner by
            // macOS, so their real frames are useless — this shows the true layout regardless.
            let home = homeScreen(forWorkspace: n) ?? screen
            let wsScreen = home.frame
            let frames = spaces[sid]?.root?.previewFrames(in: layoutRect(home)) ?? [:]
            var tiles: [ExposeTile] = []
            spaces[sid]?.root?.forEachTile { tile in
                if tile.isLeaf {
                    guard let w = tile.window else { return }
                    if w.isFullscreen {
                        tiles.append(ExposeTile(frame: wsScreen, tabs: [ExposeTab(label: "⛶ \(w.title)", icon: w.app.icon, selected: true, windowID: w.resolvedID(), focus: { [weak self] in self?.focusManagedWindow(w, onWorkspace: n) })]))
                    } else if let f = frames[ObjectIdentifier(tile)] {
                        tiles.append(ExposeTile(frame: f, tabs: [ExposeTab(label: w.title, icon: w.app.icon, selected: true, windowID: w.resolvedID(), focus: { [weak self] in self?.focusManagedWindow(w, onWorkspace: n) })]))
                    }
                } else {
                    // Tabbed container → one tile with a tab per child (rep = child's first window).
                    let sel = min(max(tile.selected, 0), tile.children.count - 1)
                    guard tile.children.indices.contains(sel),
                          let f = frames[ObjectIdentifier(tile)] else { return }
                    let tabs = tile.children.enumerated().map { i, c -> ExposeTab in
                        let w = c.firstLeaf().window
                        return ExposeTab(label: w?.title ?? "—", icon: w?.app.icon, selected: i == sel, windowID: w?.resolvedID(),
                                         focus: w.map { win in { [weak self] in self?.focusManagedWindow(win, onWorkspace: n) } })
                    }
                    tiles.append(ExposeTile(frame: f, tabs: tabs))
                }
            }
            wss.append(ExposeWorkspace(
                title: Config.shared.workspaceNames[n] ?? "Workspace \(n)",
                screen: wsScreen, tiles: tiles, current: n == current, shown: shownWs.contains(n),
                jump: { [weak self] in self?.switchToWorkspace(n) }))
        }
        ExposeOverlay.show(wss, on: screen, allScreens: Config.shared.exposeAllScreens,
                           commitOnRelease: commitOnCmdRelease)
    }

    /// Stop managing workspace `n`: tear its tree down, drop it, and un-show it anywhere it's
    /// placed (its windows are left where they are, un-dimmed and un-tiled).
    func unassignWorkspace(_ n: Int) {
        let key = UInt64(n)
        guard let ws = spaces[key] else { return }
        ws.root?.forEachLeaf { if let w = $0.window, let wid = AX.windowID(w.element) { w.setAlpha(1, id: wid) } }
        ws.root?.teardown()
        spaces[key] = nil
        for (did, v) in shownOnDisplay where v == key { shownOnDisplay[did] = nil }
        if activeSpaceID == key { activeSpaceID = nil }
        workspaceRecency.removeAll { $0 == n }
        focusIndicator.hide()
        saveNow()
        if let screen = screenUnderMouse() {
            checkSpaceChange()                    // re-bootstrap a workspace on this monitor
            showWorkspaceIndicator(for: screen)   // refresh HUD / status.json / bar
        }
    }

    /// Stop managing the workspace shown on the monitor under the mouse.
    func unassignCurrent() {
        guard let screen = screenUnderMouse(),
              let n = currentWorkspace(for: screen).flatMap({ workspaceNumber(for: $0) }) else { return }
        unassignWorkspace(n)
    }

    /// Vimium-style window hints: label every visible window; typing its letter focuses it.
    func showHints() {
        let onScreen = AX.onScreenWindowIDs()
        var targets: [HintTarget] = []
        // Screens left→right (leftmost first), so the earliest letters land on the left.
        for screen in NSScreen.screens.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            guard let sid = currentWorkspace(for: screen), let root = spaces[sid]?.root else { continue }
            var perScreen: [HintTarget] = []
            root.forEachVisibleLeaf { leaf in   // skip hidden tabs/stacks
                guard let w = leaf.window, let id = AX.windowID(w.element), onScreen.contains(id),
                      let axFrame = w.frame else { return }
                perScreen.append(HintTarget(frameCocoa: Geometry.flip(axFrame),
                                            focus: { [weak self] in self?.focusVisibleWindow(leaf) }))
            }
            // Reading order within the screen: group windows into ROWS (tops within a tolerance —
            // real AX frames jitter by a title bar or two even when tiled to the same top), then
            // order each row left→right. A single tolerance-band comparator is NOT a valid strict
            // weak ordering (intransitive across a chain of near-equal tops), which made Swift's
            // sort swap adjacent labels — the "f/g inverted" bug. Explicit clustering is deterministic.
            let rowTolerance: CGFloat = 40
            var rows: [[HintTarget]] = []
            for t in perScreen.sorted(by: { $0.frameCocoa.maxY > $1.frameCocoa.maxY }) {   // top→bottom
                if let head = rows.last?.first, abs(head.frameCocoa.maxY - t.frameCocoa.maxY) <= rowTolerance {
                    rows[rows.count - 1].append(t)
                } else {
                    rows.append([t])
                }
            }
            for row in rows {
                targets.append(contentsOf: row.sorted { $0.frameCocoa.minX < $1.frameCocoa.minX })   // left→right
            }
        }
        HintsOverlay.show(targets)
    }

    /// Focus a hinted window. If it's on another screen/desktop, warp the mouse onto it so
    /// the mouse-follows model adopts that desktop, then move Mosaic's focus + border there.
    func focusVisibleWindow(_ leaf: Container) {
        guard let w = leaf.window else { return }
        AX.makeMain(w.element); w.activateApp(); AX.raise(w.element)
        if treeContainsLeaf(leaf) {              // already on the active desktop
            focused = leaf
            updateFocusIndicator()
        } else if let f = w.frame {              // another screen → follow it there
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))   // AX frame is CG (top-left)
            CGAssociateMouseAndMouseCursorPosition(1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self else { return }
                self.checkSpaceChange()
                self.focused = leaf
                self.updateFocusIndicator()
            }
        }
    }

    /// Fuzzy quick-switcher: jump to a workspace (by name/number) or a window (by title).
    /// Ordered by recency (most-recently-used first); the current workspace sinks to the
    /// bottom so ⏎ on the top row jumps somewhere useful.
    func showSwitcher() {
        guard let screen = screenUnderMouse() else { return }
        let current = currentWorkspace(for: screen).flatMap { workspaceNumber(for: $0) }
        let ordered = spaces.keys.compactMap { workspaceNumber(for: $0) }.sorted { a, b in
            if a == current { return false }
            if b == current { return true }
            let ia = workspaceRecency.firstIndex(of: a) ?? Int.max
            let ib = workspaceRecency.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a < b
        }
        var wsItems: [SwitcherItem] = []
        var winItems: [SwitcherItem] = []
        for n in ordered {
            let root = spaces[UInt64(n)]?.root
            var count = 0
            root?.forEachLeaf { if $0.window != nil { count += 1 } }
            wsItems.append(SwitcherItem(
                kind: .workspace,
                title: Config.shared.workspaceNames[n] ?? "Workspace \(n)",
                subtitle: count == 1 ? "1 window" : "\(count) windows",
                badge: "\(n)", icon: nil,
                run: { [weak self] in self?.switchToWorkspace(n) },
                moveHere: { [weak self] in self?.moveToWorkspace(n) }))
            root?.forEachLeaf { leaf in
                guard let w = leaf.window else { return }
                winItems.append(SwitcherItem(
                    kind: .window, title: w.title, subtitle: w.appName, badge: "\(n)", icon: w.app.icon,
                    run: { [weak self] in self?.focusWindow(w, inWorkspace: n) },
                    moveHere: { [weak self] in self?.moveToWorkspace(n) }))
            }
        }
        var navSections: [SwitcherSection] = []
        if !wsItems.isEmpty { navSections.append(SwitcherSection(header: "Workspaces", items: wsItems)) }
        if !winItems.isEmpty { navSections.append(SwitcherSection(header: "Windows", items: winItems)) }

        let actionItems = (switcherActions?() ?? []).map { a in
            SwitcherItem(kind: .action, title: Self.prettyAction(a.title), subtitle: Self.prettyShortcut(a.subtitle),
                         badge: "▸", icon: nil, run: a.run, moveHere: nil)
        }
        SwitcherPanel.present(modes: [
            SwitcherMode(name: "Go", sections: navSections),
            SwitcherMode(name: "Actions", sections: [SwitcherSection(header: "Mosaic actions", items: actionItems)]),
        ], on: screen)
    }

    static func prettyAction(_ key: String) -> String {
        let s = key.replacingOccurrences(of: "-", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
    static func prettyShortcut(_ combo: String) -> String {
        guard !combo.isEmpty else { return "" }
        return combo.split(separator: " ").map { part -> String in
            switch part {
            case "cmd": return "⌘"; case "alt": return "⌥"; case "ctrl": return "⌃"; case "shift": return "⇧"
            case "return": return "↩"; case "left": return "←"; case "right": return "→"
            case "up": return "↑"; case "down": return "↓"; case "equal": return "="
            case "minus": return "-"; case "period": return "."; case "comma": return ","
            default: return part.count == 1 ? part.uppercased() : String(part)
            }
        }.joined()
    }

    /// Bring a specific window forward: switch its workspace onto this monitor if it isn't
    /// already shown, then activate it. The focus-sync observer adopts it into Mosaic's focus.
    func focusWindow(_ w: ManagedWindow, inWorkspace n: Int) {
        if let screen = screenUnderMouse(), currentWorkspace(for: screen) != UInt64(n) {
            switchToWorkspace(n)
        }
        // A native-fullscreen window lives on its own Space: makeMain/raise (both do kAXRaiseAction)
        // would yank that Space forward uncontrollably. Activating its app is the controlled way in.
        guard !w.isFullscreen else { w.activateApp(); return }
        AX.makeMain(w.element)
        w.activateApp()
        AX.raise(w.element)
    }

    /// Toggle a floating, live picture-in-picture of the focused window. The window keeps playing
    /// wherever it is (even parked on another workspace); "return" from the PiP brings it back here.
    func togglePiP() {
        guard #available(macOS 13.0, *) else { NSLog("Mosaic: PiP needs macOS 13+"); return }
        if PiP.shared.isActive { PiP.shared.stop(); return }   // toggle off — onStop clears the cover
        guard let leaf = focused, let w = leaf.window, let id = w.resolvedID() else {
            NSLog("Mosaic: PiP — no focused window"); return
        }
        let ws = Int(activeSpaceID ?? 1)   // workspace to return to, captured now
        PiP.shared.onStop = { [weak self] in            // remove the source's letterbox cover
            self?.pipSourceLeaf = nil
            self?.updateLetterboxFill()
        }
        PiP.shared.toggle(windowID: id, pid: w.app.processIdentifier) { [weak self, weak leaf] in
            guard let self, let leaf else { return }
            self.revealForPiP(leaf, inWorkspace: ws)
        }
        pipSourceLeaf = leaf            // cover its on-screen tile so the video isn't shown twice
        updateLetterboxFill()
    }

    /// Return from the PiP onto the source window: switch to its workspace, re-select it along its
    /// tab path (so a tabbed window surfaces, not just its app), re-render, then activate it.
    func revealForPiP(_ leaf: Container, inWorkspace n: Int) {
        if let screen = screenUnderMouse(), currentWorkspace(for: screen) != UInt64(n) {
            switchToWorkspace(n)
        }
        focused = leaf
        selectTabsOnPath(to: leaf)
        render()
        guard let w = leaf.window else { return }
        guard !w.isFullscreen else { w.activateApp(); return }
        AX.makeMain(w.element)
        w.activateApp()
        AX.raise(w.element)
    }

    /// Send the focused window to workspace `n`: detach it from the current tree and graft it
    /// into `n`'s. If `n` is shown on a monitor it's re-arranged there; otherwise it stays
    /// parked and the window slides off-screen with it.
    func moveToWorkspace(_ n: Int) {
        checkSpaceChange()
        moveFocused(toWorkspace: n)
    }

    func moveFocused(toWorkspace n: Int) {
        let target = UInt64(n)
        guard let leaf = focused, leaf.window != nil, target != activeSpaceID else { return }
        detach(leaf)
        leaf.parent = nil

        let tst = workspaceOffscreen(n)   // fetch/create; don't change where it's placed
        appendLeaf(leaf, to: tst)
        if let r = tst.root { wireTabCallbacks(r) }
        if let scr = screen(forWorkspace: target) {   // shown somewhere → tile it there
            tst.root?.arrange(in: layoutRect(scr))
            tst.root?.raiseVisibleWindows()   // skips fullscreen (Space yank) + hidden tabs (wrong tab surfacing)
        } else {
            parkWorkspace(tst)   // parked destination → the moved window follows off-screen
        }

        if focused == nil || !treeContainsLeaf(focused!) { focused = root?.firstLeaf() }
        render()
        saveNow()
    }

    /// The screen a workspace is currently placed on (nil if parked / not shown anywhere).
    func screen(forWorkspace space: UInt64) -> NSScreen? {
        guard let ws = spaces[space], ws.displayID != 0,
              shownOnDisplay[ws.displayID] == space else { return nil }
        return screen(forDisplayID: ws.displayID)
    }

    /// Fetch/create a workspace WITHOUT changing which monitor it's placed on — for the parked
    /// destination of a move. A new one is homed on the current monitor so it can be parked
    /// off-screen relative to a real display (a displayID-0 workspace can't be parked).
    @discardableResult
    func workspaceOffscreen(_ n: Int) -> SpaceState {
        let key = UInt64(n)
        if let ws = spaces[key] { return ws }
        // Home it on its pinned monitor (model A) so a parked destination parks on the right
        // display; fall back to the mouse's monitor if that one isn't present.
        let did = assignedDisplay(forWorkspace: n) ?? screenUnderMouse().map(displayID(of:)) ?? 0
        let s = SpaceState(displayID: did)
        s.mode = defaultMode
        spaces[key] = s
        return s
    }

    /// Move a just-opened window to another workspace and tile it there, without touching the
    /// current tree (used by the `workspace` app rule). Shown → tiled on its monitor; parked →
    /// slides off-screen with it.
    func placeOnWorkspace(_ window: ManagedWindow, n: Int) {
        let target = UInt64(n)
        let tst = workspaceOffscreen(n)
        appendLeaf(Container(window: window), to: tst)
        if let r = tst.root { wireTabCallbacks(r) }
        if let scr = screen(forWorkspace: target) {
            tst.root?.arrange(in: layoutRect(scr))
            tst.root?.raiseVisibleWindows()   // skips fullscreen (Space yank) + hidden tabs (wrong tab surfacing)
        } else {
            parkWorkspace(tst)
        }
        NSLog("Mosaic: rule placed \(window.appName) on workspace \(n)")
        scheduleSave()
    }

    /// Optionally move the cursor onto the just-switched workspace so the mouse-follows model
    /// stays aligned. `screen` is the monitor the workspace was placed on.
    func warpMouseToWorkspace(_ space: UInt64, on screen: NSScreen) {
        guard Config.shared.warpMouseOnSwitch else { return }
        let cocoa: CGPoint
        if let st = spaces[space], let f = (st.focused ?? st.root?.firstLeaf())?.window?.frame {
            let r = Geometry.flip(f)
            cocoa = CGPoint(x: r.midX, y: r.midY)
        } else {
            cocoa = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        }
        let cg = CGPoint(x: cocoa.x, y: Geometry.primaryHeight - cocoa.y)   // Cocoa → CG (top-left)
        CGWarpMouseCursorPosition(cg)
        CGAssociateMouseAndMouseCursorPosition(1)   // avoid the post-warp cursor freeze
    }

    /// A synthetic workspace id maps back to its number when it's a live managed workspace
    /// (1-9). No CGS Space lookup — the number IS the id.
    func workspaceNumber(for space: UInt64) -> Int? {
        guard space >= 1, space <= 9, spaces[space] != nil else { return nil }
        return Int(space)
    }

    /// No-op in the emulated model: workspace numbers are intrinsic, nothing to prune.
    func pruneStaleAssignments() {}

    /// Distinct app icons of the windows living in workspace `n`, in tree order (one per app, so a
    /// workspace with three Finder windows shows one Finder icon). Feeds the HUD's at-a-glance row.
    func workspaceAppIcons(_ n: Int) -> [NSImage] {
        var seen = Set<pid_t>()
        var icons: [NSImage] = []
        spaces[UInt64(n)]?.root?.forEachLeaf { leaf in
            guard let w = leaf.window else { return }
            if seen.insert(w.app.processIdentifier).inserted, let icon = w.app.icon { icons.append(icon) }
        }
        return icons
    }

    func showWorkspaceIndicator(for screen: NSScreen) {
        guard let space = currentWorkspace(for: screen) else { return }
        let number = workspaceNumber(for: space)
        emitWorkspaceState(number)   // menu-bar icon + status file + shell hook (sketchybar…)
        // HUD: the row of THIS monitor's workspaces, so the switch also shows which of the
        // others hold windows (a dot) — the at-a-glance answer to "where did my window go?".
        guard let current = number else { return }
        // Notch dynamic-island HUD replaces the top-right strip when enabled.
        if Config.shared.notchHud {
            let name = (Config.shared.workspaceNames[current] ?? "")
                .replacingOccurrences(of: "^\\s*\\d+\\s*[-·:]?\\s*", with: "", options: .regularExpression)
            notchHUD.show(workspace: current, name: name, icons: workspaceAppIcons(current), on: screen)
            return
        }
        guard Config.shared.showWorkspaceHUD else { return }
        let did = displayID(of: screen)
        let items: [WorkspaceHUDItem] = (1...9)
            .filter { assignedDisplay(forWorkspace: $0) == did }
            .map { n in WorkspaceHUDItem(number: n, name: Config.shared.workspaceNames[n],
                                         icons: workspaceAppIcons(n),
                                         occupied: spaces[UInt64(n)]?.root != nil, current: n == current) }
        workspaceHUD.show(items, on: screen, position: Config.shared.hudPosition)
    }

    var statusURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mosaic/status.json")
    }

    /// Publish the current workspace state: update the menu bar, write status.json (for
    /// `mosaic query`), and run the configured shell hook on change (for sketchybar & co).
    func emitWorkspaceState(_ focused: Int?) {
        pruneStaleAssignments()
        if let n = focused, workspaceRecency.first != n {
            workspaceRecency.removeAll { $0 == n }
            workspaceRecency.insert(n, at: 0)
        }
        onWorkspaceChanged?(focused)
        writeStatusFile(focused: focused)
        if focused != lastEmittedWorkspace {
            lastEmittedWorkspace = focused
            runWorkspaceHook(focused)
        }
    }

    func writeStatusFile(focused: Int?) {
        var monitors: [[String: Any]] = []
        for screen in NSScreen.screens {
            guard let sp = currentWorkspace(for: screen) else { continue }
            monitors.append(["display": Int(displayID(of: screen)),
                             "workspace": workspaceNumber(for: sp).map { $0 as Any } ?? NSNull(),
                             "mode": (spaces[sp]?.mode).map { "\($0)" } ?? NSNull()])
        }
        // Optional i3-style names, only for workspaces that have one.
        var names: [String: String] = [:]
        // The monitor (CGDirectDisplayID) each workspace is pinned to — its HOME display, stable
        // whether the workspace is currently shown or parked. An external bar pins each pill to its
        // own monitor with this; using the *shown* display instead made parked workspaces (absent
        // here) fall back and pile their pills onto one screen. `assignedDisplay` recomputes over
        // present monitors, so an undocked workspace still maps to a present screen.
        var wsDisplays: [String: Int] = [:]
        let numbers = spaces.keys.compactMap { workspaceNumber(for: $0) }
        for n in numbers {
            if let nm = Config.shared.workspaceNames[n], !nm.isEmpty { names[String(n)] = nm }
            if let did = assignedDisplay(forWorkspace: n) {
                wsDisplays[String(n)] = Int(did)
            }
        }
        let dict: [String: Any] = [
            "focused": focused.map { $0 as Any } ?? NSNull(),
            "mode": (active?.mode).map { "\($0)" } ?? NSNull(),   // tiling mode of the active workspace
            "workspaces": numbers.sorted(),
            "workspaceNames": names,
            "workspaceDisplays": wsDisplays,
            "attention": attentionWorkspaces.sorted(),   // parked workspaces with unseen activity
            "monitors": monitors,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: statusURL, options: .atomic)
    }

    func runWorkspaceHook(_ focused: Int?) {
        let cmd = Config.shared.onWorkspaceChange
        guard !cmd.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        var env = ProcessInfo.processInfo.environment
        env["MOSAIC_WORKSPACE"] = focused.map(String.init) ?? ""
        // A GUI app inherits a minimal PATH; prepend the usual Homebrew/local bins so
        // `sketchybar`, `mosaic`, etc. resolve from the hook.
        let extra = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
        p.environment = env
        try? p.run()   // exec-and-forget
    }

    /// Append a leaf as a new column in a (possibly non-active) desktop's tree.
    func appendLeaf(_ leaf: Container, to state: SpaceState) {
        guard let r = state.root else { state.root = leaf; return }
        if !r.isLeaf, r.layout != .tabbed {
            r.children.append(leaf)
            leaf.parent = r
            r.addRatio(at: r.children.count - 1)
        } else {
            state.root = Container(layout: .splitH, children: [r, leaf])
        }
    }

    /// Designate the focused window's APP as the scratchpad (its windows leave tiling and hide).
    /// The same combo RELEASES the scratchpad when it's shown OR when the focused window belongs
    /// to the current scratchpad app — so you can always get an app back out (e.g. a multi-window
    /// app like Firefox: focus any of its windows and press it again).
    func sendToScratchpad() {
        checkSpaceChange()
        if let bundle = scratchpadBundleID,
           scratchpadVisible || focused?.window?.app.bundleIdentifier == bundle {
            releaseScratchpad()
            return
        }
        guard let leaf = focused, let w = leaf.window, let bundle = w.app.bundleIdentifier else { return }
        // The scratchpad floats the app's ENTIRE window set (it's tracked by bundle id, so it
        // survives the app closing/reopening). For a multi-window app that means every window
        // leaves tiling — warn, but honor it: releasing brings them all back.
        if AX.standardWindows(ofPID: w.pid).count > 1 {
            NSLog("Mosaic: scratchpad app \(w.appName) has multiple windows — all of them will float; press send-to-scratchpad again to release")
        }
        scratchpadBundleID = bundle
        scratchpadVisible = false
        detach(leaf)
        AX.setMinimized(w.element, true)
        if focused == nil || !treeContainsLeaf(focused!) { focused = root?.firstLeaf() }
        saveNow()
        render()
    }

    /// Release the scratchpad unconditionally: un-minimize EVERY window of the scratchpad app
    /// and let reconcile re-tile them. The safety valve for "I can't get my app back out",
    /// especially for a multi-window app whose whole window set was floated.
    func releaseScratchpad() {
        guard let bundle = scratchpadBundleID else { return }
        scratchpadBundleID = nil   // clear FIRST so captureWindows stops excluding the app
        scratchpadVisible = false
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundle {
            for win in AX.standardWindows(ofPID: app.processIdentifier) { AX.setMinimized(win, false) }
        }
        saveNow()
        reconcile()   // re-adopt every now-visible window of the app into the active workspace
        render()
    }

    /// Show the scratchpad app floating on the current desktop, or hide it if shown.
    func toggleScratchpad() {
        guard scratchpadBundleID != nil else {
            NSLog("Mosaic: no scratchpad set — focus a window and use send-to-scratchpad")
            return
        }
        guard let w = scratchpadWindow() else {
            NSLog("Mosaic: scratchpad app has no window (not running?)")
            return
        }
        if scratchpadVisible {
            AX.setMinimized(w.element, true)
            scratchpadVisible = false
            render()   // restore the tiles' tab bars & focus border
            return
        }
        guard let screen = screenUnderMouse() else { return }   // no screen → nothing to float on
        // No CGS move: there is a single macOS Space, so the window is already here — just
        // un-minimize and position it as a floating panel on the monitor under the mouse.
        AX.setMinimized(w.element, false)
        let vf = screen.visibleFrame
        let rect = NSRect(x: vf.midX - vf.width * 0.35, y: vf.midY - vf.height * 0.35,
                          width: vf.width * 0.7, height: vf.height * 0.7)
        w.setCocoaFrame(rect)
        AX.raise(w.element)
        w.activateApp()
        if let wid = AX.windowID(w.element) { w.setAlpha(1, id: wid) }   // full opacity
        scratchpadVisible = true
        // Hide the floating overlays so they don't sit on top of the scratchpad.
        active?.root?.forEachTabbed { $0.hideStrip() }
        hideAllHandles()
        focusIndicator.hide()
    }

    /// Resolve the scratchpad app's first standard window (incl. minimized), if running.
    func scratchpadWindow() -> ManagedWindow? {
        guard let bundle = scratchpadBundleID else { return nil }
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == bundle && app.activationPolicy == .regular {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows: [AXUIElement] = AX.copy(axApp, kAXWindowsAttribute as String) else { continue }
            for element in windows where AX.subrole(element) == (kAXStandardWindowSubrole as String) {
                return ManagedWindow(ref: AX.WindowRef(element: element, pid: app.processIdentifier))
            }
        }
        return nil
    }

    func toggleFloatFocusedApp() {
        checkSpaceChange()
        guard let f = focused, let w = f.window else { return }
        let key = w.appName.lowercased()
        if floatingApps.contains(key) { floatingApps.remove(key) } else { floatingApps.insert(key) }
        reconcile()
    }

}

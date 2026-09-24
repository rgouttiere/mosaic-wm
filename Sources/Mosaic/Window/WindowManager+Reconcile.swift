import AppKit

extension WindowManager {
    // MARK: - Entry points

    /// Start (or rebuild) management of the workspace shown on the monitor under the mouse.
    func tileCurrentSpace() {
        guard let screen = screenUnderMouse() else { return }
        let did = displayID(of: screen)
        let id = shownOnDisplay[did] ?? UInt64(defaultWorkspaceNumber(for: screen))
        shownOnDisplay[did] = id
        let st = SpaceState(displayID: did)
        st.mode = spaces[id]?.mode ?? defaultMode
        spaces[id] = st
        activeSpaceID = id
        build()
    }

    /// Panic recovery / stuck-off-screen heal (M5): bring every managed window back to a
    /// known-good state. Un-minimizes any window that got stuck minimized (e.g. minimized while
    /// its workspace was parked — `setCocoaFrame` alone won't wake a minimized window), then
    /// re-asserts every workspace's placement (re-tile the shown ones, re-park the rest). Use it
    /// whenever a window seems lost: nothing is ever destroyed, only re-placed.
    func recover() {
        checkSpaceChange()
        for ws in spaces.values {
            ws.root?.forEachLeaf { leaf in
                guard let w = leaf.window else { return }
                if AX.isMinimized(w.element) { AX.setMinimized(w.element, false) }
            }
        }
        // Learned resize minimums are derived state, re-learned on the next drag — and a poisoned
        // entry (a window that read back bigger than its tile) is exactly the kind of stuck this key
        // is for: it narrows or freezes a split and used to survive everything short of a restart.
        resizeMinCache.removeAll()
        lastResizePair = nil
        // A "lost"/stuck-off-screen window got there by an external move we didn't track, so its
        // frame cache is stale — drop it, else reassert recomputes the same rect and setCocoaFrame
        // skips the corrective write (the heal would no-op on exactly the windows it's meant to save).
        invalidateAllFrameCaches()
        reassertAllWorkspaces()
        updateFocusIndicator()
        NSLog("Mosaic: recover — un-minimized stuck windows + re-asserted all workspaces + dropped resize minimums")
    }

    /// Cycle the build strategy for the current desktop and rebuild it.
    func cycleMode() {
        checkSpaceChange()
        guard let st = active else { return }
        let all = Mode.allCases
        if let i = all.firstIndex(of: st.mode) { st.mode = all[(i + 1) % all.count] }
        build()
        // Republish so an external bar reflects the new tiling mode immediately (the focused
        // workspace is unchanged, so the normal change-gated hook wouldn't fire on its own).
        let n = activeScreen.flatMap { currentWorkspace(for: $0) }.flatMap { workspaceNumber(for: $0) }
        writeStatusFile(focused: n)
        runWorkspaceHook(n)
    }

    /// Toggle "manage every desktop": when on, visiting any unmanaged desktop tiles it.
    func toggleManageAll() {
        manageAll.toggle()
        if manageAll { activeSpaceID = nil; checkSpaceChange() }   // re-detect + build the current workspace
        NSLog("Mosaic: manage-all = \(manageAll)")
    }

    /// Stop managing the current desktop (others keep their layouts).
    func clear() {
        if let id = activeSpaceID, let st = spaces[id] {
            st.root?.forEachLeaf { if let w = $0.window, let wid = AX.windowID(w.element) { w.setAlpha(1, id: wid) } }
            st.root?.teardown()
            spaces[id] = nil
        }
        focusIndicator.hide()
    }

    /// Restore full opacity on every managed window (called on quit so nothing stays dimmed).
    func resetAllOpacity() {
        for state in spaces.values {
            state.root?.forEachLeaf {
                if let w = $0.window, let id = AX.windowID(w.element) { w.setAlpha(1, id: id) }
            }
        }
    }

    // MARK: - Tick (desktop switch + window changes)

    func tick() {
        guard !suspended else { return }
        checkSpaceChange()
        enforceFullscreenRules()
        enforceEmulatedFullscreen()
        reconcile()
    }

    /// Global "strict emulated" eject (opt-in `ejectNativeFullscreen`): a MANAGED window that
    /// enters native macOS full screen escapes onto its own Space, out of the emulated
    /// workspace. When enabled, send it back to windowed so it stays tiled. Apps a per-app rule
    /// pins to `fullscreen: true` are left alone. OFF by default — native full screen otherwise
    /// degrades gracefully (the tile keeps its slot and reclaims it on exit), and the non-native
    /// "maximize" is the monocle zoom (⌘⌥Return). Zero cost when off.
    func enforceEmulatedFullscreen() {
        guard Config.shared.ejectNativeFullscreen else { return }
        let allowed = Config.shared.rules.filter { $0.fullscreen == true }.map { $0.app.lowercased() }
        for ws in spaces.values {
            ws.root?.forEachLeaf { leaf in
                guard let w = leaf.window, w.isFullscreen else { return }
                let name = w.appName.lowercased(), bundle = (w.app.bundleIdentifier ?? "").lowercased()
                if allowed.contains(where: { name.contains($0) || bundle.contains($0) }) { return }
                AX.setFullscreen(w.element, false)   // back to windowed → stays in its tile
            }
        }
    }


    /// Enforce per-app `fullscreen` rules. Some apps (e.g. Ferdium) restore themselves into
    /// native macOS full screen, where they live on their own Space and can't be tiled. A
    /// rule `{"app":"ferdium","fullscreen":false}` forces such a window back to windowed so
    /// the next reconcile can manage it; `true` forces it into full screen.
    ///
    /// `fullscreenLock: true` keeps enforcing the state every tick (a hard lock). Otherwise
    /// the state is applied ONCE when a window first appears, then left alone — so the user
    /// can freely toggle full screen afterwards. No-op — and zero cost — unless at least one
    /// fullscreen rule exists.
    func enforceFullscreenRules() {
        let rules = Config.shared.rules.filter { $0.fullscreen != nil }
        guard !rules.isEmpty else { fullscreenApplied.removeAll(); return }
        var seen = Set<CGWindowID>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let name = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            guard let rule = rules.first(where: {
                name.contains($0.app.lowercased()) || bundle.contains($0.app.lowercased())
            }), let want = rule.fullscreen else { continue }
            let lock = rule.fullscreenLock ?? false
            for window in AX.standardWindows(ofPID: app.processIdentifier) {
                let wid = AX.windowID(window)
                if let wid { seen.insert(wid) }
                if lock {
                    if AX.isFullscreen(window) != want { AX.setFullscreen(window, want) }
                } else {   // on-open: set once per window, then leave it user-toggleable
                    guard let wid, !fullscreenApplied.contains(wid) else { continue }
                    // Mark applied only once the state is actually achieved — already matching,
                    // or the write was accepted. A window still animating on open often rejects
                    // the write; recording it applied there would defeat the on-open rule forever
                    // (the set is pruned only when the window disappears). Gate on the write
                    // RESULT, never a read-back: AXFullScreen kicks off an async Space transition,
                    // so a read right after would still report the old value and re-fire every tick.
                    if AX.isFullscreen(window) == want || AX.setFullscreen(window, want) {
                        fullscreenApplied.insert(wid)
                    }
                }
            }
        }
        fullscreenApplied.formIntersection(seen)   // forget closed windows → reopened re-apply
    }

    // MARK: - Build

    func build() {
        guard let screen = activeScreen else { return }
        let windows = captureWindows(on: screen)
        resizeMinCache.removeAll()   // keyed by object identity → stale once the tree is rebuilt
        root?.teardown()
        guard !windows.isEmpty else {
            root = nil
            focused = nil
            focusIndicator.hide()
            return
        }
        let tree = makeTree(mode, from: windows)
        wireTabCallbacks(tree)
        root = tree
        focused = tree.firstLeaf()
        observer.watchForClose(windows)
        render()
    }

    func makeTree(_ mode: Mode, from windows: [ManagedWindow]) -> Container {
        switch mode {
        case .columns:
            return windows.count == 1 ? Container(window: windows[0])
                                      : Container(layout: .splitH, children: windows.map(Container.init))
        case .grouped:
            let groups = groupByApp(windows).map { group -> Container in
                group.count == 1 ? Container(window: group[0])
                                 : Container(layout: .tabbed, children: group.map(Container.init))
            }
            return groups.count == 1 ? groups[0] : Container(layout: .splitH, children: groups)
        case .tabbed:
            return windows.count == 1 ? Container(window: windows[0])
                                      : Container(layout: .tabbed, children: windows.map(Container.init))
        case .masterStack:
            // First window = master (left); the rest = one tabbed stack (right). No slivers.
            guard windows.count > 1 else { return Container(window: windows[0]) }
            let master = Container(window: windows[0])
            let rest = windows.dropFirst().map(Container.init)
            let stack = rest.count == 1 ? rest[0] : Container(layout: .tabbed, children: Array(rest))
            return Container(layout: .splitH, children: [master, stack])
        }
    }

    func groupByApp(_ windows: [ManagedWindow]) -> [[ManagedWindow]] {
        var order: [pid_t] = []
        var byApp: [pid_t: [ManagedWindow]] = [:]
        for window in windows {
            if byApp[window.pid] == nil { order.append(window.pid) }
            byApp[window.pid, default: []].append(window)
        }
        return order.map { byApp[$0]! }
    }

    // MARK: - Live reconcile

    /// Guarantee each window lives in exactly one Space's tree. A cross-Space tab drag, or a
    /// window that drifted to another display, can leave a stale duplicate leaf → the same
    /// window then shows in two tab bars. Keep the copy on the display the window is on.
    func dedupTrees() {
        var seen: [CGWindowID: [(sid: UInt64, leaf: Container)]] = [:]
        for (sid, state) in spaces {
            state.root?.forEachLeaf { leaf in
                // Key on the cached id first: dedup only needs to match the same window across
                // trees, and lastKnownID is a stable per-window CGWindowID. resolvedID() is a
                // synchronous cross-process AX call, and this walk runs over EVERY leaf of EVERY
                // space on each reconcile — paying that IPC here (only to skip it via ??) stalls
                // the main thread. dedup doesn't rely on resolvedID()'s side effects.
                guard let w = leaf.window, let id = w.lastKnownID ?? w.resolvedID() else { return }
                seen[id, default: []].append((sid, leaf))
            }
        }
        for (_, occ) in seen where occ.count > 1 {
            var owner = occ[0].sid
            if let w = occ[0].leaf.window, let f = w.frame {
                let c = Geometry.flip(f)
                if let scr = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: c.midX, y: c.midY)) }),
                   let sid = currentWorkspace(for: scr), occ.contains(where: { $0.sid == sid }) {
                    owner = sid
                }
            }
            for entry in occ where entry.sid != owner {
                if let state = spaces[entry.sid] { removeLeaf(entry.leaf, from: state) }
            }
        }
    }

    /// Structurally remove a leaf from a (possibly non-active) Space's tree + collapse.
    func removeLeaf(_ leaf: Container, from state: SpaceState) {
        if let parent = leaf.parent, let i = parent.index(of: leaf) {
            parent.removeChild(at: i)   // adjusts `selected` for the lower-index shift too
            collapse(parent, in: state)
        } else if state.root === leaf {
            state.root = nil
        }
        leaf.hideStrip()
        if let sr = state.root, let sf = state.focused, !contains(sr, sf) { state.focused = sr.firstLeaf() }
        else if state.root == nil { state.focused = nil }
    }

    /// A window was definitively destroyed (AX "destroyed" notification) → remove its leaf
    /// from whatever Space holds it and re-render immediately, skipping the reconcile's
    /// miss-count grace. A closed app's tile/tab then vanishes instantly instead of after
    /// ~0.5s (or needing a manual focus nudge). The debounced reconcile still runs after as
    /// a backstop for anything not resolved here.
    func reconcile() {
        // NOT `let root`: an empty active workspace (root == nil) must still reconcile so a window
        // opened on a fresh/emptied workspace gets adopted — insert() seeds a nil root. activeScreen
        // already implies the active workspace exists.
        guard !suspended, !isReconciling, let screen = activeScreen else { return }
        isReconciling = true
        let __perf = DispatchTime.now(); defer { Perf.record("reconcile", since: __perf) }
        defer { isReconciling = false }
        let onScreen = AX.onScreenWindowIDs()
        dedupTrees()

        var aliveTreeIDs = Set<CGWindowID>()          // ids we must not re-add as "new" (incl. a stale leaf's, during grace)
        var aliveConfirmedIDs = Set<CGWindowID>()     // ids we POSITIVELY resolved as alive — for switch-detection only
        var deadLeaves: [Container] = []
        var staleLeaves: [Container] = []   // has a window, but AX couldn't resolve its id now
        root?.forEachLeaf { leaf in
            guard let w = leaf.window else { deadLeaves.append(leaf); return }   // no window at all
            if let id = w.resolvedID() {
                // A full-screened window (e.g. a video) is temporarily on its own Space.
                // Keep it in the tree — neither counted as present nor detached — so it
                // returns to its exact place when it leaves full screen. Only its content
                // isn't arranged/raised while full screen (handled in Container).
                if !w.isFullscreen { aliveTreeIDs.insert(id); aliveConfirmedIDs.insert(id) }
                return
            }
            // A hidden app (Cmd-H) leaves the screen but must keep its slot — treat like
            // full screen, never as a close. (Its windows aren't in captureWindows either,
            // so they won't be re-inserted elsewhere.)
            if w.app.isHidden {
                w.missCount = 0
                // Keep its slot (aliveTreeIDs) but NOT in aliveConfirmedIDs: a hidden window is off
                // the on-screen list, so counting it there would make the switch-detection at line
                // ~301 (confirmed-alive ∩ onScreen == ∅) misfire when a whole workspace is hidden.
                if let cached = w.lastKnownID { aliveTreeIDs.insert(cached) }
                return
            }
            // AX couldn't resolve the window. It might be a transient glitch, a real close,
            // or an app swapping this window for a new one (IINA replaces its launcher window
            // with the video window). Defer the verdict until we've captured the current
            // windows: a same-app newcomer can then be adopted into this exact slot, and only
            // a leaf with no replacement is aged out. Meanwhile keep the slot alive.
            if let cached = w.lastKnownID, onScreen.contains(cached) {
                w.missCount = 0
                aliveTreeIDs.insert(cached); aliveConfirmedIDs.insert(cached)
            } else {
                staleLeaves.append(leaf)
                if let cached = w.lastKnownID { aliveTreeIDs.insert(cached) }   // keep during grace
            }
        }

        // None of our windows visible → we've switched desktops; leave it untouched.
        // Gate on POSITIVELY-alive ids only, never aliveTreeIDs: a stale leaf (a just-closed window,
        // incl. the workspace's LAST one) keeps its cached id in aliveTreeIDs during grace — counting
        // it here would make a real close look like a desktop switch, skip the removal, and then
        // block every new window from being adopted until a manual rebuild (reset/cycle/tile).
        if !aliveConfirmedIDs.isEmpty && aliveConfirmedIDs.isDisjoint(with: onScreen) { return }

        // Fast path: nothing closed or vanishing, and the on-screen window set is unchanged
        // since the last full reconcile → nothing could have been added or removed. Skip the
        // expensive enumeration (captureWindows) — this keeps a pure focus / app switch cheap
        // instead of paying ~30ms of AX every time.
        // Also gate on the active space: `onScreen` is GLOBAL (all monitors), so switching to a
        // monitor whose on-screen set is unchanged would otherwise fast-path out and never call
        // captureWindows for the new active screen — leaving a window that opened on a NON-active
        // monitor unadopted when you move there (captureWindows only ever sees the active screen).
        if deadLeaves.isEmpty, staleLeaves.isEmpty,
           onScreen == lastReconcileOnScreen, activeSpaceID == lastReconcileSpaceID { return }
        lastReconcileOnScreen = onScreen
        lastReconcileSpaceID = activeSpaceID

        let windows = captureWindows(on: screen, onScreen: onScreen)   // reuse this pass's enumeration

        // Windows Mosaic already manages in ANOTHER present workspace stay THERE — never
        // re-adopt one into the active workspace just because macOS relocated it onto this
        // display (wake/unlock scatter). This makes tiled windows "sticky" to their workspace
        // and kills the drift + the dedup oscillation at the source. Scoped to spaces whose
        // display is still connected, so an undock still lets a window be re-adopted onto a
        // remaining screen. Floating windows aren't tracked here, so they still drag freely.
        var trackedElsewhere = Set<CGWindowID>()
        for (sid, st) in spaces where sid != activeSpaceID {
            guard self.screen(forDisplayID: st.displayID) != nil else { continue }   // home display gone → adoptable
            st.root?.forEachLeaf { leaf in
                if let w = leaf.window, let id = w.lastKnownID ?? w.resolvedID() { trackedElsewhere.insert(id) }
            }
        }
        var additions = windows.filter { window in
            guard let id = AX.windowID(window.element) else { return false }
            if trackedElsewhere.contains(id) { return false }   // belongs to another workspace → leave it there
            return !aliveTreeIDs.contains(id)
        }

        // Same-app window replacement: if a leaf's window vanished and the same app just
        // opened a new one, adopt the newcomer into the vanished leaf's EXACT slot instead
        // of detaching the leaf and inserting the newcomer elsewhere. No ghost tile, no jump
        // — IINA's launcher→video swap keeps the video right where the launcher tiled, and
        // the leaf keeps focus if it had it.
        var adopted = false
        for leaf in staleLeaves {
            guard let deadPid = leaf.window?.pid,
                  let idx = additions.firstIndex(where: { $0.pid == deadPid }) else { continue }
            let replacement = additions.remove(at: idx)
            _ = replacement.resolvedID()   // cache the id so the next pass sees it as alive
            if let old = leaf.window { observer.unwatch([old]) }   // the vanished window's AX regs
            leaf.window = replacement      // render() below repaints its tab/stack label
            adopted = true
        }

        // Verdict for the leaves still unresolved after adoption: a couple of misses in a row
        // confirms a real close (survives transient wake/dock glitches); one miss schedules a
        // prompt re-check so a genuinely-closed window's tab can't linger.
        var gracePending = false
        for leaf in staleLeaves {
            guard let w = leaf.window, w.resolvedID() == nil, !w.app.isHidden else { continue }
            w.missCount += 1
            if w.missCount >= 2 { deadLeaves.append(leaf) } else { gracePending = true }
        }
        if gracePending {
            graceRecheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reconcile() }
            graceRecheck = work
            // Faster re-check → a closed window's tile/tab is confirmed gone and removed in
            // ~0.2s (2 misses) instead of ~0.5s, without the flash of rendering inside the
            // AX destroy callback. Still two misses, so a transient AX glitch never removes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }

        // `adopted`: a same-app replacement swapped a leaf's window in place — no add/remove, but the
        // newcomer still needs render() to place it into the slot and repaint its tab label.
        guard !deadLeaves.isEmpty || !additions.isEmpty || adopted else { return }
        // The window set changed, so the shared snapshot render reads is stale NOW, not in 150ms.
        invalidateWindowSnapshot()

        observer.unwatch(deadLeaves.compactMap { $0.window })   // release regs for really-gone windows
        for leaf in deadLeaves { detach(leaf) }
        for window in additions { insert(window) }
        if !deadLeaves.isEmpty { pruneResizeCache() }   // window closes collapse containers → drop their cache

        guard let newRoot = self.root else { focusIndicator.hide(); return }
        if focused == nil || !treeContainsLeaf(focused!) { focused = newRoot.firstLeaf() }
        wireTabCallbacks(newRoot)
        observer.watchForClose(windows)
        render(activate: false)   // automatic update → never steal focus / switch desktop
    }

    func detach(_ leaf: Container) {
        if let w = leaf.window, let id = AX.windowID(w.element) { w.setAlpha(1, id: id) }
        guard let parent = leaf.parent, let idx = parent.index(of: leaf) else {
            root = nil
            return
        }
        parent.removeChild(at: idx)   // drops the ratio slice AND fixes `selected` for the shift
        leaf.parent = nil

        if parent.children.count == 1 {
            replace(parent, with: parent.children[0])
        } else if parent.children.isEmpty {
            detach(parent)
        }
    }

    func replace(_ node: Container, with replacement: Container) {
        node.hideStrip()
        if let grandparent = node.parent, let idx = grandparent.index(of: node) {
            grandparent.children[idx] = replacement   // same child count → keep its ratios
            replacement.parent = grandparent
        } else {
            root = replacement
            replacement.parent = nil
        }
    }

    func insert(_ window: ManagedWindow) {
        _ = window.resolvedID()   // cache its id now, so a later AX glitch can't make
                                  // reconcile treat it as new and insert a duplicate leaf
        let rule = ruleFor(window)

        // Rule: send this app's new windows to a specific workspace (if it isn't the current
        // one). Places it there without disturbing this workspace.
        if let ws = rule?.workspace, ws >= 1, ws <= 9, UInt64(ws) != activeSpaceID {
            placeOnWorkspace(window, n: ws)
            return
        }

        // Launch restore: an app relaunching after a reboot goes back to the workspace it was
        // saved in, not whatever's focused right now.
        if routeByHint(window) { return }

        let leaf = Container(window: window)
        guard root != nil else { self.root = leaf; focused = leaf; return }

        // i3 preselect: if a split was armed on the focused window, nest this new window
        // with it in a fresh split of the chosen orientation.
        if let ps = preselect, ps.leaf === focused, treeContainsLeaf(ps.leaf) {
            applyPreselect(leaf, vertical: ps.vertical)
            preselect = nil
            focused = leaf
            return
        }

        // Auto-tab with another app's window if it's present (e.g. Discord + Slack).
        if let other = rule?.groupWith, let target = findLeaf(matchingApp: other) {
            groupNewLeaf(leaf, with: target)
            focused = leaf
            return
        }
        switch rule?.place {
        case "column":
            insertAsColumn(leaf)
        case "tab":
            if let f = focused { groupNewLeaf(leaf, with: f) } else { insertAfterFocused(leaf) }
        default:
            if mode == .masterStack { insertMasterStack(leaf) } else { insertAfterFocused(leaf) }
        }
        focused = leaf
    }

    /// Master-stack insert: a new window joins the tabbed stack on the right; if only the master
    /// exists yet, the newcomer becomes the stack beside it.
    func insertMasterStack(_ leaf: Container) {
        guard let r = root else { self.root = leaf; return }
        if !r.isLeaf, r.layout == .splitH, r.children.count >= 2 {
            groupNewLeaf(leaf, with: r.children[r.children.count - 1].firstLeaf())   // tab into the stack
        } else {
            insertAsColumn(leaf)   // only the master so far → new window becomes the stack beside it
        }
    }

    /// i3 preselect commands: arm (or, if re-pressed on the same window+direction, cancel)
    /// a split orientation so the next window nests with the focused one.
    func preselectSplit(vertical: Bool) {
        checkSpaceChange()
        guard let f = focused else { return }
        if let ps = preselect, ps.leaf === f, ps.vertical == vertical {
            preselect = nil                 // toggle off
        } else {
            preselect = (vertical, f)
        }
        updateFocusIndicator()              // refresh the edge cue
    }

    /// Wrap the focused UNIT and `newLeaf` in a new split. If the focused window is inside
    /// a tab/stack group, the whole GROUP is split (the new window takes half the area) —
    /// not nested as a hidden entry inside the group.
    func applyPreselect(_ newLeaf: Container, vertical: Bool) {
        guard let f = focused else { insertAfterFocused(newLeaf); return }
        var unit = f
        while let p = unit.parent, p.layout == .tabbed { unit = p }
        // Capture the slot BEFORE building the split — Container(children:) reparents
        // `unit` to the split, so reading unit.parent afterwards would return the split
        // itself (→ a self-referential cycle → crash).
        let oldParent = unit.parent
        let oldIndex = oldParent?.index(of: unit)
        let split = Container(layout: vertical ? .splitV : .splitH, children: [unit, newLeaf])
        if let p = oldParent, let i = oldIndex {
            p.children[i] = split
            split.parent = p
        } else {
            root = split
        }
    }

    func insertAfterFocused(_ leaf: Container) {
        guard let root else { self.root = leaf; return }
        guard let f = focused, let parent = f.parent, let idx = parent.index(of: f) else {
            let split = Container(layout: .splitH, children: [root, leaf])
            self.root = split
            return
        }
        parent.children.insert(leaf, at: idx + 1)
        leaf.parent = parent
        parent.addRatio(at: idx + 1)   // keep siblings' sizes
    }

    func insertAsColumn(_ leaf: Container) {
        guard let root else { self.root = leaf; return }
        if !root.isLeaf, root.layout != .tabbed {
            root.children.append(leaf)
            leaf.parent = root
            root.addRatio(at: root.children.count - 1)
        } else {
            self.root = Container(layout: .splitH, children: [root, leaf])
        }
    }

    /// Make `new` a tab alongside `target` (joining target's group or wrapping both).
    func groupNewLeaf(_ new: Container, with target: Container) {
        guard let parent = target.parent, let idx = parent.index(of: target) else {
            let group = Container(layout: .tabbed, children: [target, new])
            group.selected = 1
            self.root = group
            return
        }
        if parent.layout == .tabbed {
            parent.children.append(new)
            new.parent = parent
            parent.addRatio(at: parent.children.count - 1)
            parent.selected = parent.children.count - 1
        } else {
            let group = Container(layout: .tabbed, children: [target, new])
            group.selected = 1
            parent.children[idx] = group
            group.parent = parent
        }
    }

    func ruleFor(_ window: ManagedWindow) -> AppRule? {
        let name = window.appName.lowercased()
        let bundle = window.app.bundleIdentifier?.lowercased() ?? ""
        return Config.shared.rules.first { rule in
            let key = rule.app.lowercased()
            return name.contains(key) || bundle.contains(key)
        }
    }

    func findLeaf(matchingApp name: String) -> Container? {
        let needle = name.lowercased()
        var found: Container?
        root?.forEachLeaf { node in
            guard found == nil, let w = node.window else { return }
            if w.appName.lowercased().contains(needle)
                || (w.app.bundleIdentifier?.lowercased().contains(needle) ?? false) {
                found = node
            }
        }
        return found
    }

}

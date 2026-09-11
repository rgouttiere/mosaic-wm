import AppKit

/// Where a tab drag landed within a target tile: center tabs into it, an edge splits beside/under it.
enum DropZone { case center, top, bottom, left, right }

extension WindowManager {
    // MARK: - Editing operations

    /// Swap the focused window with its neighbor in `direction`, keeping the layout
    /// skeleton intact — the two windows trade slots (and thus sizes). Unlike `move`,
    /// nothing is restructured; unlike `rotate`, only these two are affected.
    func swap(_ direction: Direction) {
        checkSpaceChange()
        guard let a = focused, let b = neighborLeaf(from: a, direction), a !== b,
              let pa = a.parent, let ia = pa.index(of: a),
              let pb = b.parent, let ib = pb.index(of: b) else { return }
        if pa === pb {
            pa.children.swapAt(ia, ib)   // ratios stay by slot → sizes follow the position
        } else {
            pa.children[ia] = b; b.parent = pa
            pb.children[ib] = a; a.parent = pb
        }
        focused = a                       // focus follows the window to its new slot
        render()
    }

    func focus(_ direction: Direction) {
        checkSpaceChange()
        guard let leaf = focused, let target = neighborLeaf(from: leaf, direction) else { return }
        focused = target
        preselect = nil          // focus moved → disarm any pending preselect
        render()
    }

    func focusGroup(_ direction: Direction) {
        checkSpaceChange()
        guard let leaf = focused else { return }
        let unit = nearestTabbed(from: leaf) ?? leaf
        guard let target = neighborLeaf(from: unit, direction) else { return }
        focused = target
        render()
    }

    func move(_ direction: Direction) {
        checkSpaceChange()
        guard let f = focused, let parent = f.parent, let idx = parent.index(of: f) else { return }

        // Does this direction run ALONG the parent's axis? Horizontal axis = splitH or
        // horizontal tabs; vertical axis = splitV or a stacked group.
        let horizAxis = parent.layout == .splitH || (parent.layout == .tabbed && !parent.stacked)
        let along = (direction.isHorizontal == horizAxis)
        let n = direction.isForward ? idx + 1 : idx - 1

        if along, parent.children.indices.contains(n) {
            // Reorder within the group: swap positions. A neighbouring sub-group moves as
            // ONE unit (we don't silently pull the window *into* it — that was confusing;
            // use drag & drop or group-with-neighbor to enter a group).
            parent.children.swapAt(idx, n)
            if parent.ratios.indices.contains(idx), parent.ratios.indices.contains(n) {
                parent.ratios.swapAt(idx, n)   // keep each pane's size when swapping
            }
        } else {
            // Along-axis edge OR perpendicular direction → pop the window OUT of the group.
            moveOutward(f, from: parent, idx: idx, direction: direction)
        }
        if let r = root { wireTabCallbacks(r) }
        render()
    }

    /// Extract the focused leaf from its group: into the grandparent if there is one,
    /// otherwise (the group IS the root — e.g. everything tabbed) wrap the root in a new
    /// split so the window lands beside the rest. This is how you get a window back OUT
    /// of a tab/stack group.
    func moveOutward(_ f: Container, from parent: Container, idx: Int, direction: Direction) {
        if let grandparent = parent.parent, let pIdx = grandparent.index(of: parent) {
            parent.removeChild(at: idx)   // remove + ratio + `selected` shift-fix
            f.parent = grandparent
            let insertAt = direction.isForward ? pIdx + 1 : pIdx
            grandparent.children.insert(f, at: insertAt)
            grandparent.addRatio(at: insertAt)
            cleanupAfterRemoval(parent)
        } else if parent === root, parent.children.count > 1 {
            parent.removeChild(at: idx)   // remove + ratio + `selected` shift-fix
            let orient: Container.Layout = direction.isHorizontal ? .splitH : .splitV
            self.root = Container(layout: orient, children: direction.isForward ? [parent, f] : [f, parent])
            if parent.children.count == 1 { replace(parent, with: parent.children[0]) }
        }
    }

    func cleanupAfterRemoval(_ container: Container) {
        if container.children.count == 1 {
            replace(container, with: container.children[0])
        } else if container.children.isEmpty {
            detach(container)
        } else {
            container.normalizeRatios()   // caller already dropped the removed slice
        }
    }

    func resize(_ direction: Direction, by delta: CGFloat = 0.05) {
        checkSpaceChange()
        guard let leaf = focused else { return }
        var node = leaf
        while let parent = node.parent {
            let matches = direction.isHorizontal ? parent.layout == .splitH : parent.layout == .splitV
            if matches, parent.children.count > 1, let idx = parent.index(of: node) {
                parent.normalizeRatios()
                let neighbor = idx + 1 < parent.children.count ? idx + 1 : idx - 1
                let lo = min(idx, neighbor)
                let grow = direction.isForward ? delta : -delta   // +grow = focused tile bigger
                // proposed ratio for the lower index of the pair
                let proposed = (idx == lo) ? parent.ratios[lo] + grow : parent.ratios[lo] - grow
                commitPairResize(parent, lo, proposedRatioForI: proposed,
                                 horizontal: direction.isHorizontal, live: false)
                return
            }
            node = parent
        }
    }

    func toggleSplitOrientation() {
        checkSpaceChange()
        guard let parent = focused?.parent else { return }
        parent.layout = (parent.layout == .splitH) ? .splitV : .splitH
        render()
    }

    /// Monocle: the focused tile fills the screen (staying inside Mosaic, no macOS
    /// fullscreen). Toggle again to restore it to its place. A video playing in it
    /// follows the size automatically, since the window IS the tile.
    func toggleZoom() {
        checkSpaceChange()
        guard let st = active else { return }
        st.isZoomed.toggle()
        render()
    }

    /// Reset the focused container's split ratios to equal.
    func equalizeFocused() {
        checkSpaceChange()
        guard let parent = focused?.parent else { return }
        parent.ratios = Container.equalRatios(parent.children.count)
        render()
    }

    /// Rotate the focused container's children (windows shift one position).
    func rotateFocused() {
        checkSpaceChange()
        guard let f = focused, let parent = f.parent, parent.children.count > 1 else { return }
        parent.children.append(parent.children.removeFirst())
        if !parent.ratios.isEmpty { parent.ratios.append(parent.ratios.removeFirst()) }
        if parent.layout == .tabbed {
            for (i, c) in parent.children.enumerated() where contains(c, f) { parent.selected = i; break }
        }
        render()
    }

    /// Rebuild the current desktop from scratch (discard manual groups & ratios).
    func resetDesktop() {
        checkSpaceChange()
        guard active != nil else { return }
        build()   // fresh tree in the current mode
    }

    func toggleTabbed() {
        checkSpaceChange()
        guard let f = focused, let parent = f.parent else { return }
        if parent.layout == .tabbed && !parent.stacked {
            parent.layout = .splitH          // already horizontal tabs → un-tab
        } else {
            parent.layout = .tabbed
            parent.stacked = false           // horizontal tabs (clears stacking)
            parent.selected = parent.index(of: f) ?? 0
        }
        render()
    }

    /// i3 "stacking": vertical title list, one window shown. Toggles on the focused
    /// window's parent; re-invoking on a stack reverts it to a horizontal split.
    func toggleStacked() {
        checkSpaceChange()
        guard let f = focused, let parent = f.parent else { return }
        if parent.layout == .tabbed && parent.stacked {
            parent.layout = .splitH          // already stacked → un-stack
            parent.stacked = false
        } else {
            parent.layout = .tabbed
            parent.stacked = true
            parent.selected = parent.index(of: f) ?? 0
        }
        render()
    }

    func groupWithNeighbor() { groupWithNeighbor(stacked: false) }
    /// Like `groupWithNeighbor` but the resulting group is a vertical stack, not tabs.
    func groupWithNeighborStacked() { groupWithNeighbor(stacked: true) }

    func groupWithNeighbor(stacked: Bool) {
        checkSpaceChange()
        guard let root, !root.isLeaf, root.layout != .tabbed, let f = focused else { return }
        guard let column = rootColumn(of: f), let idx = root.index(of: column) else { return }

        let otherIdx = idx > 0 ? idx - 1 : idx + 1
        guard root.children.indices.contains(otherIdx) else { return }

        let lo = min(idx, otherIdx)
        let a = root.children[lo]
        let b = root.children[lo + 1]

        // Merge a SAME-kind group's children (combining loose windows / growing a group
        // stays flat), but PRESERVE a different-kind group or a split as one nested entry
        // (so stacking two tab groups gives a stack of the two groups, shown inline).
        func entries(of node: Container) -> [Container] {
            if !node.isLeaf, node.layout == .tabbed, node.stacked == stacked {
                let kids = node.children
                node.hideStrip()
                kids.forEach { $0.parent = nil }
                return kids
            }
            return [node]
        }
        let combined = entries(of: a) + entries(of: b)

        let group = Container(layout: .tabbed, children: combined)
        group.stacked = stacked
        group.selected = combined.firstIndex { contains($0, f) } ?? 0

        root.children.removeSubrange(lo...(lo + 1))
        root.children.insert(group, at: lo)
        group.parent = root
        root.ratios = Container.equalRatios(root.children.count)

        if root.children.count == 1 {
            let only = root.children[0]
            only.parent = nil
            self.root = only
        }

        focused = f
        if let r = self.root { wireTabCallbacks(r) }
        render()
    }

    func rootColumn(of leaf: Container) -> Container? {
        guard let root, leaf !== root else { return nil }
        var node = leaf
        while let parent = node.parent {
            if parent === root { return node }
            node = parent
        }
        return nil
    }

    func collectLeaves(_ node: Container) -> [Container] {
        var result: [Container] = []
        node.forEachLeaf { result.append($0) }
        return result
    }

    func nextTab() { cycleTab(+1) }
    func prevTab() { cycleTab(-1) }

    /// Move a dragged tab into whatever group/window is under the drop point — works
    /// across desktops AND screens (source and target may be in different trees).
    func dropTab(from source: Container, index: Int, at point: NSPoint) {
        dropHighlight.hide()   // the drag is ending — clear the highlight now
        guard source.children.indices.contains(index) else { return }
        let dragged = source.children[index]

        // Resolve the drop target across all managed screens/desktops.
        guard let dropScreen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let dropSpaceID = currentWorkspace(for: dropScreen),
              let targetState = spaces[dropSpaceID],
              let targetRoot = targetState.root,
              let targetLeaf = visibleLeaf(at: point, in: targetRoot),
              targetLeaf !== dragged, !contains(dragged, targetLeaf),
              let sourceState = stateContaining(dragged) else { return }

        // Where in the target tile did we land? Center = tab into it; an edge = split beside/under.
        let zone = (targetLeaf.window?.frame).map { dropZone(at: point, in: Geometry.flip($0)) } ?? .center

        // Detach from the source tree and collapse what it leaves behind.
        if let parent = dragged.parent, let i = parent.index(of: dragged) {
            parent.removeChild(at: i)   // adjusts `selected` for the lower-index shift too
            collapse(parent, in: sourceState)
        }

        if zone == .center {
            // Insert into the target tree as a tab.
            if let group = nearestTabbed(from: targetLeaf) {
                group.children.append(dragged)
                dragged.parent = group
                group.addRatio(at: group.children.count - 1)
                group.selected = group.children.count - 1
            } else if let tp = targetLeaf.parent, let ti = tp.index(of: targetLeaf) {
                let group = Container(layout: .tabbed, children: [targetLeaf, dragged])
                group.selected = 1
                tp.children[ti] = group
                group.parent = tp
            } else {
                let group = Container(layout: .tabbed, children: [targetLeaf, dragged])
                group.selected = 1
                targetState.root = group
            }
        } else {
            // Split beside/under the WHOLE tab group the target belongs to (like preselect).
            var unit = targetLeaf
            while let p = unit.parent, p.layout == .tabbed { unit = p }
            // Capture the slot BEFORE building the split — Container(children:) reparents `unit`,
            // so reading unit.parent afterwards would return the split itself (→ a cycle → crash).
            let oldParent = unit.parent
            let oldIndex = oldParent?.index(of: unit)
            let vertical = (zone == .top || zone == .bottom)
            let draggedFirst = (zone == .top || zone == .left)
            let split = Container(layout: vertical ? .splitV : .splitH,
                                  children: draggedFirst ? [dragged, unit] : [unit, dragged])
            if let p = oldParent, let i = oldIndex {
                p.children[i] = split
                split.parent = p
            } else {
                targetState.root = split
            }
        }

        // No CGS move needed across workspaces: there is a single macOS Space, so `arrange`
        // below physically relocates the window onto the target screen (or off-screen if the
        // target workspace is parked).

        // Re-lay both trees on their screens and fix focus.
        targetState.focused = dragged.firstLeaf()
        if let sr = sourceState.root {
            if let sf = sourceState.focused, !contains(sr, sf) { sourceState.focused = sr.firstLeaf() }
        } else {
            sourceState.focused = nil
        }
        arrangeState(sourceState)
        arrangeState(targetState)
        if let sr = sourceState.root { wireTabCallbacks(sr) }
        if let tr = targetState.root { wireTabCallbacks(tr) }
        render()   // refresh overlays of the active desktop
        saveNow()
    }

    /// Highlight the region the drop will land in — the full tile (center = tab) or the half it
    /// will occupy (an edge = split there).
    func updateDropHighlight(at point: NSPoint) {
        guard Config.shared.dropHighlightEnabled,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let spaceID = currentWorkspace(for: screen),
              let root = spaces[spaceID]?.root,
              let leaf = visibleLeaf(at: point, in: root),
              let frame = leaf.window?.frame else {
            dropHighlight.hide()
            return
        }
        let f = Geometry.flip(frame)
        dropHighlight.show(around: zoneRect(dropZone(at: point, in: f), in: f))
    }

    /// Which region of a target tile the cursor is over (Cocoa coords). The outer ~28% band on each
    /// side is an edge zone (→ split); the middle is center (→ tab).
    func dropZone(at point: NSPoint, in f: NSRect) -> DropZone {
        guard f.width > 0, f.height > 0 else { return .center }
        let dx = (point.x - f.minX) / f.width
        let dy = (point.y - f.minY) / f.height
        let edge: CGFloat = 0.28
        if dx > edge, dx < 1 - edge, dy > edge, dy < 1 - edge { return .center }
        let m = min(dx, 1 - dx, dy, 1 - dy)   // nearest border wins
        if m == 1 - dy { return .top }
        if m == dy { return .bottom }
        if m == dx { return .left }
        return .right
    }

    /// The slice of `f` the dragged window will occupy — the whole tile for center, else a half.
    func zoneRect(_ zone: DropZone, in f: NSRect) -> NSRect {
        switch zone {
        case .center: return f
        case .top:    return NSRect(x: f.minX, y: f.midY, width: f.width, height: f.height / 2)
        case .bottom: return NSRect(x: f.minX, y: f.minY, width: f.width, height: f.height / 2)
        case .left:   return NSRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height)
        case .right:  return NSRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height)
        }
    }

    func stateContaining(_ node: Container) -> SpaceState? {
        for state in spaces.values {
            var found = false
            func walk(_ n: Container) {
                if n === node { found = true }
                if !found { n.children.forEach(walk) }
            }
            if let r = state.root { walk(r) }
            if found { return state }
        }
        return nil
    }

    /// Collapse a container left with one/zero children, within a specific desktop's tree.
    func collapse(_ container: Container, in state: SpaceState) {
        container.hideStrip()
        if container.children.count == 1 {
            let only = container.children[0]
            if let gp = container.parent, let idx = gp.index(of: container) {
                gp.children[idx] = only   // same child count → keep gp ratios
                only.parent = gp
            } else {
                state.root = only
                only.parent = nil
            }
        } else if container.children.isEmpty {
            if let gp = container.parent, let idx = gp.index(of: container) {
                gp.removeChild(at: idx)   // adjusts `selected` for the lower-index shift too
                collapse(gp, in: state)
            } else {
                state.root = nil
            }
        }
    }

    /// Arrange a (possibly non-active) desktop's tree on its own screen.
    func arrangeState(_ state: SpaceState) {
        guard let r = state.root, let screen = screen(forDisplayID: state.displayID) else { return }
        r.arrange(in: layoutRect(screen))
        r.raiseVisibleWindows()
    }

    /// Re-arrange and re-show the layout (windows + tab bars) of the Space currently
    /// visible on EACH screen — not just the one under the mouse. After unlock/wake,
    /// macOS hides our borderless tab-bar overlays; a normal `checkSpaceChange` only
    /// refreshes the mouse's screen, leaving the others' strips gone. This re-shows all.
    func refreshVisibleSpaces() {
        for screen in NSScreen.screens {
            guard let id = currentWorkspace(for: screen),
                  let state = spaces[id], let r = state.root else { continue }
            r.arrange(in: layoutRect(screen))
            r.raiseVisibleWindows()
            r.raiseVisibleStrips()
        }
        sweepOrphanStrips()
    }

    /// Repaint the tab/stack strip labels of the Space visible on EVERY screen, not just
    /// the active one — so a title change (a browser navigating, a terminal's cwd) on a
    /// secondary monitor updates its label live, without having to focus that monitor.
    /// Cheap: it only re-reads titles of leaves already in the tree, no AX enumeration.
    func refreshVisibleTitles() {
        for screen in NSScreen.screens {
            guard let id = currentWorkspace(for: screen), let st = spaces[id] else { continue }
            st.root?.refreshBarTitles()
        }
    }

    /// Diff every managed window's title against its snapshot. A change on a window whose workspace
    /// is PARKED flags that workspace for attention (a chat message arrived, a task finished). A
    /// change on a SHOWN workspace only refreshes the baseline — the user is already looking at it,
    /// and a fresh baseline means the FIRST change after it parks is caught. Rising-edge only: the
    /// hook fires once per attention episode, not per title tick. Runs on the (debounced) title-
    /// change event, so it costs a cheap AX title read per window at most a few times a second.
    func scanAttention() {
        let __perf = DispatchTime.now(); defer { Perf.record("scanAttention", since: __perf) }
        var changed = false
        var live = Set<ObjectIdentifier>()
        for (id, ws) in spaces {
            guard let n = workspaceNumber(for: id), let r = ws.root else { continue }
            let parked = screen(forWorkspace: id) == nil
            if !parked, attentionWorkspaces.remove(n) != nil { changed = true }   // shown → seen
            r.forEachLeaf { leaf in
                guard let w = leaf.window else { return }
                let key = ObjectIdentifier(w)
                live.insert(key)
                let title = w.title                                  // one AX read, not two
                let previous = titleSnapshot.updateValue(title, forKey: key)
                if parked, let previous, previous != title,
                   attentionWorkspaces.insert(n).inserted { changed = true }
            }
        }
        // Drop snapshots for windows that are gone, so the map stays bounded to live windows (and a
        // reused object address can't false-match a stale title).
        if titleSnapshot.count > live.count { titleSnapshot = titleSnapshot.filter { live.contains($0.key) } }
        if changed { publishAttention() }
    }

    /// Drop a workspace's attention flag because the user is now looking at it. Cheap no-op if it
    /// wasn't flagged. Called from the switch path so the badge clears the instant you visit.
    func clearAttention(_ n: Int) {
        if attentionWorkspaces.remove(n) != nil { publishAttention() }
    }

    /// Re-publish status.json and poke the external bar after the attention set changed.
    func publishAttention() {
        let focused = screenUnderMouse().flatMap { currentWorkspace(for: $0) }.flatMap { workspaceNumber(for: $0) }
        writeStatusFile(focused: focused)
        runWorkspaceHook(focused)
    }

    /// Purge dead leaves (and adopt same-app replacements) on a Space that is VISIBLE on a
    /// secondary monitor but is NOT the active one. `reconcile()` only runs on the active
    /// Space, so a window that closed on another monitor while focus was elsewhere — e.g.
    /// IINA's video window ending on a background screen — would leave a ghost tile there
    /// until that monitor was focused. Runs on the poll timer.
    ///
    /// Cost is bounded: a cheap leaf walk (only `resolvedID()`, no AX enumeration) runs
    /// first, and the expensive `captureWindows` is paid only for a Space that actually has
    /// a vanished leaf. New-window *insertion* is deliberately left to the active reconcile
    /// (opening a window activates its app → that Space becomes active), so this never has
    /// to reason about focus/preselect on a Space the user isn't on.
    func purgeVisibleGhosts() {
        guard !suspended, !isReconciling else { return }
        // Gate the expensive enumeration on cheap SPI: only a secondary monitor showing a
        // managed Space that is NOT the active one can hold a ghost here. On a single-monitor
        // setup (the common case) the sole screen's Space IS active, so there are no candidates
        // and we skip the CGWindowList enumeration entirely — otherwise it fires ~2.5×/s forever
        // and defeats idle/App-Nap quiescence.
        let candidates: [(scr: NSScreen, st: SpaceState, root: Container)] =
            NSScreen.screens.compactMap { scr in
                guard let id = currentWorkspace(for: scr), id != activeSpaceID,
                      let st = spaces[id], let r = st.root else { return nil }
                return (scr, st, r)
            }
        guard !candidates.isEmpty else { return }

        let onScreen = AX.onScreenWindowIDs()
        var changed = false
        var adopted: [ManagedWindow] = []
        for (scr, st, r) in candidates {
            var aliveIDs = Set<CGWindowID>()
            var stale: [Container] = []
            r.forEachLeaf { leaf in
                guard let w = leaf.window else { stale.append(leaf); return }
                if let wid = w.resolvedID() { if !w.isFullscreen { aliveIDs.insert(wid) }; return }
                if w.app.isHidden { w.missCount = 0; if let c = w.lastKnownID { aliveIDs.insert(c) }; return }
                if let c = w.lastKnownID, onScreen.contains(c) { w.missCount = 0; aliveIDs.insert(c); return }
                stale.append(leaf)
                if let c = w.lastKnownID { aliveIDs.insert(c) }   // keep during grace
            }
            guard !stale.isEmpty else { continue }

            // A window vanished here → look for same-app newcomers to adopt into the exact
            // slot (IINA's launcher→video swap on a background monitor), else age the leaf
            // out through the same two-miss grace the active reconcile uses.
            var additions = captureWindows(on: scr, onScreen: onScreen).filter {
                guard let wid = AX.windowID($0.element) else { return false }
                return !aliveIDs.contains(wid)
            }
            for leaf in stale {
                guard let w = leaf.window else { removeLeaf(leaf, from: st); changed = true; continue }
                if let idx = additions.firstIndex(where: { $0.pid == w.pid }) {
                    let rep = additions.remove(at: idx)
                    _ = rep.resolvedID()
                    observer.unwatch([w])   // the vanished window's AX regs (adopted away)
                    leaf.window = rep
                    adopted.append(rep)
                    changed = true
                } else {
                    w.missCount += 1
                    if w.missCount >= 2 { observer.unwatch([w]); removeLeaf(leaf, from: st); changed = true }
                }
            }
        }
        if !adopted.isEmpty { observer.watchForClose(adopted) }
        if changed { refreshVisibleSpaces() }
    }

    func contains(_ node: Container, _ leaf: Container) -> Bool {
        var found = false
        node.forEachLeaf { if $0 === leaf { found = true } }
        return found
    }

    func cycleTab(_ step: Int) {
        checkSpaceChange()
        guard let leaf = focused, let tabbed = nearestTabbed(from: leaf), !tabbed.children.isEmpty else { return }
        let count = tabbed.children.count
        tabbed.selected = (tabbed.selected + step + count) % count
        focused = tabbed.children[tabbed.selected].firstLeaf()
        render()
    }

    /// Send the focused window to the next/previous display and tile it there.
    func moveToScreen(next: Bool) {
        checkSpaceChange()
        guard let st = active, let leaf = focused else { return }
        let screens = NSScreen.screens
        guard screens.count > 1,
              let idx = screens.firstIndex(where: { displayID(of: $0) == st.displayID }) else { return }
        let target = screens[(idx + (next ? 1 : screens.count - 1)) % screens.count]
        let targetDID = displayID(of: target)
        guard targetDID != st.displayID else { return }
        // Bootstrap the target monitor's workspace if it's never been shown there (a monitor
        // the mouse hasn't visited yet has no shown workspace — nil in the emulated model).
        let targetSpace = currentWorkspace(for: target) ?? UInt64(defaultWorkspaceNumber(for: target))
        shownOnDisplay[targetDID] = targetSpace

        detach(leaf)
        leaf.parent = nil

        let tst = spaces[targetSpace] ?? {
            let s = SpaceState(displayID: targetDID)
            s.mode = defaultMode
            spaces[targetSpace] = s
            return s
        }()
        appendLeaf(leaf, to: tst)
        tst.root?.arrange(in: layoutRect(target))          // physically moves the window
        if let r = tst.root { wireTabCallbacks(r) }
        tst.root?.raiseVisibleWindows()   // skips fullscreen (Space yank) + hidden tabs (wrong tab surfacing)

        if focused == nil || !treeContainsLeaf(focused!) { focused = root?.firstLeaf() }
        render()
        saveNow()
    }

    /// Send the focused window to the next/previous workspace number (no wrap, clamped to 1-9).
    func moveToDesktop(next: Bool) {
        checkSpaceChange()
        guard let current = activeSpaceID else { return }
        let n = Int(current) + (next ? 1 : -1)
        guard n >= 1, n <= 9 else { return }
        moveToWorkspace(n)
    }

    /// Send the focused window to workspace `index + 1` (0-based index → 1-based number).
    func moveToDesktopIndex(_ index: Int) {
        let n = index + 1
        guard n >= 1, n <= 9 else { return }
        moveToWorkspace(n)
    }

}

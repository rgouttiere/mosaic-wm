import AppKit

extension WindowManager {
    // MARK: - Tree queries

    func neighborLeaf(from leaf: Container, _ direction: Direction) -> Container? {
        var node = leaf
        while let parent = node.parent {
            // Tabbed groups are traversed left/right; stacked (vertical list) up/down.
            let horiz = parent.layout == .splitH || (parent.layout == .tabbed && !parent.stacked)
            let vert  = parent.layout == .splitV || (parent.layout == .tabbed && parent.stacked)
            let matches = direction.isHorizontal ? horiz : vert
            if matches, let idx = parent.index(of: node) {
                let n = direction.isForward ? idx + 1 : idx - 1
                if parent.children.indices.contains(n) {
                    return descend(parent.children[n], direction)
                }
            }
            node = parent
        }
        return nil
    }

    func descend(_ node: Container, _ direction: Direction) -> Container {
        guard !node.isLeaf, !node.children.isEmpty else { return node }
        switch node.layout {
        case .tabbed:
            return descend(node.children[min(max(node.selected, 0), node.children.count - 1)], direction)
        default:
            return descend(direction.isForward ? node.children.first! : node.children.last!, direction)
        }
    }

    func nearestTabbed(from leaf: Container) -> Container? {
        var node: Container? = leaf.parent
        while let n = node {
            if n.layout == .tabbed { return n }
            node = n.parent
        }
        return nil
    }

    func treeContainsLeaf(_ leaf: Container) -> Bool {
        var found = false
        root?.forEachLeaf { if $0 === leaf { found = true } }
        return found
    }

    func selectTabsOnPath(to leaf: Container) {
        var child = leaf
        while let parent = child.parent {
            if parent.layout == .tabbed, let idx = parent.index(of: child) {
                parent.selected = idx
            }
            child = parent
        }
    }

    func wireTabCallbacks(_ node: Container) {
        node.onTabSelect = { [weak self] container, index in
            guard let self, container.children.indices.contains(index) else { return }
            container.selected = index
            self.focused = container.children[index].firstLeaf()
            self.render()
        }
        node.onStackSelect = { [weak self] container, row, seg in
            guard let self, container.children.indices.contains(row) else { return }
            container.selected = row
            let entry = container.children[row]
            // Inline tab-group row: `seg` picks the sub-tab inside that group.
            if !entry.isLeaf, entry.layout == .tabbed, entry.children.indices.contains(seg) {
                entry.selected = seg
                self.focused = entry.children[seg].firstLeaf()
            } else {
                self.focused = entry.firstLeaf()
            }
            self.render()
        }
        node.onReorder = { [weak self] container, from, to in
            guard let self,
                  container.children.indices.contains(from),
                  container.children.indices.contains(to) else { return }
            let moved = container.children.remove(at: from)
            container.children.insert(moved, at: to)
            container.selected = to
            self.focused = moved.firstLeaf()
            self.render()
        }
        node.onDropOutside = { [weak self] container, index, point in
            self?.dropTab(from: container, index: index, at: point)
        }
        node.onTabDragState = { [weak self] dragging in
            self?.tabDragging = dragging
            if !dragging { self?.dropHighlight.hide() }
        }
        node.onTabDragMove = { [weak self] point in self?.updateDropHighlight(at: point) }
        node.children.forEach { wireTabCallbacks($0) }
    }

    // MARK: - Render

    /// `activate` gives the focused window app keyboard focus. ONLY pass true for
    /// user-initiated actions: activating an app brings its Space forward, so doing
    /// it during an automatic render (e.g. after a desktop switch) would yank macOS
    /// back to the layout's desktop. Even then we only activate an on-screen window.
    func render(activate: Bool = true) {
        guard let root, let screen = activeScreen else { return }
        let __perf = DispatchTime.now(); defer { Perf.record("render", since: __perf) }

        // Monocle: the focused tile fills the screen; every overlay is hidden so nothing
        // floats over it. The tree keeps its frames for when we un-zoom.
        let area = layoutRect(screen)
        if active?.isZoomed == true, let w = focused?.window {
            if activate { w.activateApp() }
            if !w.isFullscreen { AX.raise(w.element) }   // raising a fullscreen tile would yank its Space
            if let id = AX.windowID(w.element) { w.setAlpha(1, id: id) }   // zoomed = full opacity
            root.forEachTabbed { $0.hideStrip() }   // only THIS desktop's strips, not other screens'
            hideAllHandles()
            windowBorders.hideAll()  // siblings hidden — no inactive borders to draw

            // Fill the screen; a window that aspect-fits (IINA) shrinks and is centred with the
            // sides letterboxed. AX setFrame is synchronous, so the constrained size reads back in
            // the SAME render — no wait, no reposition delay. Skip re-writing a zoom that's already
            // filled or already centred, so a settled zoom re-writes nothing (no per-render flicker).
            let cur = w.frame.map { Geometry.flip($0) } ?? area
            let fills = cur.width >= area.width - 8 && cur.height >= area.height - 8
            let centeredAlready = !fills && abs(cur.midX - area.midX) < 3 && abs(cur.midY - area.midY) < 3
            var frameForBorder = area
            var box: NSRect?   // the centred window rect to letterbox around; nil = fills, no bars
            if fills {
                w.setCocoaFrame(area)                       // keep it full (cached)
            } else if centeredAlready {
                frameForBorder = cur; box = cur             // already centred → just maintain
            } else {
                w.setCocoaFrame(area)                       // blow up; read the constrained result now
                let win = w.frame.map { Geometry.flip($0) } ?? area
                if win.width < area.width - 8 || win.height < area.height - 8 {
                    let centered = NSRect(x: area.midX - win.width / 2, y: area.midY - win.height / 2,
                                          width: win.width, height: win.height)
                    w.setCocoaFrame(centered)
                    frameForBorder = centered; box = centered
                }
            }
            if let box {
                letterbox.begin()
                let t: CGFloat = 8
                func bar(_ r: NSRect) { letterbox.fill(r.intersection(area)) }
                if box.minY > area.minY + t { bar(NSRect(x: area.minX, y: area.minY, width: area.width, height: box.minY - area.minY)) }
                if box.maxY < area.maxY - t { bar(NSRect(x: area.minX, y: box.maxY, width: area.width, height: area.maxY - box.maxY)) }
                if box.minX > area.minX + t { bar(NSRect(x: area.minX, y: box.minY, width: box.minX - area.minX, height: box.height)) }
                if box.maxX < area.maxX - t { bar(NSRect(x: box.maxX, y: box.minY, width: area.maxX - box.maxX, height: box.height)) }
                letterbox.end()
            } else {
                letterbox.hideAll()
            }

            // Keep the focus contour framing the zoomed window, and a persistent ZOOM badge, so it
            // stays obvious you're in monocle (siblings hidden) and haven't just lost your layout.
            if Config.shared.borderEnabled { focusIndicator.show(around: frameForBorder) } else { focusIndicator.hide() }
            zoomBadge.show(on: screen)
            scheduleSave()
            return
        }
        zoomBadge.hide()   // not (or no longer) zoomed → drop the badge

        if let f = focused { selectTabsOnPath(to: f) }
        root.arrange(in: area)
        root.raiseVisibleWindows()

        // One enumeration reused by the activate check and updateFocusIndicator below, instead
        // of two identical CGWindowList calls per render.
        let onScreen = AX.onScreenWindowIDs()
        if activate, let w = focused?.window,
           let id = AX.windowID(w.element), onScreen.contains(id) {
            // makeMain BEFORE activating: else activating the app first surfaces its old
            // main window (another tab of the same app) for a frame before we raise ours.
            AX.makeMain(w.element)
            w.activateApp()
            AX.raise(w.element)
        }
        root.raiseVisibleStrips()
        parkHiddenCrossAppTabs(on: screen)

        sweepOrphanStrips()   // hide strips not on any desktop's visible path
        updateFocusIndicator(onScreen: onScreen)
        layoutResizeHandles()
        applyOpacity()
        updateWindowBorders()   // dim accent frame on non-focused tiles (opt-in)
        updateLetterboxFill()   // black-fill letterbox gaps so parked slivers can't peek through

        // While the scratchpad is up, keep the tiles' overlays hidden so nothing floats
        // over it (a reconcile-triggered render would otherwise re-show them).
        if scratchpadVisible {
            root.forEachTabbed { $0.hideStrip() }
            hideAllHandles()
        }
        scheduleSave()
    }

    /// Cross-app tab groups can't rely on z-order: macOS stacks by app LAYER, so a hidden tab from
    /// another app can cover the selected one whenever that app's layer floats up — and activating
    /// the selected app above it is unreliable (Tahoe cooperative activation). Decouple visibility
    /// from z-order: translate each hidden tab whose app differs from the selected one's OFF-SCREEN
    /// (the same shift a workspace park uses, driven off the leaf's arranged rect so it keeps its
    /// size — no relayout), so nothing from another app can ever cover the selected tab. arrange()
    /// brings a tab straight back to its slot the instant it's selected.
    func parkHiddenCrossAppTabs(on screen: NSScreen) {
        guard let root else { return }
        let lr = layoutRect(screen), pr = parkRect(for: screen)
        let dx = pr.minX - lr.minX, dy = pr.minY - lr.minY
        root.forEachTabbed { group in
            let kids = group.children
            guard kids.count > 1 else { return }
            let sel = min(max(group.selected, 0), kids.count - 1)
            guard let selPid = kids[sel].firstLeaf().window?.app.processIdentifier else { return }
            // Only mixed-app groups need this; a same-app group's z-order (AX.raise) already works.
            guard Set(kids.compactMap { $0.firstLeaf().window?.app.processIdentifier }).count > 1 else { return }
            for (i, child) in kids.enumerated() where i != sel {
                child.forEachLeaf { leaf in
                    // Drive off lastFrame (the Cocoa rect arrange just wrote), NOT the live AX frame,
                    // so a re-park each render can't compound the window further off-screen.
                    guard let w = leaf.window, !w.isFullscreen,
                          w.app.processIdentifier != selPid, leaf.lastFrame.width > 0 else { return }
                    w.setCocoaFrame(leaf.lastFrame.offsetBy(dx: dx, dy: dy))
                }
            }
        }
    }

    /// Paint black bars over the gap of every SHOWN tile whose window doesn't fill it (e.g. IINA
    /// keeping video aspect), across all monitors — so a parked window's ~40px residual strip (macOS
    /// won't move a window fully off-screen) can't poke through, and the tile reads as a clean
    /// letterbox. Runs on every render off the leaf's arranged rect vs the window's live AX frame.
    func updateLetterboxFill() {
        guard !scratchpadVisible else { letterbox.hideAll(); return }
        letterbox.begin()
        let t: CGFloat = 8   // ignore sub-8px mismatches — too small to be worth a bar
        for (did, wsNum) in shownOnDisplay {
            guard screen(forDisplayID: did) != nil, let root = spaces[wsNum]?.root else { continue }
            root.forEachVisibleLeaf { leaf in
                guard let w = leaf.window, !w.isFullscreen, let wf = w.frame else { return }
                let tile = leaf.lastFrame
                guard tile.width > 0, tile.height > 0 else { return }
                let win = Geometry.flip(wf)
                func bar(_ r: NSRect) { letterbox.fill(r.intersection(tile)) }
                if win.minY > tile.minY + t { bar(NSRect(x: tile.minX, y: tile.minY, width: tile.width, height: win.minY - tile.minY)) }
                if win.maxY < tile.maxY - t { bar(NSRect(x: tile.minX, y: win.maxY, width: tile.width, height: tile.maxY - win.maxY)) }
                if win.minX > tile.minX + t { bar(NSRect(x: tile.minX, y: win.minY, width: win.minX - tile.minX, height: win.height)) }
                if win.maxX < tile.maxX - t { bar(NSRect(x: win.maxX, y: win.minY, width: tile.maxX - win.maxX, height: win.height)) }
            }
        }
        letterbox.end()
    }

    /// Draw a dim accent border on every shown, non-focused tiled window (opt-in `borderInactive`),
    /// so the whole tiling reads as one outlined layout — the focused window keeps its brighter
    /// FocusIndicator + halo on top.
    func updateWindowBorders() {
        guard Config.shared.borderInactive, !scratchpadVisible else { windowBorders.hideAll(); return }
        windowBorders.begin()
        let focusedW = focused?.window
        for (did, wsNum) in shownOnDisplay {
            guard screen(forDisplayID: did) != nil, let root = spaces[wsNum]?.root else { continue }
            root.forEachVisibleLeaf { leaf in
                guard let w = leaf.window, !w.isFullscreen, w !== focusedW, let wf = w.frame else { return }
                windowBorders.border(around: Geometry.flip(wf))
            }
        }
        windowBorders.end()
    }

    /// Dim unfocused windows per config (focused → activeOpacity, others → inactiveOpacity).
    func applyOpacity() {
        guard let root else { return }
        let active = Float(Config.shared.activeOpacity)
        let inactive = Float(Config.shared.inactiveOpacity)
        guard active < 1 || inactive < 1 else { return }   // feature disabled
        // Reuse the cached window id (kept fresh by reconcile's resolvedID) instead of paying a
        // cross-process AX id lookup per leaf on every render; setAlpha itself is already cached.
        let activeID = focused?.window.flatMap { $0.lastKnownID ?? AX.windowID($0.element) }
        root.forEachLeaf { leaf in
            guard let w = leaf.window, !w.isFullscreen, let id = w.lastKnownID ?? AX.windowID(w.element) else { return }
            w.setAlpha(id == activeID ? active : inactive, id: id)
        }
    }

    /// Move/hide the focus border only — no window re-arranging. Used on screen
    /// switches so the tab layout isn't reloaded just to refresh the border.
    /// `onScreen` lets a caller (render) that already enumerated this pass avoid a second
    /// identical CGWindowList enumeration; defaults to a fresh one for standalone callers.
    func updateFocusIndicator(onScreen: Set<CGWindowID>? = nil) {
        if scratchpadVisible { focusIndicator.hide(); return }   // never over the scratchpad
        let ps: Bool? = (preselect?.leaf === focused) ? preselect?.vertical : nil
        // Show if the border is enabled OR a preselect is armed (so the cue is visible
        // even when borders are off).
        guard Config.shared.borderEnabled || ps != nil else { focusIndicator.hide(); return }
        // Only draw around a window that's actually on the current Space & on screen — a
        // stale/off-space focused window would otherwise get a border in empty space.
        if let w = focused?.window, let frame = w.frame, !w.isFullscreen,
           let id = AX.windowID(w.element), (onScreen ?? AX.onScreenWindowIDs()).contains(id) {
            focusIndicator.show(around: Geometry.flip(frame), preselect: ps)
        } else {
            focusIndicator.hide()
        }
    }

}

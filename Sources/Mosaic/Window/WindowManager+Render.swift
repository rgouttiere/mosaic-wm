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
            w.setCocoaFrame(area)
            if activate { w.activateApp() }
            if !w.isFullscreen { AX.raise(w.element) }   // raising a fullscreen tile would yank its Space
            if let id = AX.windowID(w.element) { w.setAlpha(1, id: id) }   // zoomed = full opacity
            root.forEachTabbed { $0.hideStrip() }   // only THIS desktop's strips, not other screens'
            hideAllHandles()
            // Keep the focus contour framing the zoomed window, and a persistent ZOOM badge, so it
            // stays obvious you're in monocle (siblings hidden) and haven't just lost your layout.
            if Config.shared.borderEnabled { focusIndicator.show(around: area) } else { focusIndicator.hide() }
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

        sweepOrphanStrips()   // hide strips not on any desktop's visible path
        updateFocusIndicator(onScreen: onScreen)
        layoutResizeHandles()
        applyOpacity()

        // While the scratchpad is up, keep the tiles' overlays hidden so nothing floats
        // over it (a reconcile-triggered render would otherwise re-show them).
        if scratchpadVisible {
            root.forEachTabbed { $0.hideStrip() }
            hideAllHandles()
        }
        scheduleSave()
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

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
    /// Screenshot/annotation tools throw up a full-screen selection overlay at the same window
    /// level as our decorations, so ours (opaque letterbox bars, borders, focus contour) end up on
    /// top and swallow their UI. Detect them by frontmost app and stand down while they're up.
    static let screenshotTools: Set<String> = [
        "shottr", "cc.ffitch.shottr", "cleanshot", "cleanshot x", "pl.maketheweb.cleanshotx",
        "monosnap", "com.monosnap.monosnap", "skitch", "com.evernote.skitch", "snagit", "xnip",
    ]
    func screenshotToolFrontmost() -> Bool {
        guard let f = NSWorkspace.shared.frontmostApplication else { return false }
        if let n = f.localizedName?.lowercased(), Self.screenshotTools.contains(n) { return true }
        if let b = f.bundleIdentifier?.lowercased(), Self.screenshotTools.contains(b) { return true }
        return false
    }

    /// Displays wholly covered by a window Mosaic does not manage — a game in borderless full
    /// screen, typically. Such a window is ordinary and screen-sized, with a subrole we never
    /// tile (WoW reports AXUnknown), so nothing in the layout knows the monitor is taken: our
    /// overlays all sit at `.floating` or above and draw straight over it, and the focused-window
    /// raise lifts a managed app's layer in front of it. Worse, focus never moves to an unmanaged
    /// window, so the halo stays pinned to the last managed tile for as long as you play.
    ///
    /// Geometric on purpose: no per-game list to maintain, and it catches launchers and engines
    /// alike. Set `yieldToFullscreenWindows: false` to turn it off. Covering alone doesn't count:
    /// the game stays on screen behind whatever you alt-tab to — see `Geometry.isTakenOver`.
    ///
    /// Cached briefly because the paths that re-show the halo (focus sync, mouse, reconcile) each
    /// consult it without a full render; `maxAge: 0` forces the fresh read a render wants.
    /// The on-screen, layer-0 windows, at most `maxAge` old. Shared so a render enumerates once.
    func onScreenSnapshot(maxAge: TimeInterval = 0.4) -> [(id: CGWindowID, pid: pid_t, bounds: CGRect)] {
        if Date().timeIntervalSince(windowSnapshotTime) < maxAge { return windowSnapshot }
        windowSnapshot = AX.onScreenWindows()
        windowSnapshotTime = Date()
        return windowSnapshot
    }

    func coveredDisplays(maxAge: TimeInterval = 0.4) -> Set<CGDirectDisplayID> {
        guard Config.shared.yieldToFullscreenWindows else { return [] }
        if Date().timeIntervalSince(coveredDisplayCacheTime) < maxAge { return coveredDisplayCache }
        var managed = Set<CGWindowID>()
        for state in spaces.values {
            state.root?.forEachLeaf { leaf in
                guard let w = leaf.window else { return }
                if let id = w.lastKnownID ?? AX.windowID(w.element) { managed.insert(id) }
            }
        }
        // A game stays on screen behind whatever you alt-tab to, so covering alone would keep us
        // stood down while you work in a window on top of it. The test is the FRONTMOST APP, not
        // z-order: Mosaic raises its own tiles on every render, so a z-order test sees one of them
        // in front, concludes you are working, and disables itself — permanently, since the next
        // render raises them again. Which app you are in can't loop that way.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var workingOn = Set<CGDirectDisplayID>()
        for state in spaces.values {
            state.root?.forEachVisibleLeaf { leaf in
                guard let w = leaf.window, w.app.processIdentifier == front, let f = w.frame else { return }
                if let did = displayID(forCocoaRect: Geometry.flip(f)) { workingOn.insert(did) }
            }
        }
        let mine = ProcessInfo.processInfo.processIdentifier
        let windows = onScreenSnapshot(maxAge: maxAge).filter { $0.pid != mine && !managed.contains($0.id) }
        var covered = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            let did = displayID(of: screen)
            guard !workingOn.contains(did) else { continue }   // you're in a tile on this one
            let frame = Geometry.flip(screen.frame)
            if windows.contains(where: { Geometry.covers(screen: frame, window: $0.bounds) }) {
                covered.insert(did)
            }
        }
        coveredDisplayCache = covered
        coveredDisplayCacheTime = Date()
        return covered
    }

    /// The display a Cocoa rect sits on, by its centre.
    func displayID(forCocoaRect rect: CGRect) -> CGDirectDisplayID? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) }.map { displayID(of: $0) }
    }

    /// Is this Cocoa rect on a display a game has taken over?
    func isCovered(cocoaRect rect: CGRect) -> Bool {
        guard let did = displayID(forCocoaRect: rect) else { return false }
        return coveredDisplays().contains(did)
    }

    func render(activate: Bool = true) {
        let __perf = DispatchTime.now(); defer { Perf.record("render", since: __perf) }
        let __pro = DispatchTime.now()
        guard let root, let screen = activeScreen else { return }
        Perf.record("render.activeScreen", since: __pro)

        // A screenshot tool is grabbing the screen → hide every overlay so it isn't buried under
        // (or captured with) our decorations. They come back on the next render when it dismisses.
        if Perf.span("render.screenshotCheck", { screenshotToolFrontmost() }) {
            letterbox.hideAll(); windowBorders.hideAll(); focusIndicator.hide(); zoomBadge.hide()
            return
        }

        // Recomputed once per render so everything below agrees on which displays to leave alone.
        let covered = Perf.span("render.coveredDisplays") { coveredDisplays(maxAge: 0) }
        let hidden = covered.contains(displayID(of: screen))   // this screen belongs to a game

        // Monocle: the focused tile fills the screen; every overlay is hidden so nothing
        // floats over it. The tree keeps its frames for when we un-zoom.
        let area = layoutRect(screen)
        if active?.isZoomed == true, let w = focused?.window {
            if activate && !hidden { w.activateApp() }
            if !w.isFullscreen && !hidden { AX.raise(w.element) }   // raising a fullscreen tile would yank its Space
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
            // A settled letterboxed zoom touches the screen on its LONG axis (fit-to-width or
            // fit-to-height). Require that before trusting "already centred" — otherwise a small
            // aspect-fit window that happens to sit dead-centre (e.g. IINA alone in the middle column,
            // centred by aspectFit) is mistaken for a finished zoom and never blown up.
            let spansOneAxis = cur.width >= area.width - 8 || cur.height >= area.height - 8
            let centeredAlready = !fills && spansOneAxis && abs(cur.midX - area.midX) < 3 && abs(cur.midY - area.midY) < 3
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
            if Config.shared.borderEnabled && !hidden { focusIndicator.show(around: frameForBorder) } else { focusIndicator.hide() }
            if hidden { zoomBadge.hide() } else { zoomBadge.show(on: screen) }
            scheduleSave()
            return
        }
        zoomBadge.hide()   // not (or no longer) zoomed → drop the badge

        Perf.span("render.selectTabs") { if let f = focused { selectTabsOnPath(to: f) } }
        Perf.span("render.arrange") { root.arrange(in: area) }
        if !hidden { Perf.span("render.raiseWindows") { root.raiseVisibleWindows() } }   // never lift a tile over the game

        // The same enumeration `coveredDisplays` just took, reused by the activate check and
        // updateFocusIndicator below rather than taken a second time.
        let onScreen = Perf.span("render.onScreenIDs") { Set(onScreenSnapshot().map { $0.id }) }
        // Never raise a managed window onto a display a game owns — that is what puts the tiles
        // you left behind in front of the game.
        if activate, let w = focused?.window,
           let id = AX.windowID(w.element), onScreen.contains(id),
           !(w.frame.map { isCovered(cocoaRect: Geometry.flip($0)) } ?? false) {
            // makeMain BEFORE activating: else activating the app first surfaces its old
            // main window (another tab of the same app) for a frame before we raise ours.
            Perf.span("render.makeMain") { AX.makeMain(w.element) }
            Perf.span("render.activateApp") { w.activateApp() }
            Perf.span("render.axRaise") { AX.raise(w.element) }
        }
        Perf.span("render.raiseStrips") { root.raiseVisibleStrips() }
        Perf.span("render.parkCrossApp") { parkHiddenCrossAppTabs(on: screen) }

        // Heal the OTHER shown monitors' window POSITIONS on every render, so drift on a non-active
        // screen (an app nudged its window, a late wake, a new window) doesn't wait for a manual
        // visit. Position only — no raise/activate — so it never touches focus or cross-app z-order.
        // setCocoaFrame skips unchanged frames, so a settled monitor re-writes nothing.
        Perf.span("render.arrangeOthers") {
            for (did, n) in shownOnDisplay where n != activeSpaceID {
                if let ws = spaces[n], let scr = self.screen(forDisplayID: did) { ws.root?.arrange(in: layoutRect(scr)) }
            }
        }

        Perf.span("render.sweepStrips") { sweepOrphanStrips() }   // hide strips not on any desktop's visible path
        Perf.span("render.handles") { layoutResizeHandles() }
        // Tab strips and resize handles are floating windows too: pull them off a covered display
        // AFTER the passes above have placed them.
        for (did, wsNum) in shownOnDisplay where covered.contains(did) {
            spaces[wsNum]?.root?.forEachTabbed { $0.hideStrip() }
        }
        if hidden { hideAllHandles() }
        Perf.span("render.opacity") { applyOpacity() }
        Perf.span("render.aspectFit") { refreshAspectRatios() }   // fit + centre aspect-locked windows (IINA)
        Perf.span("render.decorate") { decorateTiles() }   // permanent borders + letterbox gap fill
        Perf.span("render.dimBars") { dimInactiveMonitorTabBars() }   // fade strips off the focused monitor
        Perf.span("render.focusHalo") { updateFocusIndicator(onScreen: onScreen) }   // halo LAST, on top

        // While the scratchpad is up, keep the tiles' overlays hidden so nothing floats
        // over it (a reconcile-triggered render would otherwise re-show them).
        if scratchpadVisible {
            root.forEachTabbed { $0.hideStrip() }
            hideAllHandles()
        }
        Perf.span("render.scheduleSave") { scheduleSave() }
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
                // The PiP source's whole tile is covered (it's shown here but mirrored in the PiP).
                if leaf === pipSourceLeaf {
                    let tile = leaf.lastFrame
                    if tile.width > 0, tile.height > 0 { letterbox.fill(tile) }
                    return
                }
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

    /// Learn each visible aspect-fit window's true ratio (IINA & co) and re-centre it inside its tile.
    /// arrange() places a known-ratio window straight into its fit box; the FIRST time (ratio unknown)
    /// it placed the full slot, so the window snapped to its native aspect — we read that back here and
    /// immediately fit+centre it (AX setFrame is synchronous, so this settles within the same render,
    /// no overshoot flash). Re-learns if the video's aspect later changes. Runs before decorateTiles so
    /// the letterbox is computed off the fitted frame.
    func refreshAspectRatios() {
        let gap = CGFloat(Config.shared.gap)
        for (did, wsNum) in shownOnDisplay {
            guard screen(forDisplayID: did) != nil, let root = spaces[wsNum]?.root else { continue }
            root.forEachVisibleLeaf { leaf in
                guard let w = leaf.window, w.isAspectFit, !w.isFullscreen,
                      let f = w.frame, f.width > 1, f.height > 1 else { return }
                let cand = f.width / f.height
                if w.aspectRatio == 0 || abs(cand - w.aspectRatio) / w.aspectRatio > 0.02 {
                    w.aspectRatio = cand
                    w.setCocoaFrame(Geometry.aspectFit(leaf.lastFrame.insetBy(dx: gap / 2, dy: gap / 2), aspect: cand))
                }
            }
        }
    }

    /// One pass over every shown, visible tile that drives BOTH the inactive border AND the letterbox
    /// gap fill from a SINGLE AX frame read per window. render() and the live-resize path both need
    /// both overlays; reading each window's frame twice (once per overlay) on the hot 90fps drag path
    /// adds up, so this fuses them. Mirrors updateWindowBorders + updateLetterboxFill exactly.
    func decorateTiles() {
        if scratchpadVisible { windowBorders.hideAll(); letterbox.hideAll(); return }
        let drawBorders = Config.shared.borderInactive
        let activeDid = activeMonitorID()
        let covered = coveredDisplays()
        if drawBorders { windowBorders.begin() }
        letterbox.begin()
        let t: CGFloat = 8   // ignore sub-8px mismatches — too small to be worth a bar
        for (did, wsNum) in shownOnDisplay {
            guard screen(forDisplayID: did) != nil, let root = spaces[wsNum]?.root else { continue }
            guard !covered.contains(did) else { continue }   // a game owns this one — draw nothing
            let dim = activeDid != nil && did != activeDid
            root.forEachVisibleLeaf { leaf in
                // The PiP source's whole tile is covered (shown here but mirrored in the PiP); no border.
                if leaf === pipSourceLeaf {
                    let tile = leaf.lastFrame
                    if tile.width > 0, tile.height > 0 { letterbox.fill(tile) }
                    return
                }
                guard let w = leaf.window, !w.isFullscreen, let wf = w.frame else { return }
                let win = Geometry.flip(wf)
                if drawBorders { windowBorders.border(around: win, dim: dim) }
                let tile = leaf.lastFrame
                guard tile.width > 0, tile.height > 0 else { return }
                func bar(_ r: NSRect) { letterbox.fill(r.intersection(tile)) }
                if win.minY > tile.minY + t { bar(NSRect(x: tile.minX, y: tile.minY, width: tile.width, height: win.minY - tile.minY)) }
                if win.maxY < tile.maxY - t { bar(NSRect(x: tile.minX, y: win.maxY, width: tile.width, height: tile.maxY - win.maxY)) }
                if win.minX > tile.minX + t { bar(NSRect(x: tile.minX, y: win.minY, width: win.minX - tile.minX, height: win.height)) }
                if win.maxX < tile.maxX - t { bar(NSRect(x: win.maxX, y: win.minY, width: tile.maxX - win.maxX, height: win.height)) }
            }
        }
        if drawBorders { windowBorders.end() }
        letterbox.end()
    }

    /// Draw a dim accent border on every shown, non-focused tiled window (opt-in `borderInactive`),
    /// so the whole tiling reads as one outlined layout — the focused window keeps its brighter
    /// FocusIndicator + halo on top.
    func updateWindowBorders() {
        guard Config.shared.borderInactive, !scratchpadVisible else { windowBorders.hideAll(); return }
        windowBorders.begin()
        // Optionally fade the borders on monitors without keyboard focus (the active one holds the
        // focused window) so a glance says "you are here".
        let activeDid = activeMonitorID()
        let covered = coveredDisplays()
        // Border EVERY visible window, focused included — the borders are permanent so a focus change
        // never leaves a window bare. The focus halo is drawn afterwards, on top, so it still leads.
        for (did, wsNum) in shownOnDisplay {
            guard screen(forDisplayID: did) != nil, let root = spaces[wsNum]?.root else { continue }
            guard !covered.contains(did) else { continue }   // a game owns this one — draw nothing
            let dim = activeDid != nil && did != activeDid
            root.forEachVisibleLeaf { leaf in
                guard let w = leaf.window, !w.isFullscreen, let wf = w.frame else { return }
                windowBorders.border(around: Geometry.flip(wf), dim: dim)
            }
        }
        windowBorders.end()
    }

    /// The active monitor = the one showing the active workspace (the monitor the focus is on, which
    /// the mouse-follows model keeps in sync via checkSpaceChange). nil when the dim feature is off.
    func activeMonitorID() -> CGDirectDisplayID? {
        guard Config.shared.dimInactiveMonitors else { return nil }
        return activeSpaceID.flatMap { asid in shownOnDisplay.first { $0.value == asid }?.key }
    }

    /// Fade the tab strips on monitors without keyboard focus (opt-in `dimInactiveMonitors`), so the
    /// focused screen reads at a glance. When off, everything is restored to full opacity.
    func dimInactiveMonitorTabBars() {
        let activeDid = activeMonitorID()
        for bar in TabBarWindow.registry.allObjects where bar.isVisible {
            let center = NSPoint(x: bar.frame.midX, y: bar.frame.midY)
            let did = NSScreen.screens.first { $0.frame.contains(center) }.map { displayID(of: $0) }
            bar.alphaValue = (activeDid != nil && did != nil && did != activeDid) ? Config.shared.inactiveMonitorDim : 1
        }
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
    /// Move the focus halo and, when the monitor-dim feature is on, re-evaluate which monitor is
    /// faded — for the "light" focus-change paths (focus-sync, hint jump) that skip a full render,
    /// so the dim follows focus immediately. Re-show the halo last so it stays on top of the borders.
    func refreshFocusAndDim() {
        if Config.shared.dimInactiveMonitors {
            updateWindowBorders()
            dimInactiveMonitorTabBars()
        }
        updateFocusIndicator()
    }

    func updateFocusIndicator(onScreen: Set<CGWindowID>? = nil) {
        // The focus contour re-shows from many paths (focus sync, mouse, reconcile); stand all of
        // them down while a screenshot tool is up, else the border creeps back over its overlay.
        if screenshotToolFrontmost() { focusIndicator.hide(); return }
        if scratchpadVisible { focusIndicator.hide(); return }   // never over the scratchpad
        let ps: Bool? = (preselect?.leaf === focused) ? preselect?.vertical : nil
        // Show if the border is enabled OR a preselect is armed (so the cue is visible
        // even when borders are off).
        guard Config.shared.borderEnabled || ps != nil else { focusIndicator.hide(); return }
        // Only draw around a window that's actually on the current Space & on screen — a
        // stale/off-space focused window would otherwise get a border in empty space.
        // Focus never moves to an unmanaged window, so without this the halo stays pinned to the
        // last managed tile — tracing the screen edge over the game — for as long as you play.
        if let w = focused?.window, let frame = w.frame, !w.isFullscreen,
           let id = AX.windowID(w.element), (onScreen ?? AX.onScreenWindowIDs()).contains(id),
           !isCovered(cocoaRect: Geometry.flip(frame)) {
            focusIndicator.show(around: Geometry.flip(frame), preselect: ps)
        } else {
            focusIndicator.hide()
        }
    }

}

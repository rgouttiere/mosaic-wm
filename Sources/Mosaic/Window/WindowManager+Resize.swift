import AppKit

extension WindowManager {
    // MARK: - Mouse resize handles

    /// Place an invisible draggable handle on every interior split border.
    func layoutResizeHandles() {
        var needed: [(container: Container, index: Int, horizontal: Bool, rect: NSRect)] = []
        if let root { collectBoundaries(root, into: &needed) }

        while handles.count < needed.count {
            let handle = ResizeHandle()
            handle.onDrag = { [weak self] h, mouse in self?.applyResize(h, mouse: mouse) }
            handle.onUp = { [weak self] in
                self?.learnResizeMins()     // now the windows have settled → learn real mins + re-clamp
                self?.render(activate: false)  // full render: final positions + restore the parked hidden tabs
                self?.saveNow()
            }
            handles.append(handle)
        }
        for (i, handle) in handles.enumerated() {
            if i < needed.count {
                let b = needed[i]
                handle.container = b.container
                handle.index = b.index
                handle.place(at: b.rect, horizontal: b.horizontal)
            } else {
                handle.orderOut(nil)
            }
        }
    }

    func collectBoundaries(_ node: Container,
                                   into out: inout [(container: Container, index: Int, horizontal: Bool, rect: NSRect)]) {
        guard !node.isLeaf else { return }
        let f = node.lastFrame
        if (node.layout == .splitH || node.layout == .splitV),
           node.children.count > 1, f.width > 0, f.height > 0 {
            node.normalizeRatios()
            let t = max(10, Config.shared.gap + 2)
            var acc: CGFloat = 0
            for i in 0..<(node.children.count - 1) {
                acc += node.ratios[i]
                if node.layout == .splitH {
                    let x = f.minX + acc * f.width
                    out.append((node, i, true, NSRect(x: x - t / 2, y: f.minY, width: t, height: f.height)))
                } else {
                    let y = f.maxY - acc * f.height   // Cocoa: first child is on top
                    out.append((node, i, false, NSRect(x: f.minX, y: y - t / 2, width: f.width, height: t)))
                }
            }
        }
        node.children.forEach { collectBoundaries($0, into: &out) }
    }

    func applyResize(_ handle: ResizeHandle, mouse: NSPoint) {
        guard let c = handle.container, c.children.count > handle.index + 1 else { return }
        c.normalizeRatios()
        let f = c.lastFrame
        guard f.width > 0, f.height > 0 else { return }
        let axis = handle.horizontal ? f.width : f.height
        let i = handle.index
        let before = c.ratios[0..<i].reduce(0, +)
        let frac = handle.horizontal
            ? (mouse.x - f.minX) / axis - before
            : (f.maxY - mouse.y) / axis - before
        commitPairResize(c, i, proposedRatioForI: frac, horizontal: handle.horizontal, live: true)
    }

    /// Drop `resizeMinCache` entries whose container has left every Space's tree. The cache is
    /// keyed by object identity and otherwise cleared only in `build()`, so a container that was
    /// pair-resized and then collapsed (e.g. by a window close) would keep its learned minimum
    /// for the manager's lifetime — a slow, bounded leak. Cheap: the cache only ever holds
    /// pair-resized split children, and this runs only when a reconcile actually removed a leaf.
    func pruneResizeCache() {
        guard !resizeMinCache.isEmpty else { return }
        var live = Set<ObjectIdentifier>()
        func walk(_ n: Container) { live.insert(ObjectIdentifier(n)); n.children.forEach(walk) }
        for (_, state) in spaces { if let r = state.root { walk(r) } }
        resizeMinCache = resizeMinCache.filter { live.contains($0.key) }
    }

    /// Set the split point of the pair (i, i+1). Clamps UP FRONT using each tile's
    /// known minimum (cached, else 60pt baseline) so it never overshoots and snaps —
    /// the source of the jitter. The first time a window reveals a larger minimum we
    /// learn it and re-clamp once; afterwards it's pinned smoothly. Shared by mouse
    /// (live) and keyboard resize.
    func commitPairResize(_ c: Container, _ i: Int, proposedRatioForI proposed: CGFloat,
                                  horizontal: Bool, live: Bool) {
        guard c.children.indices.contains(i + 1) else { return }
        let f = c.lastFrame
        guard f.width > 0, f.height > 0 else { return }
        let axis = horizontal ? f.width : f.height
        let pair = c.ratios[i] + c.ratios[i + 1]
        let idI = ObjectIdentifier(c.children[i]), idJ = ObjectIdentifier(c.children[i + 1])

        func clamp(_ value: CGFloat) -> CGFloat {
            let minI = min(pair / 2, max(0.05, (resizeMinCache[idI] ?? 60) / axis))
            let minJ = min(pair / 2, max(0.05, (resizeMinCache[idJ] ?? 60) / axis))
            let lo = minI, hi = pair - minJ
            return lo <= hi ? min(hi, max(lo, value)) : pair / 2
        }
        func draw() { live ? scheduleLiveRender() : render() }

        c.ratios[i] = clamp(proposed)
        c.ratios[i + 1] = pair - c.ratios[i]
        draw()

        // The learned-min readback (2 AX frame reads + a possible re-clamp render) is deferred to the
        // END of the gesture (learnResizeMins, from onUp / the keyboard settle) — running it on every
        // mouse-move event, 120+/s, is pure overhead and reads a not-yet-resized frame anyway. During
        // the drag the clamp just uses whatever min we already learned (or the 60pt baseline).
        lastResizePair = (c, i, horizontal)
        if !live { learnResizeMins() }

        // Live ratio readout centered on the divider, fading out shortly after the last change.
        let pctI = Int((c.ratios[i] / pair * 100).rounded())
        let cum = c.ratios[0...i].reduce(0, +)
        let divider = horizontal ? NSPoint(x: f.minX + cum * f.width, y: f.midY)
                                 : NSPoint(x: f.midX, y: f.maxY - cum * f.height)
        resizeRatioHUD.show("\(pctI) / \(100 - pctI)", at: divider)
    }

    /// Read back the now-settled windows of the last-resized pair, learn any real minimum size an app
    /// refused to shrink under, and re-clamp the split once so it can't overshoot. Called at the end
    /// of a gesture (mouse-up / keyboard settle), not per event.
    func learnResizeMins() {
        guard let (c, i, horizontal) = lastResizePair, c.children.indices.contains(i + 1) else { return }
        let f = c.lastFrame
        guard f.width > 0, f.height > 0 else { return }
        let axis = horizontal ? f.width : f.height
        let pair = c.ratios[i] + c.ratios[i + 1]
        let idI = ObjectIdentifier(c.children[i]), idJ = ObjectIdentifier(c.children[i + 1])
        let actI = visibleAxisExtent(of: c.children[i], horizontal: horizontal)
        let actJ = visibleAxisExtent(of: c.children[i + 1], horizontal: horizontal)
        var learned = false
        if actI > c.ratios[i] * axis + 2, actI > (resizeMinCache[idI] ?? 0) { resizeMinCache[idI] = actI; learned = true }
        if actJ > c.ratios[i + 1] * axis + 2, actJ > (resizeMinCache[idJ] ?? 0) { resizeMinCache[idJ] = actJ; learned = true }
        guard learned else { return }
        let minI = min(pair / 2, max(0.05, (resizeMinCache[idI] ?? 60) / axis))
        let minJ = min(pair / 2, max(0.05, (resizeMinCache[idJ] ?? 60) / axis))
        let lo = minI, hi = pair - minJ
        c.ratios[i] = lo <= hi ? min(hi, max(lo, c.ratios[i])) : pair / 2
        c.ratios[i + 1] = pair - c.ratios[i]
        // Caller renders (a full render() at gesture end, which also restores the hidden tabs the
        // live path parked off-screen) — no render here.
    }

    /// Largest actual size (along `horizontal`) among the visible windows in a subtree.
    /// After an attempted shrink, a window that hit its minimum reports that minimum here.
    func visibleAxisExtent(of node: Container, horizontal: Bool) -> CGFloat {
        var maxSize: CGFloat = 0
        func walk(_ n: Container) {
            if n.isLeaf {
                if let fr = n.window?.frame { maxSize = max(maxSize, horizontal ? fr.width : fr.height) }
            } else if n.layout == .tabbed {
                let idx = min(max(n.selected, 0), n.children.count - 1)
                if n.children.indices.contains(idx) { walk(n.children[idx]) }
            } else {
                n.children.forEach(walk)
            }
        }
        walk(node)
        return maxSize
    }

    /// Re-arrange + reposition handles during a drag, without stealing focus or saving. Only the
    /// visible path is arranged (visibleOnly); hidden tabs are parked off-screen once so they can't
    /// flash "behind" the tiling as arrange would otherwise drag them on-screen every frame.
    func renderLive() {
        guard let root, let screen = activeScreen else { return }
        root.arrange(in: layoutRect(screen), visibleOnly: true)
        parkHiddenTabsLive(on: screen)
        refreshAspectRatios()   // keep IINA fit+centred as the tile shrinks/grows
        layoutResizeHandles()
        // Borders + letterbox in one pass: borders follow the moving edges, and the gap fill runs
        // live too — a growing tile outruns the async AX resize, and the uncovered slice would
        // otherwise flash the parked window / wallpaper underneath (throttled by scheduleLiveRender).
        decorateTiles()
        updateFocusIndicator()  // halo on top
    }

    /// During a live resize, shove EVERY hidden tab (any app) off-screen so nothing peeks out from
    /// behind the shrinking/growing tiles. Uses each hidden leaf's last arranged rect, which the
    /// visibleOnly arrange left untouched — so the target is stable across the drag and setCocoaFrame's
    /// cache collapses it to a single write per window at gesture start (cross-app tabs are already
    /// parked, so those are skipped outright). The end-of-gesture full render() restores them.
    func parkHiddenTabsLive(on screen: NSScreen) {
        guard let root else { return }
        let lr = layoutRect(screen), pr = parkRect(for: screen)
        let dx = pr.minX - lr.minX, dy = pr.minY - lr.minY
        root.forEachTabbed { group in
            let kids = group.children
            guard kids.count > 1 else { return }
            let sel = min(max(group.selected, 0), kids.count - 1)
            for (i, child) in kids.enumerated() where i != sel {
                child.forEachLeaf { leaf in
                    guard let w = leaf.window, !w.isFullscreen, leaf.lastFrame.width > 0 else { return }
                    w.setCocoaFrame(leaf.lastFrame.offsetBy(dx: dx, dy: dy))
                }
            }
        }
    }

    /// After a keyboard-resize burst (held/repeated key), persist the layout once things go quiet.
    /// The live path never saves per keypress; this coalesces to a single write when the burst ends.
    func scheduleResizeSettle() {
        resizeSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.learnResizeMins()        // burst over, windows settled → learn real mins + re-clamp
            self?.render(activate: false)  // full render: final positions + restore the parked hidden tabs
            self?.saveNow()
        }
        resizeSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Coalesce live-resize renders to ~90fps with a guaranteed trailing render, so a burst of
    /// drag events can't pile up more arrange+overlay work than the screen can show.
    func scheduleLiveRender() {
        let minInterval = 1.0 / 90.0
        let since = Date().timeIntervalSince(lastLiveRenderTime)
        if since >= minInterval {
            lastLiveRenderTime = Date()
            renderLive()
        } else if !liveRenderPending {
            liveRenderPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (minInterval - since)) { [weak self] in
                guard let self else { return }
                self.liveRenderPending = false
                self.lastLiveRenderTime = Date()
                self.renderLive()
            }
        }
    }

    func hideAllHandles() {
        for handle in handles { handle.orderOut(nil) }
    }

    /// Hide any tab-bar strip not present in ANY desktop's tree — a leftover/orphan.
    /// Strips belonging to other desktops' trees are kept (macOS hides them off-space).
    /// Write a full snapshot (per-space trees + every visible tab bar's frame) to
    /// /tmp/mosaic-dump.txt for diagnostics.
    func dumpLayout() {
        var out = "=== Mosaic layout dump ===\n"
        out += "activeSpaceID=\(activeSpaceID.map(String.init) ?? "nil")  screens=\(NSScreen.screens.count)  suspended=\(suspended)\n"
        for scr in NSScreen.screens {
            out += "  monitor \(displayID(of: scr)) frame=\(rectStr(scr.frame)) visible=\(rectStr(scr.visibleFrame)) shows=\(shownOnDisplay[displayID(of: scr)].map(String.init) ?? "—")\n"
        }
        let screenFrames = NSScreen.screens.map { $0.frame }
        let onScreen = AX.onScreenWindowIDs()
        out += "\n"
        for (id, st) in spaces.sorted(by: { $0.key < $1.key }) {
            let scr = screen(forDisplayID: st.displayID)
            let state = screen(forWorkspace: id) != nil ? "SHOWN" : "PARKED"
            out += "WORKSPACE \(id) [\(state)]  homeDisplay=\(st.displayID) (\(scr != nil ? "present" : "MISSING"))  mode=\(modeName(st.mode))\n"
            st.root?.forEachLeaf { leaf in
                guard let w = leaf.window else { out += "    (dead leaf)\n"; return }
                let id = w.lastKnownID ?? AX.windowID(w.element)
                let f = w.frame.map { Geometry.flip($0) }   // Cocoa
                let visible = f.map { rect in screenFrames.contains { $0.intersects(rect) } } ?? false
                let onScr = id.map { onScreen.contains($0) } ?? false
                out += "    \(w.appName.prefix(16).padding(toLength: 16, withPad: " ", startingAt: 0)) wid=\(id.map(String.init) ?? "nil")  frame=\(f.map(rectStr) ?? "nil")  intersectsScreen=\(visible)  cgOnScreen=\(onScr)\n"
            }
            if st.root == nil { out += "    (empty)\n" }
            if let r = st.root { out += dumpTree(r, depth: 2) }
            out += "\n"
        }
        // What each SHOWN, visible leaf gets decoration-wise — exactly mirrors updateFocusIndicator
        // / updateWindowBorders selection, so a "missing border" bug is visible right here.
        let focusedW = focused?.window
        out += "--- focus + inactive borders (borderInactive=\(Config.shared.borderInactive)) ---\n"
        out += "focused: \(focusedW.map { "\($0.appName) wid=\(($0.lastKnownID ?? AX.windowID($0.element)).map(String.init) ?? "nil")" } ?? "nil")\n"
        for (did, wsNum) in shownOnDisplay.sorted(by: { $0.key < $1.key }) {
            guard screen(forDisplayID: did) != nil, let root = spaces[wsNum]?.root else { continue }
            root.forEachVisibleLeaf { leaf in
                guard let w = leaf.window else { return }
                let wid = (w.lastKnownID ?? AX.windowID(w.element)).map(String.init) ?? "nil"
                let mark = w.isFullscreen ? "fullscreen (skip)"
                    : (w === focusedW ? "FOCUSED → halo"
                    : (leaf === pipSourceLeaf ? "PiP source → covered"
                    : "inactive → border"))
                let flipped = w.frame.map { Geometry.flip($0) }
                let onScr = flipped.map { rect in NSScreen.screens.contains { $0.frame.intersects(rect) } } ?? false
                out += "  mon\(did)/ws\(wsNum)  \(w.appName.prefix(14).padding(toLength: 14, withPad: " ", startingAt: 0)) wid=\(wid)  → \(mark)  border@\(flipped.map(rectStr) ?? "nil") onScreen=\(onScr)  tile=\(rectStr(leaf.lastFrame))\n"
            }
        }
        out += "--- visible tab bars (\(TabBarWindow.registry.allObjects.filter { $0.isVisible }.count)) ---\n"
        for bar in TabBarWindow.registry.allObjects where bar.isVisible {
            out += "  frame=\(rectStr(bar.frame))\n"
        }
        try? out.write(to: URL(fileURLWithPath: "/tmp/mosaic-dump.txt"), atomically: true, encoding: .utf8)
        NSLog("Mosaic: layout dumped to /tmp/mosaic-dump.txt")
    }

    func rectStr(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }

    /// Compact recursive view of a layout tree — node kind, selected index, per-leaf window.
    private func dumpTree(_ node: Container, depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth)
        if node.isLeaf {
            let w = node.window
            let wid = w.flatMap { $0.lastKnownID ?? AX.windowID($0.element) }.map(String.init) ?? "nil"
            return "\(pad)• leaf \(w?.appName ?? "(dead)") wid=\(wid)\n"
        }
        let kind: String
        switch node.layout {
        case .splitH: kind = "splitH"
        case .splitV: kind = "splitV"
        case .tabbed: kind = node.stacked ? "stacked" : "tabbed"
        }
        var s = "\(pad)▸ \(kind) [\(node.children.count) kids, selected=\(node.selected)]\n"
        for c in node.children { s += dumpTree(c, depth: depth + 1) }
        return s
    }

    func sweepOrphanStrips() {
        guard !tabDragging else { return }
        dropHighlight.hide()   // the drop highlight must only ever show during a drag
        var active = Set<ObjectIdentifier>()
        for state in spaces.values { state.root?.collectActiveStrips(into: &active) }
        for strip in TabBarWindow.registry.allObjects where !active.contains(ObjectIdentifier(strip)) {
            strip.orderOut(nil)
        }
    }

}

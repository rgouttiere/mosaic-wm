import AppKit

/// A node in the i3-style layout tree. A `Container` is either:
///   • a **leaf** — it holds exactly one `ManagedWindow`; or
///   • a **split/tabbed container** — it holds child containers laid out by `layout`.
///
/// Tabs are not a special object here: a tabbed group is simply a container whose
/// `layout` is `.tabbed`. That unifies tiling and tabbing into one editable tree.
final class Container {
    enum Layout {
        case splitH   // children left → right
        case splitV   // children top → bottom
        case tabbed   // children stacked, one visible, tab strip on top
    }

    weak var parent: Container?
    var layout: Layout
    var children: [Container]
    /// Fraction of the parent split each child occupies (sums to 1). Unused for leaves.
    var ratios: [CGFloat]
    /// The window, for leaves only. A `var` so a leaf can adopt a replacement window in
    /// place — e.g. when an app swaps one window for another (IINA's launcher → video).
    var window: ManagedWindow?
    /// Set on the leaf currently mirrored in the picture-in-picture (maintained by the WindowManager).
    /// The tab bar badges it, so you can tell at a glance where the floating PiP's video comes from
    /// even though the tile itself is showing a sibling tab.
    var isPiPSource = false
    /// Does this subtree hold the PiP source? A tab entry can be a nested group, not a bare leaf.
    var containsPiPSource: Bool { isPiPSource || children.contains { $0.containsPiPSource } }
    /// Selected child index, for `.tabbed` containers. Always kept in range.
    var selected = 0 {
        didSet {
            let clamped = children.isEmpty ? 0 : min(max(selected, 0), children.count - 1)
            if clamped != selected { selected = clamped }
        }
    }
    /// For a `.tabbed` container: render the strip as a vertical title list (i3
    /// "stacking") instead of horizontal tabs. Semantics are identical to tabbed.
    var stacked = false

    /// Fired when a tab is clicked, so the manager can refocus and re-render.
    var onTabSelect: ((Container, Int) -> Void)?
    /// Fired when a (row, segment) is clicked in a stacked group (segment = sub-tab of an
    /// inline tab-group entry).
    var onStackSelect: ((Container, Int, Int) -> Void)?
    /// Fired when a tab is dragged onto another position (drag & drop reorder).
    var onReorder: ((Container, Int, Int) -> Void)?
    /// Fired when a tab is dropped outside its bar (move to another group/window).
    var onDropOutside: ((Container, Int, NSPoint) -> Void)?
    /// Fired true/false around a tab drag (so the manager can freeze the active desktop).
    var onTabDragState: ((Bool) -> Void)?
    /// Fired with the global mouse location during a tab drag (for the drop highlight).
    var onTabDragMove: ((NSPoint) -> Void)?

    private var tabBar: TabBarWindow?
    private var tabBarHeight: CGFloat { Config.shared.tabBarHeight }
    /// Set by `WindowManager.layoutRect` for the screen about to be arranged: `smartGaps` zeroes
    /// the gap where a single window has nothing to be separated from. A global because the gap is
    /// read deep in the recursion, on leaves that know nothing about which screen they are on.
    static var gapOverride: CGFloat?
    private var gap: CGFloat { Container.gapOverride ?? Config.shared.gap }

    var isLeaf: Bool { window != nil }

    init(window: ManagedWindow) {
        self.window = window
        self.layout = .splitH
        self.children = []
        self.ratios = []
    }

    init(layout: Layout, children: [Container]) {
        self.window = nil
        self.layout = layout
        self.children = children
        self.ratios = Container.equalRatios(children.count)
        for child in children { child.parent = self }
    }

    // MARK: - Identity & introspection

    var title: String {
        if let window { return "\(window.appName) — \(window.title)" }
        return children.first?.title ?? "group"
    }

    /// App icon for this node's window (or its first leaf's), for the tab/stack strip.
    var appIcon: NSImage? { window?.app.icon ?? children.first?.appIcon }

    func firstLeaf() -> Container {
        isLeaf ? self : (children.first?.firstLeaf() ?? self)
    }

    /// The first ON-SCREEN leaf, honoring tab/stack selection: a tabbed container descends into its
    /// `selected` child, splits into their first. Unlike `firstLeaf` this lands on the tab actually
    /// visible — used to restore focus onto last session's selected tab instead of snapping to tab 0.
    func firstVisibleLeaf() -> Container {
        guard !isLeaf, !children.isEmpty else { return self }
        if layout == .tabbed {
            let i = min(max(selected, 0), children.count - 1)
            return children[i].firstVisibleLeaf()
        }
        return children[0].firstVisibleLeaf()
    }

    func forEachLeaf(_ body: (Container) -> Void) {
        if isLeaf { body(self) } else { children.forEach { $0.forEachLeaf(body) } }
    }

    /// Visit each on-screen TILE: a leaf, or a whole tabbed container (so its tabs can be
    /// drawn as a group). Splits are recursed.
    func forEachTile(_ body: (Container) -> Void) {
        if isLeaf || layout == .tabbed { body(self); return }
        children.forEach { $0.forEachTile(body) }
    }

    /// Like `forEachLeaf` but visits only windows that are actually on screen: in a tabbed
    /// (or stacked) container, just the selected child — so hidden tabs are skipped.
    func forEachVisibleLeaf(_ body: (Container) -> Void) {
        if isLeaf { body(self); return }
        if layout == .tabbed {
            let i = min(max(selected, 0), children.count - 1)
            if children.indices.contains(i) { children[i].forEachVisibleLeaf(body) }
        } else {
            children.forEach { $0.forEachVisibleLeaf(body) }
        }
    }

    func forEachTabbed(_ body: (Container) -> Void) {
        if !isLeaf {
            if layout == .tabbed { body(self) }
            children.forEach { $0.forEachTabbed(body) }
        }
    }

    /// Raise only the windows that are actually visible: in a tabbed container that's
    /// just the selected child. Hidden tabs are never raised, so switching tabs can't
    /// flash the others underneath.
    func raiseVisibleWindows() {
        // Never raise a full-screen window: AX-raising it could pull its Space forward.
        guard !isLeaf else {
            if window?.isFullscreen != true { window?.raiseWindowOnly() }
            return
        }
        if layout == .tabbed {
            // Raise ONLY the selected entry. Raising hidden entries (even "first") makes
            // one of them briefly land on top → a 1-frame flash of the tab underneath when
            // switching tabs. The selected entry going to front is all that's needed.
            let i = min(max(selected, 0), children.count - 1)
            if children.indices.contains(i) { children[i].raiseVisibleWindows() }
        } else {
            children.forEach { $0.raiseVisibleWindows() }
        }
    }

    func index(of child: Container) -> Int? {
        children.firstIndex { $0 === child }
    }

    /// Remove the child at `index`, keeping `selected` pointing at the SAME element rather than
    /// the same slot: removing a child BELOW `selected` shifts every later child down one, so
    /// `selected` must decrement too — otherwise a tabbed/stacked group silently shows/raises
    /// the wrong window (e.g. [A,B,C,D] sel=2 shows C; close A → [B,C,D] and sel=2 now shows D).
    /// The `selected` didSet only clamps the upper bound, which never catches this lower shift.
    /// Also drops the child's ratio slice. Does NOT collapse a now-single-child parent — the
    /// caller decides that (it needs the owning SpaceState).
    func removeChild(at index: Int) {
        guard children.indices.contains(index) else { return }
        children.remove(at: index)
        if index < selected { selected -= 1 }
        else { selected = min(selected, max(0, children.count - 1)) }
        removeRatio(at: index)
    }

    // MARK: - Ratios

    static func equalRatios(_ count: Int) -> [CGFloat] {
        count > 0 ? Array(repeating: 1 / CGFloat(count), count: count) : []
    }

    /// Keep `ratios` consistent with the child count (reset to equal if mismatched).
    func normalizeRatios() {
        if ratios.count != children.count {
            ratios = Container.equalRatios(children.count)
        }
    }

    /// Call AFTER inserting a child at `index`: give it a fair share while keeping the
    /// other children's relative sizes (so adding a window doesn't reset manual resizes).
    func addRatio(at index: Int) {
        let newCount = children.count
        guard newCount > 1, ratios.count == newCount - 1 else {
            ratios = Container.equalRatios(newCount); return
        }
        let scale = CGFloat(newCount - 1) / CGFloat(newCount)
        for i in ratios.indices { ratios[i] *= scale }
        ratios.insert(1 / CGFloat(newCount), at: min(max(index, 0), ratios.count))
    }

    /// Call AFTER removing the child at `index`: drop its slice and renormalize the rest
    /// proportionally (remaining windows keep their relative sizes).
    func removeRatio(at index: Int) {
        guard ratios.indices.contains(index) else { normalizeRatios(); return }
        ratios.remove(at: index)
        guard ratios.count == children.count, !ratios.isEmpty else {
            normalizeRatios(); return
        }
        let total = ratios.reduce(0, +)
        if total > 0 { ratios = ratios.map { $0 / total } }
        else { ratios = Container.equalRatios(ratios.count) }
    }

    // MARK: - Layout

    /// The rect this node was last laid out in (Cocoa coords) — used to place resize handles.
    var lastFrame: NSRect = .zero

    /// Split `total` among `ratios`, but never give a child less than `mins[i]` along the axis.
    /// A child whose ratio-share falls under its min is PINNED to its min; the leftover is re-split
    /// among the rest by ratio (iterating, since pinning one can starve another). If the mins can't
    /// all fit (sum > total) every child still gets its min and the container simply overflows —
    /// there is no smaller size the windows accept. With all-zero mins this is a plain ratio split.
    static func solveSplit(total: CGFloat, ratios: [CGFloat], mins: [CGFloat]) -> [CGFloat] {
        let n = ratios.count
        guard n > 0 else { return [] }
        var out = [CGFloat](repeating: 0, count: n)
        var pinned = [Bool](repeating: false, count: n)
        while true {
            let pinnedSum = zip(pinned, mins).reduce(CGFloat(0)) { $1.0 ? $0 + $1.1 : $0 }
            let free = max(0, total - pinnedSum)
            let ratioSum = zip(pinned, ratios).reduce(CGFloat(0)) { $1.0 ? $0 : $0 + $1.1 }
            let open = pinned.filter { !$0 }.count
            var changed = false
            for i in 0..<n where !pinned[i] {
                let share = ratioSum > 0 ? free * ratios[i] / ratioSum : free / CGFloat(max(1, open))
                if share < mins[i] { pinned[i] = true; changed = true } else { out[i] = share }
            }
            if !changed {
                for i in 0..<n where pinned[i] { out[i] = mins[i] }
                return out
            }
        }
    }

    /// Size this node needs along the given axis (horizontal = width), from learned window floors.
    /// Splits along the axis sum their children; across it, take the max; tabs (overlapping) max.
    func minAxisSize(horizontal: Bool) -> CGFloat {
        if isLeaf { let m = window?.learnedMin ?? .zero; return horizontal ? m.width : m.height }
        switch layout {
        case .splitH:
            return horizontal ? children.reduce(0) { $0 + $1.minAxisSize(horizontal: true) }
                              : (children.map { $0.minAxisSize(horizontal: false) }.max() ?? 0)
        case .splitV:
            return horizontal ? (children.map { $0.minAxisSize(horizontal: true) }.max() ?? 0)
                              : children.reduce(0) { $0 + $1.minAxisSize(horizontal: false) }
        case .tabbed:
            // Only the SELECTED tab is on-screen; the others overlap it. Reserving the MAX over all
            // tabs lets a hidden tab freeze the column — e.g. IINA, whose aspect-lock inflates its
            // learnedMin.width to the full video width, so a background IINA tab would pin the whole
            // splitH and make it un-resizable. Mirror visibleAxisExtent: reserve for what's shown.
            let idx = min(max(selected, 0), children.count - 1)
            return children.indices.contains(idx) ? children[idx].minAxisSize(horizontal: horizontal) : 0
        }
    }

    /// `visibleOnly` (live-resize path): a tabbed group arranges ONLY its selected child, leaving
    /// hidden tabs untouched — arranging every tab into the visible content rect (the default) drags
    /// hidden windows on-screen each frame, and only a subsequent full render's parkHiddenCrossAppTabs
    /// pushes them back. During a 90fps drag there's no such pass, so they'd flash "behind" the tiling.
    /// The WM parks the hidden ones off-screen once at gesture start instead.
    /// Set when `WindowManager.parkHiddenCrossAppTabs` has moved this leaf off-screen: a hidden
    /// tab of a mixed-app group, which z-order can't keep behind the selected one because macOS
    /// stacks by app. `arrange` then records its geometry but issues no AX write, because the park
    /// would immediately undo it — and since each write undid the other, `setCocoaFrame`'s cache
    /// never skipped either, so every render paid two synchronous cross-process writes per hidden
    /// tab. Cleared for whichever tab becomes selected, in `arrangeTabbed`.
    var parkedOffScreen = false

    /// Lay this subtree out in `rect`. ONE implementation, two modes: `apply` true moves the real
    /// windows and places the strips; false only records the rect each node would occupy. Having the
    /// preview share this code is the whole point — it used to be a SECOND, approximate copy of the
    /// same geometry, free to drift from what `arrange` actually did (and it had: a stack holding a
    /// split was laid out differently by each).
    func arrange(in rect: NSRect, visibleOnly: Bool = false) {
        var sink: [ObjectIdentifier: NSRect] = [:]
        runLayout(in: rect, visibleOnly: visibleOnly, apply: true, into: &sink)
    }

    /// The rect each node WOULD occupy, without moving a window or touching a strip. The exposé
    /// needs it for a PARKED workspace: macOS clamps a parked window to a ~1px corner, so reading
    /// real frames has lost the layout entirely.
    func previewFrames(in rect: NSRect) -> [ObjectIdentifier: NSRect] {
        var out: [ObjectIdentifier: NSRect] = [:]
        runLayout(in: rect, visibleOnly: false, apply: false, into: &out)
        return out
    }

    /// The rect `arrange(in:)` writes for this leaf's window given its tile, or nil when it writes
    /// nothing. The one place the slot math lives, so a planned write and the real one never differ.
    /// - A full-screen window is not repositioned (it's on its own Space); it keeps its slot in the
    ///   tree and reclaims it when it leaves full screen. Nor is a parked hidden tab.
    /// - An aspect-locked window with a learned ratio gets the largest box of that ratio that fits
    ///   the slot, centred, so it never overshoots and freezes the column; the letterbox fill
    ///   (computed off the full-tile lastFrame) covers the surrounding gap.
    private func windowRect(forTile rect: NSRect) -> NSRect? {
        guard let w = window, w.isFullscreen != true, !parkedOffScreen else { return nil }
        let slot = rect.insetBy(dx: gap / 2, dy: gap / 2)
        return (w.isAspectFit && w.aspectRatio > 0) ? Geometry.aspectFit(slot, aspect: w.aspectRatio) : slot
    }

    /// What `arrange(in:)` is about to write, per visible leaf — so a caller can choose the ORDER
    /// of the writes (see `WindowManager.unparkWorkspace`). A measure pass plus the slot math.
    func plannedWindowFrames(in rect: NSRect) -> [(leaf: Container, frame: NSRect)] {
        let tiles = previewFrames(in: rect)
        var out: [(leaf: Container, frame: NSRect)] = []
        forEachVisibleLeaf { leaf in
            if let tile = tiles[ObjectIdentifier(leaf)], let f = leaf.windowRect(forTile: tile) { out.append((leaf, f)) }
        }
        return out
    }

    private func runLayout(in rect: NSRect, visibleOnly: Bool, apply: Bool,
                           into out: inout [ObjectIdentifier: NSRect]) {
        out[ObjectIdentifier(self)] = rect
        if apply { lastFrame = rect }
        guard !isLeaf else {
            guard apply else { return }
            tabBar?.orderOut(nil)
            if let f = windowRect(forTile: rect) { window?.setCocoaFrame(f) }
            return
        }
        guard !children.isEmpty else { return }
        if apply { normalizeRatios() }   // a preview must not mutate the tree it is measuring
        let r = ratios.count == children.count ? ratios : Container.equalRatios(children.count)

        switch layout {
        case .splitH:
            if apply { tabBar?.orderOut(nil) }
            let widths = Container.solveSplit(total: rect.width, ratios: r,
                                              mins: children.map { $0.minAxisSize(horizontal: true) })
            var x = rect.minX
            for (i, child) in children.enumerated() {
                child.runLayout(in: NSRect(x: x, y: rect.minY, width: widths[i], height: rect.height),
                                visibleOnly: visibleOnly, apply: apply, into: &out)
                x += widths[i]
            }

        case .splitV:
            if apply { tabBar?.orderOut(nil) }
            // Cocoa origin bottom-left: first child takes the top slice.
            let heights = Container.solveSplit(total: rect.height, ratios: r,
                                               mins: children.map { $0.minAxisSize(horizontal: false) })
            var y = rect.maxY
            for (i, child) in children.enumerated() {
                child.runLayout(in: NSRect(x: rect.minX, y: y - heights[i], width: rect.width, height: heights[i]),
                                visibleOnly: visibleOnly, apply: apply, into: &out)
                y -= heights[i]
            }

        case .tabbed:
            // A tab group with a single window shows no bar (avoids a phantom top gap).
            if children.count == 1 {
                if apply { tabBar?.orderOut(nil) }
                children[0].runLayout(in: rect, visibleOnly: visibleOnly, apply: apply, into: &out)
                return
            }
            if apply { selected = min(max(selected, 0), children.count - 1) }
            if stacked { layoutStacked(in: rect, apply: apply, into: &out) }
            else { layoutTabbed(in: rect, visibleOnly: visibleOnly, apply: apply, into: &out) }
        }
    }

    /// Horizontal tabs: one strip row; children fill the content below.
    private func layoutTabbed(in rect: NSRect, visibleOnly: Bool, apply: Bool,
                              into out: inout [ObjectIdentifier: NSRect]) {
        // Clamp to 0 (as the stacked path already does) so a tab group in a pane shorter than the
        // bar can't compute a negative height that flows into a negative kAXSize write.
        let content = NSRect(x: rect.minX, y: rect.minY, width: rect.width,
                             height: max(0, rect.height - tabBarHeight))
        let sel = min(max(selected, 0), children.count - 1)
        if apply {
            let bar = ensureTabBar()
            let strip = NSRect(x: rect.minX, y: rect.maxY - tabBarHeight, width: rect.width, height: tabBarHeight)
            bar.tabView.vertical = false
            bar.tabView.rows = []
            // Titles are AX reads — one synchronous round trip per tab, into the app. At the live
            // cadence of a resize that was every tab, every frame, for text that cannot change
            // mid-drag; the full render at settle (and the title observer) keep them fresh.
            if !visibleOnly {
                bar.tabView.titles = children.map { $0.title }
                bar.tabView.icons = children.map { $0.appIcon }
                bar.tabView.pipFlags = children.map { $0.containsPiPSource }
            }
            bar.tabView.selectedIndex = selected
            bar.place(at: strip)
        }
        if visibleOnly {
            // Live resize: only the shown tab is laid out; hidden tabs are left where they are (parked
            // off-screen by the WM) so they can't flash on-screen behind the tiling every frame.
            if children.indices.contains(sel) {
                children[sel].runLayout(in: content, visibleOnly: true, apply: apply, into: &out)
            }
            return
        }
        // Whatever becomes selected is on screen again: drop the park flag first, or this pass
        // would record its geometry and skip the very write that brings it back.
        if apply, children.indices.contains(sel) {
            children[sel].forEachLeaf { $0.parkedOffScreen = false }
        }
        for child in children {
            child.runLayout(in: content, visibleOnly: false, apply: apply, into: &out)
        }
    }

    /// Stacking with INLINE nested groups: one row per entry. A tab-group entry shows its
    /// tabs inline (a multi-segment row); leaf/split entries show a title row. Only the
    /// selected entry's content is arranged; nested groups never draw their own bar (this
    /// single strip draws everything — no overlapping overlays).
    private func layoutStacked(in rect: NSRect, apply: Bool, into out: inout [ObjectIdentifier: NSRect]) {
        // Two ways to draw a stack: full-width rows across the top (each row costs a bar height —
        // four rows ate 13 % of a laptop screen), or a narrow icon rail down the left edge, which
        // costs width, the cheap dimension. Same strip window, same data; only the geometry moves.
        // Clamped so a tall stack in a short pane can't produce a negative content height.
        let rail = Config.shared.stackStyle.lowercased() == "rail"
        let stripH = rail ? 0 : min(tabBarHeight * CGFloat(children.count), rect.height)
        let railW = rail ? min(Config.shared.railWidth, rect.width) : 0
        let content = NSRect(x: rect.minX + railW, y: rect.minY,
                             width: max(0, rect.width - railW), height: max(0, rect.height - stripH))
        if apply {
            let bar = ensureTabBar()
            let r = stackedRows()
            let strip = rail ? NSRect(x: rect.minX, y: rect.minY, width: railW, height: rect.height)
                             : NSRect(x: rect.minX, y: rect.maxY - stripH, width: rect.width, height: stripH)
            bar.tabView.vertical = true
            bar.tabView.rail = rail
            bar.tabView.titles = []
            bar.tabView.rows = r.titles
            bar.tabView.rowIcons = r.icons
            bar.tabView.rowPipFlags = r.pips
            bar.tabView.rowBadges = r.badges
            bar.tabView.rowIconKeys = r.keys
            bar.tabView.selectedSeg = r.selected
            bar.tabView.selectedRow = selected
            bar.place(at: strip)
        }
        for (i, child) in children.enumerated() {
            child.layoutStackEntry(in: content, visible: i == selected, apply: apply, into: &out)
        }
    }

    /// The inline rows of a stacked strip: one row per entry, a tab-group entry spread into segments.
    /// ONE builder for both the layout pass and a title refresh. They used to each carry a copy, and
    /// the refresh copy had no PiP flags — so a browser navigating wiped the badge off the strip
    /// until the next full render. Duplicated logic is exactly how that kind of bug is born.
    private func stackedRows() -> (titles: [[String]], icons: [[NSImage?]], pips: [[Bool]], selected: [Int], badges: [[Int?]], keys: [[String]]) {
        var rows: [[String]] = [], icons: [[NSImage?]] = [], pips: [[Bool]] = [], sel: [Int] = [], badges: [[Int?]] = [], keys: [[String]] = []
        func key(_ c: Container) -> String { c.firstLeaf().window?.app.bundleIdentifier ?? c.firstLeaf().window?.appName ?? "?" }
        for child in children {
            if !child.isLeaf, child.layout == .tabbed, !child.stacked, child.children.count > 1 {
                let titles = child.children.map { $0.title }
                rows.append(titles)
                icons.append(child.children.map { $0.appIcon })
                pips.append(child.children.map { $0.containsPiPSource })
                sel.append(min(max(child.selected, 0), child.children.count - 1))
                badges.append(titles.map(UnreadBadge.parse))   // from the same title read, no extra AX call
                keys.append(child.children.map(key))
            } else {
                let title = child.title
                rows.append([title]); icons.append([child.appIcon])
                pips.append([child.containsPiPSource]); sel.append(0)
                badges.append([UnreadBadge.parse(title)]); keys.append([key(child)])
            }
        }
        return (rows, icons, pips, sel, badges, keys)
    }

    /// Place a stack entry's window(s) in `rect`. A tabbed entry's own bar is never shown
    /// (drawn inline by the stack); a split entry tiles and shows its inner bars only when
    /// it's the visible entry; non-visible entries hide all their bars (placed behind).
    private func layoutStackEntry(in rect: NSRect, visible: Bool, apply: Bool,
                                  into out: inout [ObjectIdentifier: NSRect]) {
        out[ObjectIdentifier(self)] = rect
        if isLeaf {
            guard apply else { return }
            tabBar?.orderOut(nil)
            lastFrame = rect   // record the content tile (below the strip) — else the letterbox fills
                               // the stale full-tile gap and paints over the stack strip
            // The row on show is on screen again: drop the park flag FIRST, or this pass would skip
            // the very write that brings it back. A hidden row keeps its flag — this branch used to
            // place every hidden row on the tile each render only for the cross-app park to push it
            // away again: two writes per render per hidden row, measured on a stacked workspace.
            if visible { parkedOffScreen = false }
            if let f = windowRect(forTile: rect) { window?.setCocoaFrame(f) }
            return
        }
        if layout == .tabbed {
            if apply { tabBar?.orderOut(nil) }   // its tabs are inline in the ancestor stack
            let sel = min(max(selected, 0), children.count - 1)
            for (i, c) in children.enumerated() {
                c.layoutStackEntry(in: rect, visible: visible && i == sel, apply: apply, into: &out)
            }
            return
        }
        // split
        if visible {
            if apply { tabBar?.orderOut(nil); forEachLeaf { $0.parkedOffScreen = false } }   // on show again: release before placing
            runLayout(in: rect, visibleOnly: false, apply: apply, into: &out)   // tiles + its own inner bars
        } else if apply {
            hideBarsRecursively()
            // Same rule as a leaf's own placement: a hidden entry that the cross-app park already
            // pushed off-screen is NOT dragged back onto the tile. This branch skipped that check,
            // so every render placed each hidden stacked entry on its tile and the park pushed it
            // away again — the two-passes-fighting pattern the frame audit exists for, measured as
            // "3 writes in a render, repeatedly" on all six entries of a stacked mail/chat workspace.
            forEachLeaf { if let f = $0.windowRect(forTile: rect) { $0.window?.setCocoaFrame(f) } }
        } else {
            forEachLeaf { out[ObjectIdentifier($0)] = rect }   // stacked behind, all on the same tile
        }
    }

    func hideBarsRecursively() {
        tabBar?.orderOut(nil)
        children.forEach { $0.hideBarsRecursively() }
    }

    /// Re-read window titles into the strips WITHOUT moving any window — for live tab
    /// labels when a title changes (e.g. the browser navigates).
    func refreshBarTitles() {
        if layout == .tabbed, let bar = tabBar {
            if stacked {
                let r = stackedRows()
                bar.tabView.rows = r.titles
                bar.tabView.rowIcons = r.icons
                bar.tabView.rowPipFlags = r.pips
                bar.tabView.rowBadges = r.badges
                bar.tabView.rowIconKeys = r.keys
                bar.tabView.selectedSeg = r.selected
                bar.tabView.selectedRow = selected
            } else {
                bar.tabView.titles = children.map { $0.title }
                bar.tabView.icons = children.map { $0.appIcon }
                bar.tabView.pipFlags = children.map { $0.containsPiPSource }
                bar.tabView.selectedIndex = selected
            }
        }
        children.forEach { $0.refreshBarTitles() }
    }

    private func ensureTabBar() -> TabBarWindow {
        if let tabBar { return tabBar }
        let bar = TabBarWindow()
        bar.tabView.onSelect = { [weak self] index in
            guard let self else { return }
            self.onTabSelect?(self, index)
        }
        bar.tabView.onReorder = { [weak self] from, to in
            guard let self else { return }
            self.onReorder?(self, from, to)
        }
        bar.tabView.onDropOutside = { [weak self] index, point in
            guard let self else { return }
            self.onDropOutside?(self, index, point)
        }
        bar.tabView.onDragStateChange = { [weak self] dragging in
            self?.onTabDragState?(dragging)
        }
        bar.tabView.onDragMove = { [weak self] point in
            self?.onTabDragMove?(point)
        }
        bar.tabView.onStackSelect = { [weak self] row, seg in
            guard let self else { return }
            self.onStackSelect?(self, row, seg)
        }
        tabBar = bar
        return bar
    }

    /// True when this tab group is a DIRECT entry of a stack: its tabs are drawn inline in
    /// the stack's strip, so its own bar must never be shown.
    var isInlineInStack: Bool {
        guard let p = parent else { return false }
        return p.layout == .tabbed && p.stacked
    }

    /// Raise only the strips on the VISIBLE path: a tabbed/stacked container shows its own
    /// bar (unless inline in a stack) and recurses into its SELECTED child only; a split
    /// recurses into all children. Strips off the visible path stay hidden — no ghosts.
    func raiseVisibleStrips() {
        guard !isLeaf else { return }
        if layout == .tabbed {
            // A 1-child tab group draws no bar (arrange() passes through); inline groups are
            // drawn by their parent stack — hide their own bar in both cases.
            if isInlineInStack || children.count <= 1 { tabBar?.orderOut(nil) }
            else { tabBar?.orderFrontRegardless() }
            let i = min(max(selected, 0), children.count - 1)
            if children.indices.contains(i) { children[i].raiseVisibleStrips() }
        } else {
            children.forEach { $0.raiseVisibleStrips() }
        }
    }

    /// Strips on the visible path (mirrors `raiseVisibleStrips`), so the manager sweeps
    /// every OTHER strip — including off-path nested ones — with no lingering ghosts.
    func collectActiveStrips(into set: inout Set<ObjectIdentifier>) {
        guard !isLeaf else { return }
        if layout == .tabbed {
            if !isInlineInStack, children.count > 1, let tabBar { set.insert(ObjectIdentifier(tabBar)) }
            let i = min(max(selected, 0), children.count - 1)
            if children.indices.contains(i) { children[i].collectActiveStrips(into: &set) }
        } else {
            children.forEach { $0.collectActiveStrips(into: &set) }
        }
    }

    /// Hide just this container's strip (not its children's). Call when this node is
    /// removed from the tree so its overlay doesn't linger as an orphan.
    func hideStrip() {
        tabBar?.orderOut(nil)
    }

    func teardown() {
        tabBar?.orderOut(nil)
        children.forEach { $0.teardown() }
    }

    /// Human-readable tree dump for diagnostics. Marks the focused leaf with ★, and in a
    /// tabbed/stacked container tags each child VISIBLE (selected) or hidden.
    func dump(_ depth: Int = 0, focused: Container? = nil, visible: Bool = true) -> String {
        let pad = String(repeating: "  ", count: depth)
        if let w = window {
            let id = AX.windowID(w.element).map(String.init) ?? "nil"
            let f = w.frame.map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))×\(Int($0.height))" } ?? "nil"
            let tag = (self === focused ? "★" : " ") + (visible ? "" : " (hidden)")
            return "\(pad)•\(tag) \(w.appName) — \(w.title)  [id=\(id) fs=\(w.isFullscreen) \(f)]\n"
        }
        let kind = layout == .tabbed ? (stacked ? "stacked" : "tabbed")
                                     : (layout == .splitH ? "splitH" : "splitV")
        let barState = tabBar == nil ? "no-bar" : (tabBar!.isVisible ? "bar:shown" : "bar:hidden")
        var s = "\(pad)▸ \(kind) sel=\(selected) \(visible ? "" : "(hidden) ")\(barState)\n"
        let sel = min(max(selected, 0), children.count - 1)
        for (i, c) in children.enumerated() {
            let childVisible = visible && (layout != .tabbed || i == sel)
            s += c.dump(depth + 1, focused: focused, visible: childVisible)
        }
        return s
    }
}

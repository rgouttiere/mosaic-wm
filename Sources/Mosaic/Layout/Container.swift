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
    /// The window, for leaves only.
    let window: ManagedWindow?
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
    private var gap: CGFloat { Config.shared.gap }

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

    func arrange(in rect: NSRect) {
        lastFrame = rect
        guard !isLeaf else {
            tabBar?.orderOut(nil)
            // Don't reposition a full-screen window (it's on its own Space); it keeps
            // its slot in the tree and reclaims it when it leaves full screen.
            if window?.isFullscreen != true {
                window?.setCocoaFrame(rect.insetBy(dx: gap / 2, dy: gap / 2))
            }
            return
        }
        guard !children.isEmpty else { return }
        normalizeRatios()

        switch layout {
        case .splitH:
            tabBar?.orderOut(nil)
            var x = rect.minX
            for (i, child) in children.enumerated() {
                let w = rect.width * ratios[i]
                child.arrange(in: NSRect(x: x, y: rect.minY, width: w, height: rect.height))
                x += w
            }

        case .splitV:
            tabBar?.orderOut(nil)
            // Cocoa origin bottom-left: first child takes the top slice.
            var y = rect.maxY
            for (i, child) in children.enumerated() {
                let h = rect.height * ratios[i]
                child.arrange(in: NSRect(x: rect.minX, y: y - h, width: rect.width, height: h))
                y -= h
            }

        case .tabbed:
            // A tab group with a single window shows no bar (avoids a phantom top gap).
            if children.count == 1 {
                tabBar?.orderOut(nil)
                children[0].arrange(in: rect)
                return
            }
            selected = min(max(selected, 0), children.count - 1)
            if stacked { arrangeStacked(in: rect) } else { arrangeTabbed(in: rect) }
        }
    }

    /// Horizontal tabs: one strip row; children fill the content below.
    private func arrangeTabbed(in rect: NSRect) {
        let bar = ensureTabBar()
        let strip = NSRect(x: rect.minX, y: rect.maxY - tabBarHeight, width: rect.width, height: tabBarHeight)
        let content = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tabBarHeight)
        bar.tabView.vertical = false
        bar.tabView.rows = []
        bar.tabView.titles = children.map { $0.title }
        bar.tabView.icons = children.map { $0.appIcon }
        bar.tabView.selectedIndex = selected
        bar.place(at: strip)
        for child in children { child.arrange(in: content) }
    }

    /// Stacking with INLINE nested groups: one row per entry. A tab-group entry shows its
    /// tabs inline (a multi-segment row); leaf/split entries show a title row. Only the
    /// selected entry's content is arranged; nested groups never draw their own bar (this
    /// single strip draws everything — no overlapping overlays).
    private func arrangeStacked(in rect: NSRect) {
        let bar = ensureTabBar()
        var rows: [[String]] = []
        var rowIcons: [[NSImage?]] = []
        var selSeg: [Int] = []
        for child in children {
            if !child.isLeaf, child.layout == .tabbed, !child.stacked, child.children.count > 1 {
                rows.append(child.children.map { $0.title })
                rowIcons.append(child.children.map { $0.appIcon })
                selSeg.append(min(max(child.selected, 0), child.children.count - 1))
            } else {
                rows.append([child.title]); rowIcons.append([child.appIcon]); selSeg.append(0)
            }
        }
        // Clamp so a tall stack in a short pane can't produce a negative content height.
        let stripH = min(tabBarHeight * CGFloat(children.count), rect.height)
        let strip = NSRect(x: rect.minX, y: rect.maxY - stripH, width: rect.width, height: stripH)
        let content = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, rect.height - stripH))
        bar.tabView.vertical = true
        bar.tabView.titles = []
        bar.tabView.rows = rows
        bar.tabView.rowIcons = rowIcons
        bar.tabView.selectedSeg = selSeg
        bar.tabView.selectedRow = selected
        bar.place(at: strip)
        for (i, child) in children.enumerated() {
            child.arrangeStackEntry(in: content, visible: i == selected)
        }
    }

    /// Place a stack entry's window(s) in `rect`. A tabbed entry's own bar is never shown
    /// (drawn inline by the stack); a split entry tiles and shows its inner bars only when
    /// it's the visible entry; non-visible entries hide all their bars (placed behind).
    func arrangeStackEntry(in rect: NSRect, visible: Bool) {
        if isLeaf {
            tabBar?.orderOut(nil)
            if window?.isFullscreen != true { window?.setCocoaFrame(rect.insetBy(dx: gap / 2, dy: gap / 2)) }
            return
        }
        if layout == .tabbed {
            tabBar?.orderOut(nil)   // its tabs are inline in the ancestor stack
            let sel = min(max(selected, 0), children.count - 1)
            for (i, c) in children.enumerated() { c.arrangeStackEntry(in: rect, visible: visible && i == sel) }
            return
        }
        // split
        if visible {
            tabBar?.orderOut(nil)
            arrange(in: rect)   // tiles and shows its own inner (standalone) bars
        } else {
            hideBarsRecursively()
            forEachLeaf { if $0.window?.isFullscreen != true { $0.window?.setCocoaFrame(rect.insetBy(dx: gap / 2, dy: gap / 2)) } }
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
                var rows: [[String]] = [], icons: [[NSImage?]] = []; var sel: [Int] = []
                for child in children {
                    if !child.isLeaf, child.layout == .tabbed, !child.stacked, child.children.count > 1 {
                        rows.append(child.children.map { $0.title })
                        icons.append(child.children.map { $0.appIcon })
                        sel.append(min(max(child.selected, 0), child.children.count - 1))
                    } else {
                        rows.append([child.title]); icons.append([child.appIcon]); sel.append(0)
                    }
                }
                bar.tabView.rows = rows
                bar.tabView.rowIcons = icons
                bar.tabView.selectedSeg = sel
                bar.tabView.selectedRow = selected
            } else {
                bar.tabView.titles = children.map { $0.title }
                bar.tabView.icons = children.map { $0.appIcon }
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

    func raiseStrip() { tabBar?.orderFrontRegardless() }

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

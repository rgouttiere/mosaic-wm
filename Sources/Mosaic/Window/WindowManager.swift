import AppKit

enum Direction {
    case left, right, up, down
    var isHorizontal: Bool { self == .left || self == .right }
    var isForward: Bool { self == .right || self == .down }
}

/// Owns one persistent i3-style layout tree **per macOS Space** (desktop) on the
/// managed screen. Switching desktops swaps to that desktop's layout; with
/// `manageAll` on, every desktop is auto-tiled on first visit.
final class WindowManager {
    enum Mode: CaseIterable { case columns, grouped, tabbed }

    /// The layout state for a single desktop, including which display it lives on.
    private final class SpaceState {
        let displayID: CGDirectDisplayID
        var root: Container?
        weak var focused: Container?
        var mode: Mode = .columns
        var isZoomed = false   // focused tile fills the screen (monocle), follows focus
        init(displayID: CGDirectDisplayID) { self.displayID = displayID }
    }

    private var spaces: [UInt64: SpaceState] = [:]
    private var activeSpaceID: UInt64?
    private(set) var manageAll = false

    private var floatingApps: Set<String> = Config.shared.floatingApps

    /// Initial build strategy from config (falls back to columns).
    private var defaultMode: Mode {
        switch Config.shared.defaultMode.lowercased() {
        case "grouped": return .grouped
        case "tabbed": return .tabbed
        default: return .columns
        }
    }

    private lazy var observer = WindowObserver { [weak self] in self?.tick() }
    private let focusIndicator = FocusIndicator()
    private let dropHighlight = DropHighlight()
    private var spaceTimer: Timer?
    private var mouseMonitor: Any?
    private var mouseUpMonitor: Any?
    private var handles: [ResizeHandle] = []
    /// Discovered minimum size (points) per child container, so resize clamps up front
    /// instead of overshooting and snapping back every drag event.
    private var resizeMinCache: [ObjectIdentifier: CGFloat] = [:]

    /// Persisted layouts for desktops not yet restored this session.
    private var savedState: [UInt64: SavedSpace] = [:]
    private var saveWork: DispatchWorkItem?

    /// User-assigned workspace numbers (1-9) → Space id. Persisted.
    private var assignments: [Int: UInt64] = [:]
    /// Workspace number → app bundle id (used to switch to unmanaged/full-screen spaces).
    private var assignmentApps: [Int: String] = [:]

    /// The scratchpad app (by bundle id, persisted): all its windows stay out of tiling
    /// and are shown/hidden as a floating panel. Survives app/Mosaic relaunch.
    private var scratchpadBundleID: String?
    private var scratchpadVisible = false

    /// True while the machine/displays are asleep — no reconcile (AX is unreliable then).
    private var suspended = false
    /// Debounces display-config changes: we resume only once the set of displays has
    /// stopped changing (dock/undock fires many events and migrates windows mid-flight).
    private var displayChangeWork: DispatchWorkItem?
    /// Confirms a window kept "in grace" is really gone, so a closed window's tab is
    /// removed within ~0.25s instead of lingering until the next window event.
    private var graceRecheck: DispatchWorkItem?
    /// Guards reconcile against re-entrancy (all triggers are on the main queue, but this
    /// makes it impossible for a nested call to corrupt the tree mid-pass).
    private var isReconciling = false
    /// On-screen window IDs at the last reconcile that ran the full enumeration. If the
    /// set is unchanged and nothing closed, a reconcile can't have anything to do — used
    /// to skip the costly captureWindows() on pure focus/app switches.
    private var lastReconcileOnScreen: Set<CGWindowID> = []
    /// Recently-focused workspace numbers, most-recent first. Powers the switcher's recency
    /// ordering and the ⌘⌥B back-and-forth toggle.
    private var workspaceRecency: [Int] = []
    /// i3 "preselect": arm a split orientation on a window so the NEXT window nests into a
    /// new split with it. `vertical` = new window goes below; else to the right.
    private var preselect: (vertical: Bool, leaf: Container)?
    /// True while a tab is being dragged — freeze the active desktop so the drop
    /// re-renders the source screen correctly (mouse crossing screens won't switch it).
    private var tabDragging = false
    private let workspaceHUD = WorkspaceHUD()
    /// Notifies the menu bar of the current workspace number (nil = unknown/unmanaged).
    var onWorkspaceChanged: ((Int?) -> Void)?
    /// Supplies the Mosaic actions for the switcher's "Actions" mode (set by AppDelegate).
    var switcherActions: (() -> [(title: String, subtitle: String, run: () -> Void)])?
    private var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mosaic/state.json")
    }

    // Operate on the active desktop's state transparently.
    private var active: SpaceState? { activeSpaceID.flatMap { spaces[$0] } }
    private var activeScreen: NSScreen? { active.flatMap { screen(forDisplayID: $0.displayID) } }

    private func screen(forDisplayID id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Stable identity of the physical monitor behind `screen` (survives dock/undock &
    /// reboot, unlike the transient CGDirectDisplayID). Used to re-match saved layouts.
    private func displayUUID(of screen: NSScreen) -> String? {
        displayUUID(forID: displayID(of: screen))
    }
    private func displayUUID(forID id: CGDirectDisplayID) -> String? {
        guard id != 0, let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cf) as String
    }

    /// This Space's 0-based index among its display's Spaces (its "desktop ordinal").
    private func spaceOrdinal(of id: UInt64, on screen: NSScreen) -> Int? {
        Spaces.orderedSpaceIDs(for: screen).firstIndex(of: id)
    }
    private var root: Container? {
        get { active?.root }
        set { active?.root = newValue }
    }
    private var focused: Container? {
        get { active?.focused }
        set { active?.focused = newValue }
    }
    private var mode: Mode {
        get { active?.mode ?? .columns }
        set { active?.mode = newValue }
    }

    /// Re-apply config after it was reloaded from disk: refresh the floating-app set
    /// and re-render (gaps, tab-bar height & rules are read live from Config).
    func reloadConfig() {
        floatingApps = Config.shared.floatingApps
        resetAllOpacity()       // clear previous dimming; render re-applies per new config
        render()                // re-arrange with new gap / tab-bar height / border / opacity
        // Workspace names may have changed → republish status.json and fire the hook so
        // the external bar picks up new labels immediately (even if the number is unchanged).
        let screen = screenUnderMouse()
        let num = Spaces.currentSpaceID(for: screen).flatMap { workspaceNumber(for: $0) }
        writeStatusFile(focused: num)
        runWorkspaceHook(num)
    }

    func startObserving() {
        loadState()
        observer.onTitleChange = { [weak self] in self?.active?.root?.refreshBarTitles() }
        observer.onFocusChange = { [weak self] in self?.syncFocusToSystem() }
        observer.start()
        // Poll the current Space as a reliable fallback: the activeSpaceDidChange
        // notification is flaky, and without this the active desktop can go stale
        // (so edits would hit the previous desktop's layout).
        spaceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkSpaceChange()
            self?.sweepOrphanStrips()   // catch stray tab bars even without a render
            Perf.dumpIfDue()            // opt-in timing summary (no-op unless enabled)
        }
        // Focus-follows-click: clicking a managed window moves Mosaic's focus to it.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.focusWindowUnderMouse()
        }
        // Safety net: if a tab drag ends abnormally (strip hidden mid-drag, source app
        // dies, mouse-up off the strip), TabBarView's mouseUp never fires and `tabDragging`
        // would stay true — freezing desktop switching AND orphan-strip cleanup. A global
        // mouse-up always clears it.
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self, self.tabDragging else { return }
            self.tabDragging = false
            TabDragGhost.shared.hide()
            self.dropHighlight.hide()
            self.sweepOrphanStrips()
        }

        // Sleep/lock corrupts window AX state; suspend reconcile so we never mistake a
        // sleeping window for a closed one (which used to destroy a screen's layout).
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.suspended = true }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.handleWake() }
        }
        // Update the active desktop the instant macOS reports a Space change (the 0.4s poll
        // is only a fallback). The notification can fire before the switch settles, so
        // re-check after the transition too. Without this the focus border lags on the old
        // Space — very visible when two workspaces share one display.
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkSpaceChange()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in self?.checkSpaceChange() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleDisplayChange() }
    }

    /// Dock/undock (home ↔ office) fires a burst of screen-parameter changes while
    /// macOS adds/removes displays and migrates windows between them. If we reconcile
    /// mid-transition we absorb those migrated windows into the wrong workspace and
    /// lose the layout of the display that went away. So: freeze until the set of
    /// displays has been STABLE for a moment, then re-fit every present desktop.
    private func handleDisplayChange() {
        suspended = true
        displayChangeWork?.cancel()
        let before = Set(NSScreen.screens.map(displayID(of:)))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = Set(NSScreen.screens.map(self.displayID(of:)))
            guard now == before else { self.handleDisplayChange(); return }   // still settling
            self.suspended = false
            self.activeSpaceID = nil
            self.checkSpaceChange()
            self.refreshVisibleSpaces()
        }
        displayChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// After wake / display change, wait for macOS to restore displays & Spaces, then
    /// resume and re-detect/re-render (this also brings back the tab bars).
    private func handleWake() {
        suspended = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.suspended = false
            self.activeSpaceID = nil   // force a fresh detect + render of the current desktop
            self.checkSpaceChange()
            self.refreshVisibleSpaces()   // re-show tab bars on ALL screens, not just the mouse's
            // A slow wake can re-hide the overlays after we refresh; do it once more.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.refreshVisibleSpaces()
            }
        }
    }

    private func focusWindowUnderMouse() {
        checkSpaceChange()
        guard let root else { return }
        let mouse = NSEvent.mouseLocation
        guard let leaf = visibleLeaf(at: mouse, in: root), leaf !== focused else { return }
        focused = leaf
        preselect = nil          // focus moved → disarm any pending preselect
        updateFocusIndicator()   // border only — the click itself already focused the window
    }

    /// Adopt the system's focused window (keyboard focus, cmd-tab, app switch) into the
    /// tree. PASSIVE: updates the tab bars + focus border only, never activates/raises a
    /// window — so it can't fight the user or loop with our own raises. This is what keeps
    /// the tabs in sync without needing a click.
    private func syncFocusToSystem() {
        guard Config.shared.focusSync, !suspended, !tabDragging, let root else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let win: AXUIElement = AX.copy(axApp, kAXFocusedWindowAttribute as String),
              let id = AX.windowID(win) else { return }
        var target: Container?
        root.forEachLeaf { leaf in
            guard target == nil, let w = leaf.window else { return }
            if w.resolvedID() == id || w.lastKnownID == id { target = leaf }
        }
        guard let leaf = target, leaf !== focused else { return }
        focused = leaf
        preselect = nil          // focus moved → disarm any pending preselect
        updateFocusIndicator()   // move the focus border only — identical to a click, no re-tile/raise
    }

    /// The visible window under `point`: in a tabbed container only the selected child
    /// is on screen, so hidden tabs are never matched.
    private func visibleLeaf(at point: NSPoint, in node: Container) -> Container? {
        if node.isLeaf {
            guard let frame = node.window?.frame else { return nil }
            return Geometry.flip(frame).contains(point) ? node : nil
        }
        if node.layout == .tabbed {
            let i = min(max(node.selected, 0), node.children.count - 1)
            guard node.children.indices.contains(i) else { return nil }
            return visibleLeaf(at: point, in: node.children[i])
        }
        for child in node.children {
            if let hit = visibleLeaf(at: point, in: child) { return hit }
        }
        return nil
    }

    /// Detect a desktop switch and load that desktop's layout. Cheap when unchanged.
    private func checkSpaceChange() {
        guard !suspended, !tabDragging else { return }
        // Follow the screen the mouse is on: the active desktop is that screen's
        // current Space. Moving the mouse to another display activates its desktop.
        let screen = screenUnderMouse()
        guard let id = Spaces.currentSpaceID(for: screen) else { return }
        guard id != activeSpaceID else { return }
        NSLog("Mosaic: desktop \(activeSpaceID.map(String.init) ?? "nil") → \(id)")
        focusIndicator.hide()   // drop the focus rectangle immediately during the switch
        scratchpadVisible = false   // leaving its Space hides the floating scratchpad
        activeSpaceID = id
        if spaces[id] != nil {
            // Windows & tab bars persist per-desktop (macOS re-shows them), so DON'T
            // re-render — just absorb any window changes and move the focus border.
            reconcile()
            updateFocusIndicator()
        } else if restoreSaved(id, on: screen) {
            // restored a persisted layout for this desktop
        } else if manageAll {
            let st = SpaceState(displayID: displayID(of: screen))
            st.mode = defaultMode
            spaces[id] = st
            build()
        }
        layoutResizeHandles()   // reposition handles for the now-active desktop
        showWorkspaceIndicator(for: screen)
        // Draw the eye to the now-focused window, after the macOS Space transition settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.focusIndicator.pulse() }
    }

    // MARK: - Entry points

    /// Start (or rebuild) management of the current desktop on the screen under the mouse.
    func tileCurrentSpace() {
        let screen = screenUnderMouse()
        guard let id = Spaces.currentSpaceID(for: screen) else { return }
        let st = SpaceState(displayID: displayID(of: screen))
        st.mode = spaces[id]?.mode ?? defaultMode
        spaces[id] = st
        activeSpaceID = id
        build()
    }

    /// Cycle the build strategy for the current desktop and rebuild it.
    func cycleMode() {
        checkSpaceChange()
        guard let st = active else { return }
        let all = Mode.allCases
        if let i = all.firstIndex(of: st.mode) { st.mode = all[(i + 1) % all.count] }
        build()
    }

    /// Toggle "manage every desktop": when on, visiting any unmanaged desktop tiles it.
    func toggleManageAll() {
        manageAll.toggle()
        if manageAll {
            let screen = screenUnderMouse()
            if let id = Spaces.currentSpaceID(for: screen) {
                activeSpaceID = id
                if spaces[id] == nil {
                    let st = SpaceState(displayID: displayID(of: screen))
                    st.mode = defaultMode
                    spaces[id] = st
                    build()
                }
            }
        }
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

    private func tick() {
        guard !suspended else { return }
        checkSpaceChange()
        reconcile()
    }

    // MARK: - Build

    private func build() {
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

    private func makeTree(_ mode: Mode, from windows: [ManagedWindow]) -> Container {
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
        }
    }

    private func groupByApp(_ windows: [ManagedWindow]) -> [[ManagedWindow]] {
        var order: [pid_t] = []
        var byApp: [pid_t: [ManagedWindow]] = [:]
        for window in windows {
            if byApp[window.pid] == nil { order.append(window.pid) }
            byApp[window.pid, default: []].append(window)
        }
        return order.map { byApp[$0]! }
    }

    // MARK: - Live reconcile

    private func reconcile() {
        guard !suspended, !isReconciling, let root, let screen = activeScreen else { return }
        isReconciling = true
        let __perf = DispatchTime.now(); defer { Perf.record("reconcile", since: __perf) }
        defer { isReconciling = false }
        let onScreen = AX.onScreenWindowIDs()

        var aliveTreeIDs = Set<CGWindowID>()
        var deadLeaves: [Container] = []
        var gracePending = false
        root.forEachLeaf { leaf in
            guard let w = leaf.window else { deadLeaves.append(leaf); return }   // no window at all
            if let id = w.resolvedID() {
                // A full-screened window (e.g. a video) is temporarily on its own Space.
                // Keep it in the tree — neither counted as present nor detached — so it
                // returns to its exact place when it leaves full screen. Only its content
                // isn't arranged/raised while full screen (handled in Container).
                if !w.isFullscreen { aliveTreeIDs.insert(id) }
                return
            }
            // A hidden app (Cmd-H) leaves the screen but must keep its slot — treat like
            // full screen, never as a close. (Its windows aren't in captureWindows either,
            // so they won't be re-inserted elsewhere.)
            if w.app.isHidden {
                w.missCount = 0
                if let cached = w.lastKnownID { aliveTreeIDs.insert(cached) }
                return
            }
            // AX couldn't resolve the window. Before removing it, be sure it's really gone:
            //  • still in the window-server list (CoreGraphics) → just an AX glitch, keep it;
            //  • otherwise require it to miss twice → survives transient wake/dock hiccups.
            if let cached = w.lastKnownID, onScreen.contains(cached) {
                w.missCount = 0
                aliveTreeIDs.insert(cached)
            } else {
                w.missCount += 1
                if w.missCount >= 2 { deadLeaves.append(leaf) }          // confirmed closed
                else {
                    gracePending = true                                  // re-check soon
                    if let cached = w.lastKnownID { aliveTreeIDs.insert(cached) }   // grace: keep
                }
            }
        }

        // A window in grace: nothing else will fire the 2nd check, so a genuinely-closed
        // window's tab would linger. Re-run soon to confirm & remove it promptly.
        if gracePending {
            graceRecheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reconcile() }
            graceRecheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        // None of our windows visible → we've switched desktops; leave it untouched.
        // (Per-leaf glitch/close handling above already keeps transiently-invalid windows,
        // so an empty aliveTreeIDs here means a real switch or a real empty desktop.)
        if !aliveTreeIDs.isEmpty && aliveTreeIDs.isDisjoint(with: onScreen) { return }

        // Fast path: nothing closed, no grace recheck pending, and the on-screen window
        // set is unchanged since the last full reconcile → nothing could have been added
        // or removed. Skip the expensive enumeration (captureWindows) — this is what makes
        // a pure focus / app switch cheap instead of paying ~30ms of AX every time.
        if deadLeaves.isEmpty, !gracePending, onScreen == lastReconcileOnScreen { return }
        lastReconcileOnScreen = onScreen

        let windows = captureWindows(on: screen)
        let additions = windows.filter { window in
            guard let id = AX.windowID(window.element) else { return false }
            return !aliveTreeIDs.contains(id)
        }

        guard !deadLeaves.isEmpty || !additions.isEmpty else { return }

        for leaf in deadLeaves { detach(leaf) }
        for window in additions { insert(window) }

        guard let newRoot = self.root else { focusIndicator.hide(); return }
        if focused == nil || !treeContainsLeaf(focused!) { focused = newRoot.firstLeaf() }
        wireTabCallbacks(newRoot)
        observer.watchForClose(windows)
        render(activate: false)   // automatic update → never steal focus / switch desktop
    }

    private func detach(_ leaf: Container) {
        if let w = leaf.window, let id = AX.windowID(w.element) { w.setAlpha(1, id: id) }
        guard let parent = leaf.parent, let idx = parent.index(of: leaf) else {
            root = nil
            return
        }
        parent.children.remove(at: idx)
        leaf.parent = nil
        parent.removeRatio(at: idx)   // preserve remaining windows' relative sizes

        if parent.children.count == 1 {
            replace(parent, with: parent.children[0])
        } else if parent.children.isEmpty {
            detach(parent)
        }
    }

    private func replace(_ node: Container, with replacement: Container) {
        node.hideStrip()
        if let grandparent = node.parent, let idx = grandparent.index(of: node) {
            grandparent.children[idx] = replacement   // same child count → keep its ratios
            replacement.parent = grandparent
        } else {
            root = replacement
            replacement.parent = nil
        }
    }

    private func insert(_ window: ManagedWindow) {
        _ = window.resolvedID()   // cache its id now, so a later AX glitch can't make
                                  // reconcile treat it as new and insert a duplicate leaf
        let rule = ruleFor(window)

        // Rule: send this app's new windows to a specific workspace (if assigned and
        // not the current one). Places it there without disturbing this desktop.
        if let ws = rule?.workspace, let target = assignments[ws],
           target != activeSpaceID, let wid = AX.windowID(window.element) {
            placeOnSpace(window, wid: wid, space: target)
            return
        }

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
            insertAfterFocused(leaf)
        }
        focused = leaf
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
    private func applyPreselect(_ newLeaf: Container, vertical: Bool) {
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

    private func insertAfterFocused(_ leaf: Container) {
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

    private func insertAsColumn(_ leaf: Container) {
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
    private func groupNewLeaf(_ new: Container, with target: Container) {
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

    private func ruleFor(_ window: ManagedWindow) -> AppRule? {
        let name = window.appName.lowercased()
        let bundle = window.app.bundleIdentifier?.lowercased() ?? ""
        return Config.shared.rules.first { rule in
            let key = rule.app.lowercased()
            return name.contains(key) || bundle.contains(key)
        }
    }

    private func findLeaf(matchingApp name: String) -> Container? {
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
    private func moveOutward(_ f: Container, from parent: Container, idx: Int, direction: Direction) {
        if let grandparent = parent.parent, let pIdx = grandparent.index(of: parent) {
            parent.children.remove(at: idx)
            parent.removeRatio(at: idx)
            f.parent = grandparent
            let insertAt = direction.isForward ? pIdx + 1 : pIdx
            grandparent.children.insert(f, at: insertAt)
            grandparent.addRatio(at: insertAt)
            cleanupAfterRemoval(parent)
        } else if parent === root, parent.children.count > 1 {
            parent.children.remove(at: idx)
            parent.removeRatio(at: idx)
            let orient: Container.Layout = direction.isHorizontal ? .splitH : .splitV
            self.root = Container(layout: orient, children: direction.isForward ? [parent, f] : [f, parent])
            if parent.children.count == 1 { replace(parent, with: parent.children[0]) }
        }
    }

    private func cleanupAfterRemoval(_ container: Container) {
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

    private func groupWithNeighbor(stacked: Bool) {
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

    private func rootColumn(of leaf: Container) -> Container? {
        guard let root, leaf !== root else { return nil }
        var node = leaf
        while let parent = node.parent {
            if parent === root { return node }
            node = parent
        }
        return nil
    }

    private func collectLeaves(_ node: Container) -> [Container] {
        var result: [Container] = []
        node.forEachLeaf { result.append($0) }
        return result
    }

    func nextTab() { cycleTab(+1) }
    func prevTab() { cycleTab(-1) }

    /// Move a dragged tab into whatever group/window is under the drop point — works
    /// across desktops AND screens (source and target may be in different trees).
    private func dropTab(from source: Container, index: Int, at point: NSPoint) {
        dropHighlight.hide()   // the drag is ending — clear the highlight now
        guard source.children.indices.contains(index) else { return }
        let dragged = source.children[index]

        // Resolve the drop target across all managed screens/desktops.
        guard let dropScreen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let dropSpaceID = Spaces.currentSpaceID(for: dropScreen),
              let targetState = spaces[dropSpaceID],
              let targetRoot = targetState.root,
              let targetLeaf = visibleLeaf(at: point, in: targetRoot),
              targetLeaf !== dragged, !contains(dragged, targetLeaf),
              let sourceState = stateContaining(dragged) else { return }

        // Detach from the source tree and collapse what it leaves behind.
        if let parent = dragged.parent, let i = parent.index(of: dragged) {
            parent.children.remove(at: i)
            parent.selected = min(parent.selected, max(0, parent.children.count - 1))
            parent.removeRatio(at: i)
            collapse(parent, in: sourceState)
        }

        // Insert into the target tree.
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

        // Cross-desktop: move the window(s) to the target Space so they live there.
        if sourceState !== targetState {
            dragged.forEachLeaf { leaf in
                if let w = leaf.window, let wid = AX.windowID(w.element) {
                    Spaces.move(window: wid, toSpace: dropSpaceID)
                }
            }
        }

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

    /// Highlight the window/group under the cursor during a tab drag.
    private func updateDropHighlight(at point: NSPoint) {
        guard Config.shared.dropHighlightEnabled,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let spaceID = Spaces.currentSpaceID(for: screen),
              let root = spaces[spaceID]?.root,
              let leaf = visibleLeaf(at: point, in: root),
              let frame = leaf.window?.frame else {
            dropHighlight.hide()
            return
        }
        dropHighlight.show(around: Geometry.flip(frame))
    }

    private func stateContaining(_ node: Container) -> SpaceState? {
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
    private func collapse(_ container: Container, in state: SpaceState) {
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
                gp.children.remove(at: idx)
                gp.removeRatio(at: idx)
                collapse(gp, in: state)
            } else {
                state.root = nil
            }
        }
    }

    /// Arrange a (possibly non-active) desktop's tree on its own screen.
    private func arrangeState(_ state: SpaceState) {
        guard let r = state.root, let screen = screen(forDisplayID: state.displayID) else { return }
        r.arrange(in: layoutRect(screen))
        r.raiseVisibleWindows()
    }

    /// Re-arrange and re-show the layout (windows + tab bars) of the Space currently
    /// visible on EACH screen — not just the one under the mouse. After unlock/wake,
    /// macOS hides our borderless tab-bar overlays; a normal `checkSpaceChange` only
    /// refreshes the mouse's screen, leaving the others' strips gone. This re-shows all.
    private func refreshVisibleSpaces() {
        for screen in NSScreen.screens {
            guard let id = Spaces.currentSpaceID(for: screen),
                  let state = spaces[id], let r = state.root else { continue }
            r.arrange(in: layoutRect(screen))
            r.raiseVisibleWindows()
            r.raiseVisibleStrips()
        }
        sweepOrphanStrips()
    }

    private func contains(_ node: Container, _ leaf: Container) -> Bool {
        var found = false
        node.forEachLeaf { if $0 === leaf { found = true } }
        return found
    }

    private func cycleTab(_ step: Int) {
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
        guard displayID(of: target) != st.displayID,
              let targetSpace = Spaces.currentSpaceID(for: target) else { return }

        detach(leaf)
        leaf.parent = nil

        let tst = spaces[targetSpace] ?? {
            let s = SpaceState(displayID: displayID(of: target))
            s.mode = defaultMode
            spaces[targetSpace] = s
            return s
        }()
        appendLeaf(leaf, to: tst)
        tst.root?.arrange(in: layoutRect(target))          // physically moves the window
        if let r = tst.root { wireTabCallbacks(r) }
        tst.root?.forEachLeaf { $0.window?.raiseWindowOnly() }

        if focused == nil || !treeContainsLeaf(focused!) { focused = root?.firstLeaf() }
        render()
        saveNow()
    }

    /// Send the focused window to the next/previous desktop on the same display
    /// (private Space API; the window is absorbed into that desktop's layout on visit).
    func moveToDesktop(next: Bool) {
        checkSpaceChange()
        guard let screen = activeScreen, let current = activeSpaceID else { return }
        let ordered = Spaces.orderedSpaceIDs(for: screen)
        guard let idx = ordered.firstIndex(of: current) else {
            NSLog("Mosaic: could not resolve desktop order to move window"); return
        }
        moveToDesktopIndex(idx + (next ? 1 : -1))
    }

    func moveToDesktopIndex(_ index: Int) {
        let ordered = Spaces.orderedSpaceIDs(for: activeScreen ?? screenUnderMouse())
        guard ordered.indices.contains(index) else { return }
        moveFocused(toSpace: ordered[index])
    }

    // MARK: i3-style numbered workspaces (user-assigned numbers)

    /// Pin the current desktop to workspace number `n` (1-9).
    func assignWorkspace(_ n: Int) {
        let screen = screenUnderMouse()
        guard let space = Spaces.currentSpaceID(for: screen) else { return }
        assignments = assignments.filter { $0.key != n && $0.value != space }  // unique number & space
        assignments[n] = space
        // Remember the desktop's app so we can switch to it even when it's unmanaged
        // (e.g. a full-screen app on its own Space).
        assignmentApps[n] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        saveNow()
        showWorkspaceIndicator(for: screen)
    }

    /// Switch to the desktop assigned to workspace `n` (numbers are global across all
    /// screens — only user-assigned desktops have a number).
    func switchToWorkspace(_ n: Int) {
        let screen = screenUnderMouse()
        guard let target = assignments[n], target != Spaces.currentSpaceID(for: screen) else { return }
        switchTo(space: target, appHint: assignmentApps[n], on: screen)
    }

    /// Bounce to the previous workspace (i3 back-and-forth): recency[0] is current, [1] prior.
    func workspaceBack() {
        guard workspaceRecency.count >= 2 else { return }
        switchToWorkspace(workspaceRecency[1])
    }

    /// Vimium-style window hints: label every visible window; typing its letter focuses it.
    func showHints() {
        let onScreen = AX.onScreenWindowIDs()
        var targets: [HintTarget] = []
        for screen in NSScreen.screens {
            guard let sid = Spaces.currentSpaceID(for: screen), let root = spaces[sid]?.root else { continue }
            root.forEachVisibleLeaf { leaf in   // skip hidden tabs/stacks
                guard let w = leaf.window, let id = AX.windowID(w.element), onScreen.contains(id),
                      let axFrame = w.frame else { return }
                targets.append(HintTarget(frameCocoa: Geometry.flip(axFrame),
                                          focus: { [weak self] in self?.focusVisibleWindow(leaf) }))
            }
        }
        HintsOverlay.show(targets)
    }

    /// Focus a hinted window. If it's on another screen/desktop, warp the mouse onto it so
    /// the mouse-follows model adopts that desktop, then move Mosaic's focus + border there.
    private func focusVisibleWindow(_ leaf: Container) {
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
        let screen = screenUnderMouse()
        let current = Spaces.currentSpaceID(for: screen).flatMap { workspaceNumber(for: $0) }
        let ordered = assignments.keys.sorted { a, b in
            if a == current { return false }
            if b == current { return true }
            let ia = workspaceRecency.firstIndex(of: a) ?? Int.max
            let ib = workspaceRecency.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a < b
        }
        var wsItems: [SwitcherItem] = []
        var winItems: [SwitcherItem] = []
        for n in ordered {
            let root = assignments[n].flatMap { spaces[$0]?.root }
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

    private static func prettyAction(_ key: String) -> String {
        let s = key.replacingOccurrences(of: "-", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
    private static func prettyShortcut(_ combo: String) -> String {
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

    /// Bring a specific window forward: switch to its workspace's Space if needed, then
    /// activate it. The focus-sync observer adopts it into Mosaic's focus — no manual set.
    private func focusWindow(_ w: ManagedWindow, inWorkspace n: Int) {
        let screen = screenUnderMouse()
        if let target = assignments[n], target != Spaces.currentSpaceID(for: screen) {
            switchTo(space: target, appHint: w.app.bundleIdentifier, on: screen)
        }
        AX.makeMain(w.element)
        w.activateApp()
        AX.raise(w.element)
    }

    /// Send the focused window to the desktop assigned to workspace `n`.
    func moveToWorkspace(_ n: Int) {
        checkSpaceChange()
        guard let target = assignments[n] else { return }
        moveFocused(toSpace: target)
    }

    /// Bring `target` Space forward: activate a managed window on it; else activate the
    /// assigned app (handles full-screen apps on their own Space); else step via ⌃-arrows.
    private func switchTo(space target: UInt64, appHint: String?, on screen: NSScreen) {
        if let st = spaces[target], let w = (st.focused ?? st.root?.firstLeaf())?.window {
            AX.makeMain(w.element)
            w.activateApp()
        } else if let bundle = appHint,
                  let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) {
            app.activate()   // switches to the app's Space, incl. a full-screen one
        } else {
            let ordered = Spaces.orderedSpaceIDs(for: screen)
            if let current = Spaces.currentSpaceID(for: screen),
               let ci = ordered.firstIndex(of: current), let ti = ordered.firstIndex(of: target) {
                Spaces.step(by: ti - ci)
            }
        }
        warpMouseToSpace(target)
    }

    /// Optionally move the cursor onto the target desktop so the mouse-follows model
    /// stays aligned after a keyboard switch.
    private func warpMouseToSpace(_ space: UInt64) {
        guard Config.shared.warpMouseOnSwitch else { return }
        let cocoa: CGPoint
        if let st = spaces[space], let f = (st.focused ?? st.root?.firstLeaf())?.window?.frame {
            let r = Geometry.flip(f)
            cocoa = CGPoint(x: r.midX, y: r.midY)
        } else if let screen = screen(forSpace: space) {
            cocoa = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        } else {
            return
        }
        let cg = CGPoint(x: cocoa.x, y: Geometry.primaryHeight - cocoa.y)   // Cocoa → CG (top-left)
        CGWarpMouseCursorPosition(cg)
        CGAssociateMouseAndMouseCursorPosition(1)   // avoid the post-warp cursor freeze
    }

    private func moveFocused(toSpace target: UInt64) {
        checkSpaceChange()
        guard let leaf = focused, let w = leaf.window, let wid = AX.windowID(w.element),
              target != activeSpaceID else { return }
        // Refuse to move to a Space on a monitor that isn't currently attached — it would
        // fabricate a displayID-0 phantom state that can never render or be restored.
        guard let targetScreen = screen(forSpace: target) else { return }
        detach(leaf)
        leaf.parent = nil
        Spaces.move(window: wid, toSpace: target)   // move to the target desktop's Space

        // Register + tile it in the target desktop's layout and place it on that
        // desktop's *screen* (so cross-screen moves physically relocate the window).
        let tst = spaces[target] ?? {
            let s = SpaceState(displayID: displayID(of: targetScreen))
            s.mode = defaultMode
            spaces[target] = s
            return s
        }()
        appendLeaf(leaf, to: tst)
        tst.root?.arrange(in: layoutRect(targetScreen))
        tst.root?.forEachLeaf { $0.window?.raiseWindowOnly() }
        if let r = tst.root { wireTabCallbacks(r) }

        if focused == nil || !treeContainsLeaf(focused!) { focused = root?.firstLeaf() }
        render()
        saveNow()
    }

    private func screen(forSpace space: UInt64) -> NSScreen? {
        NSScreen.screens.first { Spaces.orderedSpaceIDs(for: $0).contains(space) }
    }

    /// Move a just-opened window to another workspace's Space and tile it there, without
    /// touching the current desktop (used by the `workspace` app rule). The window never
    /// enters the current tree — reconcile's caller returns right after.
    private func placeOnSpace(_ window: ManagedWindow, wid: CGWindowID, space target: UInt64) {
        Spaces.move(window: wid, toSpace: target)
        let targetScreen = screen(forSpace: target)
        let tst = spaces[target] ?? {
            let s = SpaceState(displayID: targetScreen.map(displayID(of:)) ?? 0)
            s.mode = defaultMode
            spaces[target] = s
            return s
        }()
        appendLeaf(Container(window: window), to: tst)
        if let ts = targetScreen {
            tst.root?.arrange(in: layoutRect(ts))
            tst.root?.forEachLeaf { $0.window?.raiseWindowOnly() }
        }
        if let r = tst.root { wireTabCallbacks(r) }
        NSLog("Mosaic: rule placed \(window.appName) on workspace space \(target)")
        scheduleSave()
    }

    /// The workspace number of a Space = its user-assigned number (global, unique), or
    /// nil if unassigned. No per-screen Mission Control ordinal (it collides across screens).
    private func workspaceNumber(for space: UInt64) -> Int? {
        assignments.first(where: { $0.value == space })?.key
    }

    /// Drop workspace assignments whose Space no longer exists (desktop deleted in
    /// Mission Control), so an orphaned number stops being published to status.json
    /// (and stops showing a dead pill in sketchybar).
    private func pruneStaleAssignments() {
        let live = Spaces.allSpaceIDs()
        guard !live.isEmpty else { return }   // unknown → never risk wiping valid assignments
        let stale = assignments.filter { !live.contains($0.value) }.map(\.key)
        guard !stale.isEmpty else { return }
        for n in stale { assignments[n] = nil; assignmentApps[n] = nil }
        saveNow()
    }

    private func showWorkspaceIndicator(for screen: NSScreen) {
        guard let space = Spaces.currentSpaceID(for: screen) else { return }
        let number = workspaceNumber(for: space)
        emitWorkspaceState(number)   // menu-bar icon + status file + shell hook (sketchybar…)
        // Only pop the HUD on a *managed* desktop → never flash a number over an
        // unmanaged Space such as a full-screen video.
        if let number, Config.shared.showWorkspaceHUD, spaces[space] != nil {
            workspaceHUD.show("\(number)", on: screen, position: Config.shared.hudPosition)
        }
    }

    private var statusURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mosaic/status.json")
    }
    private var lastEmittedWorkspace: Int? = -1   // sentinel: forces the first emit through

    /// Publish the current workspace state: update the menu bar, write status.json (for
    /// `mosaic query`), and run the configured shell hook on change (for sketchybar & co).
    private func emitWorkspaceState(_ focused: Int?) {
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

    private func writeStatusFile(focused: Int?) {
        var monitors: [[String: Any]] = []
        for screen in NSScreen.screens {
            guard let sp = Spaces.currentSpaceID(for: screen) else { continue }
            monitors.append(["display": Int(displayID(of: screen)),
                             "workspace": workspaceNumber(for: sp).map { $0 as Any } ?? NSNull()])
        }
        // Optional i3-style names, only for assigned workspaces that have one.
        var names: [String: String] = [:]
        // Home display (CGDirectDisplayID) of each assigned workspace, so an external bar
        // can show each workspace only on the monitor it lives on.
        var wsDisplays: [String: Int] = [:]
        for n in assignments.keys {
            if let nm = Config.shared.workspaceNames[n], !nm.isEmpty { names[String(n)] = nm }
            if let sid = assignments[n], let scr = screen(forSpace: sid) {
                wsDisplays[String(n)] = Int(displayID(of: scr))
            }
        }
        let dict: [String: Any] = [
            "focused": focused.map { $0 as Any } ?? NSNull(),
            "workspaces": assignments.keys.sorted(),
            "workspaceNames": names,
            "workspaceDisplays": wsDisplays,
            "monitors": monitors,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: statusURL, options: .atomic)
    }

    private func runWorkspaceHook(_ focused: Int?) {
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
    private func appendLeaf(_ leaf: Container, to state: SpaceState) {
        guard let r = state.root else { state.root = leaf; return }
        if !r.isLeaf, r.layout != .tabbed {
            r.children.append(leaf)
            leaf.parent = r
            r.addRatio(at: r.children.count - 1)
        } else {
            state.root = Container(layout: .splitH, children: [r, leaf])
        }
    }

    /// Designate the focused window's APP as the scratchpad (its windows leave tiling
    /// and hide). If the scratchpad is currently shown, the same combo RELEASES it.
    func sendToScratchpad() {
        checkSpaceChange()
        if scratchpadBundleID != nil, scratchpadVisible {
            let w = scratchpadWindow()
            scratchpadBundleID = nil
            scratchpadVisible = false
            saveNow()
            if let w { insert(w); render() }   // back into the tree
            return
        }
        guard let leaf = focused, let w = leaf.window, let bundle = w.app.bundleIdentifier else { return }
        scratchpadBundleID = bundle
        scratchpadVisible = false
        detach(leaf)
        AX.setMinimized(w.element, true)
        if focused == nil || !treeContainsLeaf(focused!) { focused = root?.firstLeaf() }
        saveNow()
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
        let screen = screenUnderMouse()
        if let space = Spaces.currentSpaceID(for: screen), let wid = AX.windowID(w.element) {
            Spaces.move(window: wid, toSpace: space)   // bring it to the desktop I'm on
        }
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
    private func scratchpadWindow() -> ManagedWindow? {
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

    // MARK: - Tree queries

    private func neighborLeaf(from leaf: Container, _ direction: Direction) -> Container? {
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

    private func descend(_ node: Container, _ direction: Direction) -> Container {
        guard !node.isLeaf, !node.children.isEmpty else { return node }
        switch node.layout {
        case .tabbed:
            return descend(node.children[min(max(node.selected, 0), node.children.count - 1)], direction)
        default:
            return descend(direction.isForward ? node.children.first! : node.children.last!, direction)
        }
    }

    private func nearestTabbed(from leaf: Container) -> Container? {
        var node: Container? = leaf.parent
        while let n = node {
            if n.layout == .tabbed { return n }
            node = n.parent
        }
        return nil
    }

    private func treeContainsLeaf(_ leaf: Container) -> Bool {
        var found = false
        root?.forEachLeaf { if $0 === leaf { found = true } }
        return found
    }

    private func selectTabsOnPath(to leaf: Container) {
        var child = leaf
        while let parent = child.parent {
            if parent.layout == .tabbed, let idx = parent.index(of: child) {
                parent.selected = idx
            }
            child = parent
        }
    }

    private func wireTabCallbacks(_ node: Container) {
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
    private func render(activate: Bool = true) {
        guard let root, let screen = activeScreen else { return }
        let __perf = DispatchTime.now(); defer { Perf.record("render", since: __perf) }

        // Monocle: the focused tile fills the screen; every overlay is hidden so nothing
        // floats over it. The tree keeps its frames for when we un-zoom.
        let area = layoutRect(screen)
        if active?.isZoomed == true, let w = focused?.window {
            w.setCocoaFrame(area)
            if activate { w.activateApp() }
            AX.raise(w.element)
            if let id = AX.windowID(w.element) { w.setAlpha(1, id: id) }   // zoomed = full opacity
            root.forEachTabbed { $0.hideStrip() }   // only THIS desktop's strips, not other screens'
            hideAllHandles()
            // Monocle = a single window fills the screen: the focus border only adds
            // noise over the content (nothing to disambiguate), so never draw it here.
            focusIndicator.hide()
            scheduleSave()
            return
        }

        if let f = focused { selectTabsOnPath(to: f) }
        root.arrange(in: area)
        root.raiseVisibleWindows()

        if activate, let w = focused?.window,
           let id = AX.windowID(w.element), AX.onScreenWindowIDs().contains(id) {
            // makeMain BEFORE activating: else activating the app first surfaces its old
            // main window (another tab of the same app) for a frame before we raise ours.
            AX.makeMain(w.element)
            w.activateApp()
            AX.raise(w.element)
        }
        root.raiseVisibleStrips()

        sweepOrphanStrips()   // hide strips not on any desktop's visible path
        updateFocusIndicator()
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
    private func applyOpacity() {
        guard let root else { return }
        let active = Float(Config.shared.activeOpacity)
        let inactive = Float(Config.shared.inactiveOpacity)
        guard active < 1 || inactive < 1 else { return }   // feature disabled
        let activeID = focused?.window.flatMap { AX.windowID($0.element) }
        root.forEachLeaf { leaf in
            guard let w = leaf.window, !w.isFullscreen, let id = AX.windowID(w.element) else { return }
            w.setAlpha(id == activeID ? active : inactive, id: id)
        }
    }

    /// Move/hide the focus border only — no window re-arranging. Used on screen
    /// switches so the tab layout isn't reloaded just to refresh the border.
    private func updateFocusIndicator() {
        if scratchpadVisible { focusIndicator.hide(); return }   // never over the scratchpad
        let ps: Bool? = (preselect?.leaf === focused) ? preselect?.vertical : nil
        // Show if the border is enabled OR a preselect is armed (so the cue is visible
        // even when borders are off).
        guard Config.shared.borderEnabled || ps != nil else { focusIndicator.hide(); return }
        // Only draw around a window that's actually on the current Space & on screen — a
        // stale/off-space focused window would otherwise get a border in empty space.
        if let w = focused?.window, let frame = w.frame, !w.isFullscreen,
           let id = AX.windowID(w.element), AX.onScreenWindowIDs().contains(id) {
            focusIndicator.show(around: Geometry.flip(frame), preselect: ps)
        } else {
            focusIndicator.hide()
        }
    }

    // MARK: - Mouse resize handles

    /// Place an invisible draggable handle on every interior split border.
    private func layoutResizeHandles() {
        var needed: [(container: Container, index: Int, horizontal: Bool, rect: NSRect)] = []
        if let root { collectBoundaries(root, into: &needed) }

        while handles.count < needed.count {
            let handle = ResizeHandle()
            handle.onDrag = { [weak self] h, mouse in self?.applyResize(h, mouse: mouse) }
            handle.onUp = { [weak self] in self?.saveNow() }
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

    private func collectBoundaries(_ node: Container,
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

    private func applyResize(_ handle: ResizeHandle, mouse: NSPoint) {
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

    /// Set the split point of the pair (i, i+1). Clamps UP FRONT using each tile's
    /// known minimum (cached, else 60pt baseline) so it never overshoots and snaps —
    /// the source of the jitter. The first time a window reveals a larger minimum we
    /// learn it and re-clamp once; afterwards it's pinned smoothly. Shared by mouse
    /// (live) and keyboard resize.
    private func commitPairResize(_ c: Container, _ i: Int, proposedRatioForI proposed: CGFloat,
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
        func draw() { live ? renderLive() : render() }

        c.ratios[i] = clamp(proposed)
        c.ratios[i + 1] = pair - c.ratios[i]
        draw()

        let actI = visibleAxisExtent(of: c.children[i], horizontal: horizontal)
        let actJ = visibleAxisExtent(of: c.children[i + 1], horizontal: horizontal)
        var learned = false
        if actI > c.ratios[i] * axis + 2, actI > (resizeMinCache[idI] ?? 0) { resizeMinCache[idI] = actI; learned = true }
        if actJ > c.ratios[i + 1] * axis + 2, actJ > (resizeMinCache[idJ] ?? 0) { resizeMinCache[idJ] = actJ; learned = true }
        if learned {
            c.ratios[i] = clamp(proposed)
            c.ratios[i + 1] = pair - c.ratios[i]
            draw()
        }
    }

    /// Largest actual size (along `horizontal`) among the visible windows in a subtree.
    /// After an attempted shrink, a window that hit its minimum reports that minimum here.
    private func visibleAxisExtent(of node: Container, horizontal: Bool) -> CGFloat {
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

    /// Re-arrange + reposition handles during a drag, without stealing focus or saving.
    private func renderLive() {
        guard let root, let screen = activeScreen else { return }
        root.arrange(in: layoutRect(screen))
        layoutResizeHandles()
        updateFocusIndicator()
    }

    private func hideAllHandles() {
        for handle in handles { handle.orderOut(nil) }
    }

    /// Hide any tab-bar strip not present in ANY desktop's tree — a leftover/orphan.
    /// Strips belonging to other desktops' trees are kept (macOS hides them off-space).
    /// Write a full snapshot (per-space trees + every visible tab bar's frame) to
    /// /tmp/mosaic-dump.txt for diagnostics.
    func dumpLayout() {
        var out = "=== Mosaic layout dump ===\n"
        out += "activeSpaceID=\(activeSpaceID.map(String.init) ?? "nil")  screens=\(NSScreen.screens.count)  suspended=\(suspended)\n\n"
        for (id, st) in spaces.sorted(by: { $0.key < $1.key }) {
            let scr = screen(forDisplayID: st.displayID)
            out += "SPACE \(id)  display=\(st.displayID) (\(scr != nil ? "present" : "MISSING"))  mode=\(modeName(st.mode))  zoom=\(st.isZoomed)\n"
            out += st.root?.dump(1, focused: st.focused) ?? "  (empty)\n"
            out += "\n"
        }
        out += "--- visible tab bars (\(TabBarWindow.registry.allObjects.filter { $0.isVisible }.count)) ---\n"
        for bar in TabBarWindow.registry.allObjects where bar.isVisible {
            let f = bar.frame
            out += "  frame=(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))\n"
        }
        try? out.write(to: URL(fileURLWithPath: "/tmp/mosaic-dump.txt"), atomically: true, encoding: .utf8)
        NSLog("Mosaic: layout dumped to /tmp/mosaic-dump.txt")
    }

    private func sweepOrphanStrips() {
        guard !tabDragging else { return }
        dropHighlight.hide()   // the drop highlight must only ever show during a drag
        var active = Set<ObjectIdentifier>()
        for state in spaces.values { state.root?.collectActiveStrips(into: &active) }
        for strip in TabBarWindow.registry.allObjects where !active.contains(ObjectIdentifier(strip)) {
            strip.orderOut(nil)
        }
    }

    // MARK: - Persistence

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        for (key, space) in state.spaces {
            if let id = UInt64(key) { savedState[id] = space }
        }
        for (key, space) in state.assignments ?? [:] {
            if let n = Int(key) { assignments[n] = space }
        }
        for (key, bundle) in state.assignmentApps ?? [:] {
            if let n = Int(key) { assignmentApps[n] = bundle }
        }
        scratchpadBundleID = state.scratchpadBundle
        NSLog("Mosaic: loaded \(savedState.count) saved desktop layout(s)")
    }

    /// Debounced save of all known layouts (live + not-yet-restored).
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()   // disarm any pending debounced save so it can't overwrite this
        var out: [String: SavedSpace] = [:]
        for (id, st) in spaces {
            guard let root = st.root else { continue }
            let scr = screen(forDisplayID: st.displayID)
            out[String(id)] = SavedSpace(displayID: st.displayID,
                                         mode: modeName(st.mode),
                                         tree: serialize(root),
                                         displayUUID: scr.flatMap(displayUUID(of:)) ?? displayUUID(forID: st.displayID),
                                         spaceOrdinal: scr.flatMap { spaceOrdinal(of: id, on: $0) })
        }
        // Keep layouts for desktops we haven't visited/restored yet.
        for (id, saved) in savedState where spaces[id] == nil {
            out[String(id)] = saved
        }
        let assigns = Dictionary(uniqueKeysWithValues: assignments.map { (String($0.key), $0.value) })
        let assignApps = Dictionary(uniqueKeysWithValues: assignmentApps.map { (String($0.key), $0.value) })
        let state = SavedState(spaces: out, assignments: assigns,
                               assignmentApps: assignApps, scratchpadBundle: scratchpadBundleID)
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

    private func serialize(_ node: Container) -> SavedNode {
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

    /// Rebuild a saved desktop by matching its windows to currently-open ones.
    private func restoreSaved(_ id: UInt64, on screen: NSScreen) -> Bool {
        guard let (savedKey, saved) = savedLayout(forSpace: id, on: screen),
              let savedTree = saved.tree else { return false }
        var pool = captureWindows(on: screen)
        guard !pool.isEmpty else { return false }

        guard let root = rebuild(savedTree, pool: &pool) else { return false }

        let st = SpaceState(displayID: displayID(of: screen))   // current display, not the stale saved id
        st.mode = mode(named: saved.mode)
        st.root = root
        spaces[id] = st
        activeSpaceID = id
        focused = root.firstLeaf()

        // Consume the match AND any stale duplicates for the same monitor+desktop (prior
        // sessions leave one entry per boot) so they can't be re-applied to other Spaces.
        if savedKey != id { savedState[savedKey] = nil }
        if let uuid = saved.displayUUID {
            for (k, v) in savedState where k != id && v.displayUUID == uuid && v.spaceOrdinal == saved.spaceOrdinal {
                savedState[k] = nil
            }
        }

        // Windows opened since the layout was saved → append them.
        for window in pool { insert(window) }

        if let r = self.root { wireTabCallbacks(r) }
        observer.watchForClose(captureWindows(on: screen))
        render()
        NSLog("Mosaic: restored desktop \(id) (from saved \(savedKey))")
        return true
    }

    /// Find a saved layout for this Space: exact macOS-Space-id match (same session),
    /// else by stable monitor fingerprint + desktop ordinal — so a location's layout is
    /// restored even though its Space ids/display ids differ (dock/undock, reboot).
    private func savedLayout(forSpace id: UInt64, on screen: NSScreen) -> (UInt64, SavedSpace)? {
        if let exact = savedState[id] { return (id, exact) }
        guard let uuid = displayUUID(of: screen) else { return nil }
        let candidates = savedState.filter { $0.value.displayUUID == uuid }
        guard !candidates.isEmpty else { return nil }
        // Require a desktop-ordinal match. (Dropping the old "single candidate → use it
        // anyway" guess: it stole another desktop's layout onto a fresh empty desktop.)
        guard let ordinal = spaceOrdinal(of: id, on: screen),
              let m = candidates.first(where: { $0.value.spaceOrdinal == ordinal }) else { return nil }
        return (m.key, m.value)
    }

    private func rebuild(_ saved: SavedNode, pool: inout [ManagedWindow]) -> Container? {
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
    private func takeMatch(_ sw: SavedWindow, from pool: inout [ManagedWindow]) -> ManagedWindow? {
        if let wid = sw.windowID,
           let i = pool.firstIndex(where: { AX.windowID($0.element) == wid }) {
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

    private func modeName(_ m: Mode) -> String {
        switch m { case .columns: return "columns"; case .grouped: return "grouped"; case .tabbed: return "tabbed" }
    }
    private func mode(named s: String) -> Mode {
        switch s.lowercased() { case "grouped": return .grouped; case "tabbed": return .tabbed; default: return .columns }
    }
    private func layoutName(_ l: Container.Layout) -> String {
        switch l { case .splitH: return "splitH"; case .splitV: return "splitV"; case .tabbed: return "tabbed" }
    }
    private func layout(named s: String?) -> Container.Layout {
        switch s?.lowercased() { case "splitv": return .splitV; case "tabbed": return .tabbed; default: return .splitH }
    }

    // MARK: - Helpers

    private func captureWindows(on screen: NSScreen) -> [ManagedWindow] {
        let __perf = DispatchTime.now(); defer { Perf.record("captureWindows", since: __perf) }
        let onScreen = AX.onScreenWindowIDs()
        return AX.managedWindows()
            .compactMap(ManagedWindow.init)
            .filter { window in
                guard !isFloating(window), !window.isFullscreen else { return false }
                guard let wid = AX.windowID(window.element), onScreen.contains(wid) else { return false }
                if window.app.bundleIdentifier == scratchpadBundleID { return false }   // scratchpad app floats
                guard let axFrame = window.frame else { return false }
                let cocoaFrame = Geometry.flip(axFrame)
                return screen.frame.contains(CGPoint(x: cocoaFrame.midX, y: cocoaFrame.midY))
            }
    }

    private func isFloating(_ window: ManagedWindow) -> Bool {
        if floatingApps.contains(window.appName.lowercased()) { return true }
        if let bundle = window.app.bundleIdentifier?.lowercased(), floatingApps.contains(bundle) { return true }
        if ruleFor(window)?.float == true { return true }
        return false
    }

    private func clamp(_ v: CGFloat) -> CGFloat { min(0.9, max(0.1, v)) }

    /// The tiling area of a screen = its visible frame minus the configured outer gap,
    /// minus a top strip reserved for an external bar (e.g. sketchybar).
    ///
    /// `externalBarTop` is the bar's height. We only reserve what macOS doesn't already
    /// reserve at the top (menu bar / notch safe-area), so a notched built-in display —
    /// which already keeps 32px clear — gets little or no extra strip, while external
    /// monitors that reserve nothing get the full bar height. This keeps the gap uniform
    /// across a mixed multi-monitor setup instead of double-counting the notch.
    private func layoutRect(_ screen: NSScreen) -> NSRect {
        var r = screen.visibleFrame.insetBy(dx: Config.shared.outerGap, dy: Config.shared.outerGap)
        let bar = Config.shared.externalBarTop
        if bar > 0 {
            let alreadyReserved = screen.frame.maxY - screen.visibleFrame.maxY  // menu bar / notch
            let extra = max(0, bar - alreadyReserved)
            r.size.height -= extra   // Cocoa origin is bottom-left → shrinking height frees the TOP
        }
        return r
    }

    private func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

import AppKit

enum Direction {
    case left, right, up, down
    var isHorizontal: Bool { self == .left || self == .right }
    var isForward: Bool { self == .right || self == .down }
}

/// Owns one persistent i3-style layout tree **per emulated workspace** (v2). There is a
/// SINGLE macOS Space; a "workspace" is a purely logical set of windows. Switching a
/// workspace parks the outgoing one's windows off-screen and places the incoming one — the
/// tiling engine (`Container`) is unchanged. This kills, by construction, the whole class of
/// real-Spaces bugs (drift on wake/dock, animated switch, Space-id instability) and drops the
/// private CGS Spaces dependency for the desktop layer. See docs/V2-EMULATED-WORKSPACES.md.
///
/// A workspace is keyed by a synthetic id = `UInt64(workspaceNumber)`, so the numbered
/// workspaces (⌘⌥1-9) map directly to `spaces[UInt64(n)]` with no assignment indirection.
final class WindowManager {
    enum Mode: CaseIterable { case columns, grouped, tabbed }

    /// The layout state for one workspace, including which monitor it is currently placed on.
    /// `displayID` is where the workspace is shown right now (it can move between monitors on
    /// dock/undock or an explicit send) — 0 while the workspace exists but is parked nowhere.
    private final class SpaceState {
        var displayID: CGDirectDisplayID
        var root: Container?
        weak var focused: Container?
        var mode: Mode = .columns
        var isZoomed = false   // focused tile fills the screen (monocle), follows focus
        init(displayID: CGDirectDisplayID) { self.displayID = displayID }
    }

    /// All workspaces, keyed by synthetic id (= workspace number). Persisted.
    private var spaces: [UInt64: SpaceState] = [:]
    /// The workspace currently shown on the monitor under the mouse (the "active" one that
    /// keyboard ops target). Set by us on switch / monitor cross — never read from CGS.
    private var activeSpaceID: UInt64?
    /// Which workspace (synthetic id) is currently placed on each physical monitor. This is
    /// the emulated-workspace equivalent of "the current Space of each display": we own it
    /// outright instead of asking the window server. Absent = that monitor shows no workspace.
    private var shownOnDisplay: [CGDirectDisplayID: UInt64] = [:]
    private(set) var manageAll = false

    /// Workspaces with unseen activity while PARKED (a parked window's title changed — a chat's
    /// unread counter, a build finishing…). Published in status.json so an external bar can badge
    /// the pill. Cleared when the user actually visits the workspace. Only the emulated model makes
    /// this possible: parked windows still live on the one Space, so their AX titles stay readable.
    private var attentionWorkspaces: Set<Int> = []
    /// Last title we saw per managed window — the baseline `scanAttention` diffs against. Keyed by
    /// window identity (a stable class ref while it's managed).
    private var titleSnapshot: [ObjectIdentifier: String] = [:]

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
    private var mouseMoveMonitor: Any?
    private var lastMouseDisplayID: CGDirectDisplayID = 0
    private var handles: [ResizeHandle] = []
    /// Discovered minimum size (points) per child container, so resize clamps up front
    /// instead of overshooting and snapping back every drag event.
    private var resizeMinCache: [ObjectIdentifier: CGFloat] = [:]

    /// Persisted layouts for desktops not yet restored this session.
    private var savedState: [UInt64: SavedSpace] = [:]
    private var saveWork: DispatchWorkItem?
    /// Which workspace number was shown on each monitor (left→right order) last session, so a
    /// restart restores the exact view instead of guessing the first non-empty one.
    private var savedShownByMonitor: [Int] = []

    /// Launch-time routing hints: for a short window after startup, a newly-appearing window
    /// whose app matches a saved layout is sent to the workspace it was saved in, not the active
    /// one — so apps that relaunch AFTER Mosaic (a full reboot) still land on the right workspace
    /// instead of piling onto whatever's focused. Keyed by "bundleID\u{1}title" (strong) and
    /// "bundleID" (fallback). Cleared a few seconds after launch. See `restoreSavedWorkspaces`.
    private var restoreHints: [String: Int] = [:]

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

    // MARK: - Emulated workspaces (v2 — replaces the CGS Space layer)

    /// The synthetic id of the workspace currently placed on `screen`. This is the emulated
    /// stand-in for `currentWorkspace(for:)`: it reads OUR own placement map, never the
    /// window server, so a workspace only "changes" on a screen when we park/unpark it.
    private func currentWorkspace(for screen: NSScreen) -> UInt64? {
        shownOnDisplay[displayID(of: screen)]
    }

    // MARK: Workspace ↔ monitor assignment (model A: global 1-9, each pinned to a monitor)

    /// Present monitors ordered left→right by frame x. The basis for the workspace→monitor
    /// partition, so the assignment is deterministic and recomputes on dock/undock.
    private func orderedDisplays() -> [CGDirectDisplayID] {
        NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }.map(displayID(of:))
    }

    /// The monitor workspace `n` (1-9) is pinned to, among the CURRENTLY PRESENT monitors.
    /// Default: the nine workspaces split into contiguous blocks left→right, as even as
    /// possible (3 monitors → 1-3 | 4-6 | 7-9; 2 monitors → 1-5 | 6-9; 1 monitor → all). A
    /// config override (`workspaceMonitors: {"5": 2}`) pins a workspace to a monitor index
    /// (1-based, left→right). Because it's computed from present monitors, unplugging a display
    /// re-partitions the numbers over what's left — the emulated answer to home↔office.
    private func assignedDisplay(forWorkspace n: Int) -> CGDirectDisplayID? {
        let displays = orderedDisplays()
        guard !displays.isEmpty, n >= 1, n <= 9 else { return displays.first }
        if let idx = Config.shared.workspaceMonitors[n], idx >= 1, idx <= displays.count {
            return displays[idx - 1]
        }
        return displays[WindowManager.monitorBlock(forWorkspace: n, monitorCount: displays.count)]
    }

    /// Pure: which 0-based monitor (left→right) workspace `n` (1-9) falls into when the nine
    /// workspaces are split into `monitorCount` contiguous, as-even-as-possible blocks — the
    /// first `9 % monitorCount` monitors get one extra. (1 mon → all 0; 3 → 1-3|4-6|7-9; 2 →
    /// 1-5|6-9.) Clamped to a valid index. Unit-tested.
    static func monitorBlock(forWorkspace n: Int, monitorCount: Int) -> Int {
        guard monitorCount > 1 else { return 0 }
        let per = 9 / monitorCount, remainder = 9 % monitorCount
        var start = 1
        for i in 0..<monitorCount {
            let size = per + (i < remainder ? 1 : 0)
            if n >= start && n < start + size { return i }
            start += size
        }
        return monitorCount - 1
    }

    /// The screen workspace `n` is pinned to (its home monitor), if present.
    private func homeScreen(forWorkspace n: Int) -> NSScreen? {
        assignedDisplay(forWorkspace: n).flatMap(screen(forDisplayID:))
    }

    /// The default workspace to show when a monitor is first visited: the lowest-numbered
    /// workspace pinned to it (left monitor → 1, middle → 4, right → 7 on a triple-screen).
    private func defaultWorkspaceNumber(for screen: NSScreen) -> Int {
        let did = displayID(of: screen)
        return (1...9).first { assignedDisplay(forWorkspace: $0) == did } ?? 1
    }

    /// Cocoa rect a parked workspace is laid out in — the screen's ON-SCREEN tiling rect pushed off
    /// its OWN home monitor's void-facing edge (see `Geometry.parkRect`). Using `layoutRect(screen)`
    /// (the exact rect unpark restores) makes park a pure translation on that monitor: no cross-
    /// resolution clamp, so windows never come back resized, and the strip stays on the home screen.
    private func parkRect(for screen: NSScreen) -> NSRect {
        let desktop = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return Geometry.parkRect(layoutRect: layoutRect(screen),
                                 screenFrame: screen.frame,
                                 desktop: desktop.isNull ? screen.frame : desktop)
    }

    /// Park a workspace: lay its tree off its OWN home monitor's void-facing edge. macOS keeps a
    /// ~40px strip on screen (it won't fully off-screen a window) and cross-app CGS alpha is blocked
    /// on recent macOS, so neither position nor transparency can hide that strip. Keeping the push
    /// on the home monitor means (a) no cross-resolution clamp, so windows never come back resized,
    /// and (b) the strip stays on that monitor's outer edge, mostly behind the SHOWN tiling (see
    /// `coverParkedSlivers`) — animation-free. (Set `externalBarTop:0` and a small `outerGap` so the
    /// shown tiling reaches the screen edge and covers as much of the strip as possible.)
    private func parkWorkspace(_ ws: SpaceState) {
        guard let r = ws.root else { return }
        guard let screen = screen(forDisplayID: ws.displayID) ?? screenUnderMouse() ?? NSScreen.screens.first
        else { return }
        r.arrange(in: parkRect(for: screen))
    }

    /// Unpark a workspace onto `screen`: un-minimize (in case a window was minimized — by the
    /// user, or a previous build), lay the tree on-screen, and lift its windows and strips above
    /// unmanaged windows. `setCocoaFrame`'s cache skips windows already at their on-screen frame.
    private func unparkWorkspace(_ ws: SpaceState, on screen: NSScreen) {
        guard let r = ws.root else { return }
        r.forEachLeaf { if let w = $0.window, AX.isMinimized(w.element) { AX.setMinimized(w.element, false) } }
        r.arrange(in: layoutRect(screen))
        r.raiseVisibleWindows()
        r.raiseVisibleStrips()
    }

    /// Raise every SHOWN workspace's windows so they sit above the parked workspaces' off-screen
    /// slivers (macOS keeps ~40px of a parked window on the nearest monitor edge; we can't hide it
    /// with alpha on recent macOS, so we cover it with the visible tiling instead). Called after
    /// any park so a just-parked window can't stay on top of the tiles that should hide it.
    private func coverParkedSlivers() {
        for (id, ws) in spaces where screen(forWorkspace: id) != nil {
            ws.root?.raiseVisibleWindows()
        }
    }

    /// Lift every app in the just-shown workspace above the app-layer of whatever we parked, then
    /// re-assert the focused window on top. macOS stacks windows by APP, and `AX.raise` only
    /// reorders within an app — so a non-focused tile of another app can stay UNDER a parked
    /// window whose app was frontmost (the "adjacent app peeks over my non-focused tile" bug).
    /// Activating an app is the only thing that reliably reorders app layers; we activate each
    /// OTHER app, then the focused one last so it ends frontmost. No-op on a single-app workspace
    /// (focusing it already covers everything) so we don't churn activations for nothing.
    private func liftAppsAboveParked(_ ws: SpaceState) {
        guard let r = ws.root, let focusedWin = (ws.focused ?? r.firstLeaf()).window else { return }
        let focusedPid = focusedWin.app.processIdentifier
        // Apps that ALSO own a window on a parked workspace: activating them raises that parked
        // window too (activation is app-wide) — back above the tiling meant to hide it. Skip them
        // and accept the rarer peek for those, rather than resurfacing a sliver.
        var parkedPids = Set<pid_t>()
        for (id, other) in spaces where screen(forWorkspace: id) == nil {
            other.root?.forEachLeaf { if let w = $0.window { parkedPids.insert(w.app.processIdentifier) } }
        }
        var seen = Set<pid_t>()
        var others: [NSRunningApplication] = []
        r.forEachVisibleLeaf { leaf in
            guard let w = leaf.window, !w.isFullscreen else { return }   // activating a FS app can yank Spaces
            let pid = w.app.processIdentifier
            guard pid != focusedPid, !parkedPids.contains(pid) else { return }
            if seen.insert(pid).inserted { others.append(w.app) }
        }
        guard !others.isEmpty else { return }          // nothing safe to lift → focusing alone covers it
        for app in others { app.activate() }           // each other app's layer above the parked one
        AX.makeMain(focusedWin.element); focusedWin.activateApp(); AX.raise(focusedWin.element)
    }

    /// Fetch (or create) the workspace numbered `n`, ensuring it's marked as placed on `screen`.
    @discardableResult
    private func workspace(_ n: Int, on screen: NSScreen) -> SpaceState {
        let key = UInt64(n)
        let ws = spaces[key] ?? {
            let s = SpaceState(displayID: displayID(of: screen))
            s.mode = defaultMode
            spaces[key] = s
            return s
        }()
        ws.displayID = displayID(of: screen)
        return ws
    }

    private func screen(forDisplayID id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
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
        resetAllOpacity()          // clear previous dimming (incl. parked windows at alpha 0)
        render()                   // re-arrange the active workspace with new gap / bar / opacity
        reassertAllWorkspaces()    // re-hide parked workspaces (alpha 0) that reset made opaque
        // Workspace names may have changed → republish status.json and fire the hook so
        // the external bar picks up new labels immediately (even if the number is unchanged).
        let num = screenUnderMouse().flatMap { currentWorkspace(for: $0) }.flatMap { workspaceNumber(for: $0) }
        writeStatusFile(focused: num)
        runWorkspaceHook(num)
    }

    func startObserving() {
        loadState()
        restoreSavedWorkspaces()   // eager, BEFORE the timer can lazily restore just one
        // Stop routing late-launching apps to their saved workspace after a grace window, so
        // windows opened deliberately later go to the active workspace as normal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.restoreHints.removeAll() }
        observer.onTitleChange = { [weak self] in self?.refreshVisibleTitles(); self?.scanAttention() }
        observer.onFocusChange = { [weak self] in self?.syncFocusToSystem() }
        observer.start()
        // Poll which monitor the mouse is on so the active workspace follows it (the emulated
        // model has no macOS Space change to hook). .common mode (via explicit Timer +
        // RunLoop.add, not scheduledTimer which is .default only) so the poll keeps firing while
        // a status-bar menu or modal holds a nested run loop.
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkSpaceChange()
            self?.sweepOrphanStrips()   // catch stray tab bars even without a render
            self?.purgeVisibleGhosts()  // clean dead tiles on visible, non-active monitors
            Perf.dumpIfDue()            // opt-in timing summary (no-op unless enabled)
        }
        RunLoop.main.add(timer, forMode: .common)
        spaceTimer = timer
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
        // Snappy monitor-follow: react the instant the cursor crosses to another display instead of
        // waiting up to 0.4s for the poll. The handler is trivial — a display-id compare — and only
        // calls checkSpaceChange when the display ACTUALLY changes, so a firehose mouse-moved
        // monitor stays cheap. The poll above remains the safety net if this doesn't fire in some
        // context (e.g. over a window that swallows moved events).
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            guard let self, !self.suspended, !self.tabDragging, let scr = self.screenUnderMouse() else { return }
            let did = self.displayID(of: scr)
            guard did != self.lastMouseDisplayID else { return }
            self.lastMouseDisplayID = did
            self.checkSpaceChange()
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
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleDisplayChange() }
    }

    /// Dock/undock (home ↔ office) fires a burst of screen-parameter changes while macOS
    /// adds/removes displays and scatters windows. Freeze until the display set has been STABLE
    /// for a moment, then re-home workspaces onto present monitors and re-assert every
    /// placement. In the emulated model there are no real Spaces to drift between, so this is
    /// just geometry — no CGS moves, no per-window rehome heuristics.
    private func handleDisplayChange() {
        suspended = true
        displayChangeWork?.cancel()
        let before = Set(NSScreen.screens.map(displayID(of:)))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = Set(NSScreen.screens.map(self.displayID(of:)))
            guard now == before else { self.handleDisplayChange(); return }   // still settling
            self.suspended = false
            self.rehomeToPresentMonitors()
            self.activeSpaceID = nil
            self.checkSpaceChange()
            self.reassertAllWorkspaces()
        }
        displayChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// After wake, macOS scatters windows and hides our borderless overlays. Wait for it to
    /// settle, then re-assert every workspace's placement (parked off-screen or tiled on its
    /// monitor) — which also brings the tab bars back. No CGS, no drift heuristics.
    private func handleWake() {
        suspended = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.suspended = false
            self.activeSpaceID = nil   // force a fresh detect of the current workspace
            self.checkSpaceChange()
            self.reassertAllWorkspaces()
            // A slow wake can re-hide the overlays after we refresh; do it once more.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.reassertAllWorkspaces()
            }
        }
    }

    /// Drop placements that point at a monitor that's no longer attached, so a workspace homed
    /// on a removed display can be re-shown on a present one at its next visit (its windows
    /// were migrated by macOS anyway). Keeps `shownOnDisplay` consistent with reality.
    private func rehomeToPresentMonitors() {
        let present = Set(NSScreen.screens.map(displayID(of:)))
        for (did, _) in shownOnDisplay where !present.contains(did) { shownOnDisplay[did] = nil }
        for (_, ws) in spaces where ws.displayID != 0 && !present.contains(ws.displayID) {
            ws.displayID = 0   // parked, no home monitor until re-shown
        }
    }

    /// Re-assert every workspace's placement: tile the ones shown on a present monitor, park
    /// the rest off-screen. The single source of truth for "where every window should be" —
    /// the emulated-model replacement for the whole drift/rehome/refresh machinery.
    private func reassertAllWorkspaces() {
        for (id, ws) in spaces {
            if let scr = screen(forWorkspace: id) {
                unparkWorkspace(ws, on: scr)   // on-screen + raised
            } else {
                parkWorkspace(ws)              // off-screen
            }
        }
        coverParkedSlivers()   // shown tiling back on top of any parked sliver
        sweepOrphanStrips()
    }

    /// Bring EVERY workspace's windows back on-screen (on its home monitor) and fully opaque —
    /// called on quit so no parked window is left stranded off the visible desktop. Workspaces
    /// sharing a monitor overlap, but everything is reachable and visible again.
    func unparkAll() {
        for (id, ws) in spaces {
            guard let r = ws.root,
                  let scr = screen(forWorkspace: id) ?? homeScreen(forWorkspace: Int(id))
                            ?? screenUnderMouse() ?? NSScreen.main else { continue }
            r.forEachLeaf { if let w = $0.window { AX.setMinimized(w.element, false) } }
            r.arrange(in: layoutRect(scr))
            r.raiseVisibleWindows()
        }
    }

    private func focusWindowUnderMouse() {
        checkSpaceChange()
        guard let root else { return }
        // Monocle/zoom: the focused window fills the screen while the tree still holds the
        // other tiles' un-zoomed frames. A click anywhere lands on the zoomed window, so don't
        // let tree geometry re-home focus onto a tile hidden underneath — the next render would
        // then zoom THAT one to the front (the "click right → focus jumps to the app behind" bug).
        if active?.isZoomed == true { return }
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

    /// Follow the monitor the mouse is on and make its shown workspace the active one. In the
    /// emulated model crossing monitors moves NO windows (each monitor already shows its own
    /// workspace) — it just retargets keyboard ops and the focus border. A monitor visited for
    /// the first time is bootstrapped with its default workspace. Cheap when nothing changed.
    private func checkSpaceChange() {
        guard !suspended, !tabDragging else { return }
        guard let screen = screenUnderMouse() else { return }
        let did = displayID(of: screen)
        let id = shownOnDisplay[did] ?? {
            let n = UInt64(defaultWorkspaceNumber(for: screen))   // first visit → place its default workspace
            shownOnDisplay[did] = n
            return n
        }()
        guard id != activeSpaceID else { return }
        NSLog("Mosaic: active workspace \(activeSpaceID.map(String.init) ?? "nil") → \(id)")
        focusIndicator.hide()       // drop the focus rectangle immediately
        scratchpadVisible = false   // leaving its workspace hides the floating scratchpad
        activeSpaceID = id
        if spaces[id] != nil {
            reconcile()             // absorb any window changes; windows/strips already on-screen
            updateFocusIndicator()
        } else if restoreSaved(id, on: screen) {
            // restored a persisted layout for this workspace
        } else if manageAll {
            workspace(Int(id), on: screen)
            build()
        }
        layoutResizeHandles()   // reposition handles for the now-active workspace
        showWorkspaceIndicator(for: screen)
        focusIndicator.pulse()
    }

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
        reassertAllWorkspaces()
        updateFocusIndicator()
        NSLog("Mosaic: recover — un-minimized stuck windows + re-asserted all workspaces")
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

    private func tick() {
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
    private func enforceEmulatedFullscreen() {
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

    /// Windows we've already applied an on-open `fullscreen` rule to, so we set the state
    /// once and then leave the user free to toggle it. Pruned to living windows each pass.
    private var fullscreenApplied = Set<CGWindowID>()

    /// Enforce per-app `fullscreen` rules. Some apps (e.g. Ferdium) restore themselves into
    /// native macOS full screen, where they live on their own Space and can't be tiled. A
    /// rule `{"app":"ferdium","fullscreen":false}` forces such a window back to windowed so
    /// the next reconcile can manage it; `true` forces it into full screen.
    ///
    /// `fullscreenLock: true` keeps enforcing the state every tick (a hard lock). Otherwise
    /// the state is applied ONCE when a window first appears, then left alone — so the user
    /// can freely toggle full screen afterwards. No-op — and zero cost — unless at least one
    /// fullscreen rule exists.
    private func enforceFullscreenRules() {
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

    /// Guarantee each window lives in exactly one Space's tree. A cross-Space tab drag, or a
    /// window that drifted to another display, can leave a stale duplicate leaf → the same
    /// window then shows in two tab bars. Keep the copy on the display the window is on.
    private func dedupTrees() {
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
    private func removeLeaf(_ leaf: Container, from state: SpaceState) {
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
    private func reconcile() {
        guard !suspended, !isReconciling, let root, let screen = activeScreen else { return }
        isReconciling = true
        let __perf = DispatchTime.now(); defer { Perf.record("reconcile", since: __perf) }
        defer { isReconciling = false }
        let onScreen = AX.onScreenWindowIDs()
        dedupTrees()

        var aliveTreeIDs = Set<CGWindowID>()
        var deadLeaves: [Container] = []
        var staleLeaves: [Container] = []   // has a window, but AX couldn't resolve its id now
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
            // AX couldn't resolve the window. It might be a transient glitch, a real close,
            // or an app swapping this window for a new one (IINA replaces its launcher window
            // with the video window). Defer the verdict until we've captured the current
            // windows: a same-app newcomer can then be adopted into this exact slot, and only
            // a leaf with no replacement is aged out. Meanwhile keep the slot alive.
            if let cached = w.lastKnownID, onScreen.contains(cached) {
                w.missCount = 0
                aliveTreeIDs.insert(cached)
            } else {
                staleLeaves.append(leaf)
                if let cached = w.lastKnownID { aliveTreeIDs.insert(cached) }   // keep during grace
            }
        }

        // None of our windows visible → we've switched desktops; leave it untouched.
        // (Per-leaf glitch/close handling above already keeps transiently-invalid windows,
        // so an empty aliveTreeIDs here means a real switch or a real empty desktop.)
        if !aliveTreeIDs.isEmpty && aliveTreeIDs.isDisjoint(with: onScreen) { return }

        // Fast path: nothing closed or vanishing, and the on-screen window set is unchanged
        // since the last full reconcile → nothing could have been added or removed. Skip the
        // expensive enumeration (captureWindows) — this keeps a pure focus / app switch cheap
        // instead of paying ~30ms of AX every time.
        if deadLeaves.isEmpty, staleLeaves.isEmpty, onScreen == lastReconcileOnScreen { return }
        lastReconcileOnScreen = onScreen

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
        for leaf in staleLeaves {
            guard let deadPid = leaf.window?.pid,
                  let idx = additions.firstIndex(where: { $0.pid == deadPid }) else { continue }
            let replacement = additions.remove(at: idx)
            _ = replacement.resolvedID()   // cache the id so the next pass sees it as alive
            if let old = leaf.window { observer.unwatch([old]) }   // the vanished window's AX regs
            leaf.window = replacement      // render() below repaints its tab/stack label
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

        guard !deadLeaves.isEmpty || !additions.isEmpty else { return }

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

    private func detach(_ leaf: Container) {
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
              let dropSpaceID = currentWorkspace(for: dropScreen),
              let targetState = spaces[dropSpaceID],
              let targetRoot = targetState.root,
              let targetLeaf = visibleLeaf(at: point, in: targetRoot),
              targetLeaf !== dragged, !contains(dragged, targetLeaf),
              let sourceState = stateContaining(dragged) else { return }

        // Detach from the source tree and collapse what it leaves behind.
        if let parent = dragged.parent, let i = parent.index(of: dragged) {
            parent.removeChild(at: i)   // adjusts `selected` for the lower-index shift too
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

    /// Highlight the window/group under the cursor during a tab drag.
    private func updateDropHighlight(at point: NSPoint) {
        guard Config.shared.dropHighlightEnabled,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let spaceID = currentWorkspace(for: screen),
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
                gp.removeChild(at: idx)   // adjusts `selected` for the lower-index shift too
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
    private func refreshVisibleTitles() {
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
    private func scanAttention() {
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
    private func clearAttention(_ n: Int) {
        if attentionWorkspaces.remove(n) != nil { publishAttention() }
    }

    /// Re-publish status.json and poke the external bar after the attention set changed.
    private func publishAttention() {
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
    private func purgeVisibleGhosts() {
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
        tst.root?.forEachLeaf { $0.window?.raiseWindowOnly() }

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

    // MARK: - i3-style numbered workspaces (v2: emulated — park/unpark, no CGS)

    /// Switch to workspace `n` (1-9) on ITS pinned monitor (model A): each workspace has a home
    /// monitor, so ⌘⌥5 goes to whichever monitor workspace 5 belongs to, parks whatever that
    /// monitor shows now, and places workspace 5 there (empty on first use, or restored from
    /// disk) — then moves focus/cursor onto that monitor. No macOS Space transition, just two
    /// off-screen ↔ on-screen `arrange` passes.
    func switchToWorkspace(_ n: Int) {
        guard let screen = homeScreen(forWorkspace: n) ?? screenUnderMouse() else { return }
        let did = displayID(of: screen)
        let target = UInt64(n)
        guard shownOnDisplay[did] != target else {   // already shown on its monitor → just retarget
            activeSpaceID = target
            warpMouseToWorkspace(target, on: screen)
            updateFocusIndicator()
            return
        }

        // Park the outgoing workspace on the target monitor, then put every still-shown
        // workspace's tiling back on top of the parked slivers (incoming is raised last, below).
        focusIndicator.hide()
        if let outgoing = shownOnDisplay[did], let ws = spaces[outgoing] { parkWorkspace(ws) }
        coverParkedSlivers()
        scratchpadVisible = false

        // Place workspace n on its monitor: restore from disk on first load, else unpark.
        shownOnDisplay[did] = target
        activeSpaceID = target
        clearAttention(n)   // visiting it dismisses its badge
        if spaces[target] == nil, restoreSaved(target, on: screen) {
            // restoreSaved built the tree, set focus, and rendered it on-screen
        } else {
            let ws = workspace(n, on: screen)
            unparkWorkspace(ws, on: screen)
            if ws.focused == nil { ws.focused = ws.root?.firstLeaf() }
            render()
        }
        if let ws = spaces[target] { liftAppsAboveParked(ws) }   // multi-app: beat macOS' app-layer order
        layoutResizeHandles()
        showWorkspaceIndicator(for: screen)
        warpMouseToWorkspace(target, on: screen)
        focusIndicator.pulse()
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
    func showExpose(commitOnCmdRelease: Bool = false) {
        guard let screen = screenUnderMouse() else { return }
        let current = currentWorkspace(for: screen).flatMap { workspaceNumber(for: $0) }
        let ordered = spaces.keys.compactMap { workspaceNumber(for: $0) }.sorted()
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
                        tiles.append(ExposeTile(frame: wsScreen, tabs: [ExposeTab(label: "⛶ \(w.title)", icon: w.app.icon, selected: true)]))
                    } else if let f = frames[ObjectIdentifier(tile)] {
                        tiles.append(ExposeTile(frame: f, tabs: [ExposeTab(label: w.title, icon: w.app.icon, selected: true)]))
                    }
                } else {
                    // Tabbed container → one tile with a tab per child (rep = child's first window).
                    let sel = min(max(tile.selected, 0), tile.children.count - 1)
                    guard tile.children.indices.contains(sel),
                          let f = frames[ObjectIdentifier(tile)] else { return }
                    let tabs = tile.children.enumerated().map { i, c -> ExposeTab in
                        let w = c.firstLeaf().window
                        return ExposeTab(label: w?.title ?? "—", icon: w?.app.icon, selected: i == sel)
                    }
                    tiles.append(ExposeTile(frame: f, tabs: tabs))
                }
            }
            wss.append(ExposeWorkspace(
                title: Config.shared.workspaceNames[n] ?? "Workspace \(n)",
                screen: wsScreen, tiles: tiles, current: n == current,
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
            // Reading order within the screen: top→bottom, then left→right, so labels flow spatially
            // from the top-left instead of following the tree's traversal order.
            perScreen.sort {
                abs($0.frameCocoa.maxY - $1.frameCocoa.maxY) > 1
                    ? $0.frameCocoa.maxY > $1.frameCocoa.maxY
                    : $0.frameCocoa.minX < $1.frameCocoa.minX
            }
            targets.append(contentsOf: perScreen)
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

    /// Bring a specific window forward: switch its workspace onto this monitor if it isn't
    /// already shown, then activate it. The focus-sync observer adopts it into Mosaic's focus.
    private func focusWindow(_ w: ManagedWindow, inWorkspace n: Int) {
        if let screen = screenUnderMouse(), currentWorkspace(for: screen) != UInt64(n) {
            switchToWorkspace(n)
        }
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

    private func moveFocused(toWorkspace n: Int) {
        let target = UInt64(n)
        guard let leaf = focused, leaf.window != nil, target != activeSpaceID else { return }
        detach(leaf)
        leaf.parent = nil

        let tst = workspaceOffscreen(n)   // fetch/create; don't change where it's placed
        appendLeaf(leaf, to: tst)
        if let r = tst.root { wireTabCallbacks(r) }
        if let scr = screen(forWorkspace: target) {   // shown somewhere → tile it there
            tst.root?.arrange(in: layoutRect(scr))
            tst.root?.forEachLeaf { $0.window?.raiseWindowOnly() }
        } else {
            parkWorkspace(tst)   // parked destination → the moved window follows off-screen
        }

        if focused == nil || !treeContainsLeaf(focused!) { focused = root?.firstLeaf() }
        render()
        saveNow()
    }

    /// The screen a workspace is currently placed on (nil if parked / not shown anywhere).
    private func screen(forWorkspace space: UInt64) -> NSScreen? {
        guard let ws = spaces[space], ws.displayID != 0,
              shownOnDisplay[ws.displayID] == space else { return nil }
        return screen(forDisplayID: ws.displayID)
    }

    /// Fetch/create a workspace WITHOUT changing which monitor it's placed on — for the parked
    /// destination of a move. A new one is homed on the current monitor so it can be parked
    /// off-screen relative to a real display (a displayID-0 workspace can't be parked).
    @discardableResult
    private func workspaceOffscreen(_ n: Int) -> SpaceState {
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
    private func placeOnWorkspace(_ window: ManagedWindow, n: Int) {
        let target = UInt64(n)
        let tst = workspaceOffscreen(n)
        appendLeaf(Container(window: window), to: tst)
        if let r = tst.root { wireTabCallbacks(r) }
        if let scr = screen(forWorkspace: target) {
            tst.root?.arrange(in: layoutRect(scr))
            tst.root?.forEachLeaf { $0.window?.raiseWindowOnly() }
        } else {
            parkWorkspace(tst)
        }
        NSLog("Mosaic: rule placed \(window.appName) on workspace \(n)")
        scheduleSave()
    }

    /// Optionally move the cursor onto the just-switched workspace so the mouse-follows model
    /// stays aligned. `screen` is the monitor the workspace was placed on.
    private func warpMouseToWorkspace(_ space: UInt64, on screen: NSScreen) {
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
    private func workspaceNumber(for space: UInt64) -> Int? {
        guard space >= 1, space <= 9, spaces[space] != nil else { return nil }
        return Int(space)
    }

    /// No-op in the emulated model: workspace numbers are intrinsic, nothing to prune.
    private func pruneStaleAssignments() {}

    private func showWorkspaceIndicator(for screen: NSScreen) {
        guard let space = currentWorkspace(for: screen) else { return }
        let number = workspaceNumber(for: space)
        emitWorkspaceState(number)   // menu-bar icon + status file + shell hook (sketchybar…)
        // HUD: the row of THIS monitor's workspaces, so the switch also shows which of the
        // others hold windows (a dot) — the at-a-glance answer to "where did my window go?".
        guard let current = number, Config.shared.showWorkspaceHUD else { return }
        let did = displayID(of: screen)
        let items: [WorkspaceHUDItem] = (1...9)
            .filter { assignedDisplay(forWorkspace: $0) == did }
            .map { n in WorkspaceHUDItem(number: n, name: Config.shared.workspaceNames[n],
                                         occupied: spaces[UInt64(n)]?.root != nil, current: n == current) }
        workspaceHUD.show(items, on: screen, position: Config.shared.hudPosition)
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
    private func applyOpacity() {
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
    private func updateFocusIndicator(onScreen: Set<CGWindowID>? = nil) {
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

    /// Drop `resizeMinCache` entries whose container has left every Space's tree. The cache is
    /// keyed by object identity and otherwise cleared only in `build()`, so a container that was
    /// pair-resized and then collapsed (e.g. by a window close) would keep its learned minimum
    /// for the manager's lifetime — a slow, bounded leak. Cheap: the cache only ever holds
    /// pair-resized split children, and this runs only when a reconcile actually removed a leaf.
    private func pruneResizeCache() {
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
            out += "\n"
        }
        out += "--- visible tab bars (\(TabBarWindow.registry.allObjects.filter { $0.isVisible }.count)) ---\n"
        for bar in TabBarWindow.registry.allObjects where bar.isVisible {
            out += "  frame=\(rectStr(bar.frame))\n"
        }
        try? out.write(to: URL(fileURLWithPath: "/tmp/mosaic-dump.txt"), atomically: true, encoding: .utf8)
        NSLog("Mosaic: layout dumped to /tmp/mosaic-dump.txt")
    }

    private func rectStr(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
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
        // v2: keys are workspace numbers (1-9). Legacy files keyed by macOS Space id (huge
        // numbers) are silently dropped here — a one-time reset of persisted layouts on upgrade.
        for (key, space) in state.spaces {
            if let id = UInt64(key), id >= 1, id <= 9 { savedState[id] = space }
        }
        scratchpadBundleID = state.scratchpadBundle
        savedShownByMonitor = state.shownByMonitor ?? []
        NSLog("Mosaic: loaded \(savedState.count) saved workspace layout(s)")
    }

    /// Restore EVERY saved workspace at once, at launch. In the emulated model all windows share
    /// one on-screen Space, so a lazy per-visit restore lets the first-visited workspace swallow
    /// every other workspace's currently-open windows. Instead: build all saved trees from ONE
    /// shared pool of open windows (each window matched to the workspace it was saved in), then
    /// show the first non-empty workspace on each monitor and park the rest. Windows for apps
    /// that haven't relaunched yet are simply absent from a tree and re-adopted by reconcile
    /// later; windows opened since the save fall through to the active workspace as usual.
    private func restoreSavedWorkspaces() {
        guard !savedState.isEmpty else { return }
        // Build launch routing hints from EVERY saved window first, so apps that relaunch after
        // us (reboot) can still be routed to their workspace even though they're absent from the
        // pool right now. Cleared a few seconds later (in startObserving).
        for (id, saved) in savedState {
            var wins: [SavedWindow] = []
            flattenSaved(saved.tree, into: &wins)
            for sw in wins {
                guard let b = sw.bundleID else { continue }
                if let t = sw.title { restoreHints["\(b)\u{1}\(t)"] = Int(id) }
                restoreHints[b] = Int(id)   // weaker bundle-only fallback
            }
        }
        var pool = AX.managedWindows().compactMap(ManagedWindow.init).filter {
            !isFloating($0) && !$0.isFullscreen && $0.app.bundleIdentifier != scratchpadBundleID
        }
        for (id, saved) in savedState.sorted(by: { $0.key < $1.key }) {
            guard let tree = saved.tree, let root = rebuild(tree, pool: &pool) else { continue }
            let st = SpaceState(displayID: assignedDisplay(forWorkspace: Int(id)) ?? 0)
            st.mode = mode(named: saved.mode)
            st.root = root
            st.focused = root.firstLeaf()
            spaces[id] = st
            wireTabCallbacks(root)
        }
        savedState.removeAll()   // consumed (matched windows removed from the pool)
        observer.watchForClose(AX.managedWindows().compactMap(ManagedWindow.init))

        // Show the workspace each monitor showed last session (by left→right monitor index);
        // else the first non-empty workspace pinned to it; else its default. Park the rest. Never
        // leaves a monitor showing an empty workspace while a populated one it owns sits parked.
        for (i, did) in orderedDisplays().enumerated() {
            guard let scr = screen(forDisplayID: did) else { continue }
            let owned = (1...9).filter { assignedDisplay(forWorkspace: $0) == did }
            let remembered = savedShownByMonitor.indices.contains(i) ? savedShownByMonitor[i] : 0
            let n: Int
            if remembered >= 1, remembered <= 9, assignedDisplay(forWorkspace: remembered) == did {
                n = remembered   // exact restored view
            } else {
                n = owned.first { spaces[UInt64($0)]?.root != nil } ?? defaultWorkspaceNumber(for: scr)
            }
            shownOnDisplay[did] = UInt64(n)
            workspace(n, on: scr).displayID = did   // ensure it exists and is homed here
        }
        activeSpaceID = screenUnderMouse().flatMap { shownOnDisplay[displayID(of: $0)] }
        reassertAllWorkspaces()
        updateFocusIndicator()
        if let scr = screenUnderMouse() { showWorkspaceIndicator(for: scr) }
        NSLog("Mosaic: restored \(spaces.count) workspace(s) at launch")
    }

    /// Collect every leaf window of a saved tree (depth-first) — used to build launch hints.
    private func flattenSaved(_ node: SavedNode?, into out: inout [SavedWindow]) {
        guard let node else { return }
        if let w = node.window { out.append(w); return }
        for c in node.children ?? [] { flattenSaved(c, into: &out) }
    }

    /// If a just-appeared window matches a launch hint, route it to the workspace it was saved
    /// in (creating/parking as needed) instead of the active one. Returns true if it was routed.
    /// Consumes the hint so a second window of the same app doesn't chase it.
    private func routeByHint(_ window: ManagedWindow) -> Bool {
        guard !restoreHints.isEmpty, let b = window.app.bundleIdentifier else { return false }
        let strong = "\(b)\u{1}\(window.title)"
        guard let n = restoreHints[strong] ?? restoreHints[b], n >= 1, n <= 9,
              UInt64(n) != activeSpaceID else { return false }
        restoreHints[strong] = nil
        placeOnWorkspace(window, n: n)
        return true
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
        // Keyed by workspace number — the stable identity in the emulated model (no CGS Space
        // id, no monitor fingerprint, no desktop ordinal needed).
        for (id, st) in spaces {
            guard let root = st.root else { continue }
            out[String(id)] = SavedSpace(displayID: st.displayID,
                                         mode: modeName(st.mode),
                                         tree: serialize(root),
                                         displayUUID: nil, spaceOrdinal: nil)
        }
        // Keep layouts for workspaces we haven't restored yet this session.
        for (id, saved) in savedState where spaces[id] == nil {
            out[String(id)] = saved
        }
        // Which workspace is shown on each monitor, left→right, so a restart restores the view.
        let shown = orderedDisplays().map { Int(shownOnDisplay[$0] ?? 0) }
        let state = SavedState(spaces: out, assignments: nil,
                               assignmentApps: nil, scratchpadBundle: scratchpadBundleID,
                               shownByMonitor: shown)
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

    /// Rebuild a saved workspace (keyed by its number) by matching its windows to open ones.
    private func restoreSaved(_ id: UInt64, on screen: NSScreen) -> Bool {
        guard let saved = savedState[id], let savedTree = saved.tree else { return false }
        var pool = captureWindows(on: screen)
        guard !pool.isEmpty else { return false }

        guard let root = rebuild(savedTree, pool: &pool) else { return false }

        let st = SpaceState(displayID: displayID(of: screen))   // place it on the current monitor
        st.mode = mode(named: saved.mode)
        st.root = root
        spaces[id] = st
        activeSpaceID = id
        focused = root.firstLeaf()
        savedState[id] = nil   // consumed — it's now live

        // Windows opened since the layout was saved → append them.
        for window in pool { insert(window) }

        if let r = self.root { wireTabCallbacks(r) }
        observer.watchForClose(captureWindows(on: screen))
        render()
        NSLog("Mosaic: restored workspace \(id)")
        return true
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

    /// `onScreen` lets a caller that already enumerated the on-screen window ids this pass
    /// (e.g. reconcile) thread its snapshot in, instead of paying a second identical
    /// CGWindowList enumeration microseconds later. Defaults to a fresh enumeration.
    private func captureWindows(on screen: NSScreen, onScreen: Set<CGWindowID>? = nil) -> [ManagedWindow] {
        let __perf = DispatchTime.now(); defer { Perf.record("captureWindows", since: __perf) }
        let onScreen = onScreen ?? AX.onScreenWindowIDs()
        return AX.managedWindows()
            .compactMap(ManagedWindow.init)
            .filter { window in
                // Order matters: reject via cheap local checks and the on-screen gate BEFORE the
                // cross-process isFullscreen / frame reads, so off-Space windows (most of a
                // multi-desktop session) don't each waste an AXFullScreen IPC to then be discarded.
                guard !isFloating(window) else { return false }                        // local: rules / floatingApps
                guard let wid = AX.windowID(window.element), onScreen.contains(wid) else { return false }
                guard !window.isFullscreen else { return false }                       // IPC — now only for on-screen wins
                if window.app.bundleIdentifier == scratchpadBundleID { return false }   // scratchpad app floats
                guard let axFrame = window.frame else { return false }
                let cocoaFrame = Geometry.flip(axFrame)
                return screen.frame.contains(CGPoint(x: cocoaFrame.midX, y: cocoaFrame.midY))
            }
    }

    private func isFloating(_ window: ManagedWindow) -> Bool {
        // An explicit per-app rule wins both ways: float:true floats, float:false pins to tiling
        // (overrides floatingApps AND the auto-dialog heuristic below).
        if let ruled = ruleFor(window)?.float { return ruled }
        if floatingApps.contains(window.appName.lowercased()) { return true }
        if let bundle = window.app.bundleIdentifier?.lowercased(), floatingApps.contains(bundle) { return true }
        if Config.shared.autoFloatDialogs, isDialogLike(window) { return true }
        return false
    }

    /// Terminal bundle ids that mis-report as dialog-like (no full-screen button) but should
    /// still tile — the AeroSpace exception. Extend via a `float:false` rule for others.
    private static let terminalBundles: Set<String> = [
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "com.googlecode.iterm2",
        "com.apple.terminal", "net.kovidgoyal.kitty", "dev.warp.warp-stable", "com.mitchellh.ghostty",
    ]

    /// Heuristic (AeroSpace): a standard-subrole window with no native full-screen button is
    /// almost always a dialog / palette / settings panel — float it. Terminals are excepted
    /// (they lack the button but should tile). Only consulted when `autoFloatDialogs` is on.
    private func isDialogLike(_ window: ManagedWindow) -> Bool {
        if let b = window.app.bundleIdentifier?.lowercased(), WindowManager.terminalBundles.contains(b) { return false }
        return !AX.hasFullscreenButton(window.element)
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

    /// The screen under the mouse (or the main/first screen). `nil` only in a screenless state
    /// — all displays asleep mid-reconfiguration, or a headless Mac — where the old
    /// `NSScreen.screens[0]` fallback trapped. Callers guard and no-op when there's no screen.
    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

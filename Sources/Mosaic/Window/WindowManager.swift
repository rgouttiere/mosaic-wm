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
    enum Mode: CaseIterable { case columns, grouped, tabbed, masterStack }

    /// The layout state for one workspace, including which monitor it is currently placed on.
    /// `displayID` is where the workspace is shown right now (it can move between monitors on
    /// dock/undock or an explicit send) — 0 while the workspace exists but is parked nowhere.
    final class SpaceState {
        var displayID: CGDirectDisplayID
        var root: Container?
        weak var focused: Container?
        var mode: Mode = .columns
        var isZoomed = false   // focused tile fills the screen (monocle), follows focus
        init(displayID: CGDirectDisplayID) { self.displayID = displayID }
    }

    /// All workspaces, keyed by synthetic id (= workspace number). Persisted.
    var spaces: [UInt64: SpaceState] = [:]
    /// The workspace currently shown on the monitor under the mouse (the "active" one that
    /// keyboard ops target). Set by us on switch / monitor cross — never read from CGS.
    var activeSpaceID: UInt64?
    /// Which workspace (synthetic id) is currently placed on each physical monitor. This is
    /// the emulated-workspace equivalent of "the current Space of each display": we own it
    /// outright instead of asking the window server. Absent = that monitor shows no workspace.
    var shownOnDisplay: [CGDirectDisplayID: UInt64] = [:]
    // Which workspace is shown on each monitor, keyed by its stable LEFT-TO-RIGHT index (display IDs
    // change across sleep/dock, positions don't). Snapshotted only at the full monitor count, so a
    // degraded wake (externals not back yet) can't overwrite it; restored in ensureAllPresentMonitorsShown.
    var shownByMonitorIndex: [Int: UInt64] = [:]
    var maxMonitorCount = 1
    var manageAll = false

    /// Workspaces with unseen activity while PARKED (a parked window's title changed — a chat's
    /// unread counter, a build finishing…). Published in status.json so an external bar can badge
    /// the pill. Cleared when the user actually visits the workspace. Only the emulated model makes
    /// this possible: parked windows still live on the one Space, so their AX titles stay readable.
    var attentionWorkspaces: Set<Int> = []
    /// Last title we saw per managed window — the baseline `scanAttention` diffs against. Keyed by
    /// window identity (a stable class ref while it's managed).
    var titleSnapshot: [ObjectIdentifier: String] = [:]

    var floatingApps: Set<String> = Config.shared.floatingApps

    /// Initial build strategy from config (falls back to columns).
    var defaultMode: Mode {
        switch Config.shared.defaultMode.lowercased() {
        case "grouped": return .grouped
        case "tabbed": return .tabbed
        case "master-stack", "masterstack", "master": return .masterStack
        default: return .columns
        }
    }

    lazy var observer = WindowObserver { [weak self] in self?.tick() }
    let focusIndicator = FocusIndicator()
    let zoomBadge = ZoomBadge()
    let resizeRatioHUD = ResizeRatioHUD()
    var liveRenderPending = false            // coalescing state for live-resize renders
    var lastLiveRenderTime = Date.distantPast
    var resizeSettleWork: DispatchWorkItem?  // debounced finalize (save) after a keyboard-resize burst
    var lastResizePair: (c: Container, i: Int, horizontal: Bool)?  // for the end-of-gesture min learn
    let letterbox = LetterboxFill()
    /// While PiP mirrors a window, its on-screen tile is covered by the letterbox fill so the same
    /// video isn't visible twice. Only covers when this leaf is actually the front, shown tab.
    weak var pipSourceLeaf: Container?
    let windowBorders = WindowBorders()
    let dropHighlight = DropHighlight()
    var spaceTimer: Timer?
    var mouseMonitor: Any?
    var mouseUpMonitor: Any?
    var mouseMoveMonitor: Any?
    var lastMouseDisplayID: CGDirectDisplayID = 0
    var handles: [ResizeHandle] = []
    /// Discovered minimum size (points) per child container, so resize clamps up front
    /// instead of overshooting and snapping back every drag event.
    var resizeMinCache: [ObjectIdentifier: CGFloat] = [:]

    /// Persisted layouts for desktops not yet restored this session.
    var savedState: [UInt64: SavedSpace] = [:]
    var saveWork: DispatchWorkItem?
    /// Which workspace number was shown on each monitor (left→right order) last session, so a
    /// restart restores the exact view instead of guessing the first non-empty one.
    var savedShownByMonitor: [Int] = []

    /// Launch-time routing hints: for a short window after startup, a newly-appearing window
    /// whose app matches a saved layout is sent to the workspace it was saved in, not the active
    /// one — so apps that relaunch AFTER Mosaic (a full reboot) still land on the right workspace
    /// instead of piling onto whatever's focused. Keyed by "bundleID\u{1}title" (strong) and
    /// "bundleID" (fallback). Cleared a few seconds after launch. See `restoreSavedWorkspaces`.
    var restoreHints: [String: Int] = [:]

    /// The scratchpad app (by bundle id, persisted): all its windows stay out of tiling
    /// and are shown/hidden as a floating panel. Survives app/Mosaic relaunch.
    var scratchpadBundleID: String?
    var scratchpadVisible = false

    /// True while the machine/displays are asleep — no reconcile (AX is unreliable then).
    var suspended = false
    /// Debounces display-config changes: we resume only once the set of displays has
    /// stopped changing (dock/undock fires many events and migrates windows mid-flight).
    var displayChangeWork: DispatchWorkItem?
    /// Confirms a window kept "in grace" is really gone, so a closed window's tab is
    /// removed within ~0.25s instead of lingering until the next window event.
    var graceRecheck: DispatchWorkItem?
    /// Guards reconcile against re-entrancy (all triggers are on the main queue, but this
    /// makes it impossible for a nested call to corrupt the tree mid-pass).
    var isReconciling = false
    /// On-screen window IDs at the last reconcile that ran the full enumeration. If the
    /// set is unchanged and nothing closed, a reconcile can't have anything to do — used
    /// to skip the costly captureWindows() on pure focus/app switches.
    var lastReconcileOnScreen: Set<CGWindowID> = []
    var lastReconcileSpaceID: UInt64?   // active space the on-screen snapshot above was taken on
    /// Recently-focused workspace numbers, most-recent first. Powers the switcher's recency
    /// ordering and the ⌘⌥B back-and-forth toggle.
    var workspaceRecency: [Int] = []
    /// i3 "preselect": arm a split orientation on a window so the NEXT window nests into a
    /// new split with it. `vertical` = new window goes below; else to the right.
    var preselect: (vertical: Bool, leaf: Container)?
    /// True while a tab is being dragged — freeze the active desktop so the drop
    /// re-renders the source screen correctly (mouse crossing screens won't switch it).
    var tabDragging = false
    var grabbedLeaf: Container?   // the leaf being moved by a modifier-hold drag or keyboard grab
    var grabTarget: Container?    // keyboard grab: the tile the drop is currently aimed at
    var grabKeyWindow: NSWindow?  // keyboard grab: transparent key panel that captures hjkl/⏎/Esc
    var grabMonitor: Any?         // keyboard grab: local key/mouse monitor
    let workspaceHUD = WorkspaceHUD()
    let notchHUD = NotchHUD()
    /// Notifies the menu bar of the current workspace number (nil = unknown/unmanaged).
    var onWorkspaceChanged: ((Int?) -> Void)?
    /// Supplies the Mosaic actions for the switcher's "Actions" mode (set by AppDelegate).
    var switcherActions: (() -> [(title: String, subtitle: String, run: () -> Void)])?
    var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mosaic/state.json")
    }

    // Operate on the active desktop's state transparently.
    var active: SpaceState? { activeSpaceID.flatMap { spaces[$0] } }
    var activeScreen: NSScreen? { active.flatMap { screen(forDisplayID: $0.displayID) } }

    // ── Stored state relocated here so the split extensions stay stored-property-free ──
    /// Windows we've already applied an on-open `fullscreen` rule to, so we set the state
    /// once and then leave the user free to toggle it. Pruned to living windows each pass.
    var fullscreenApplied = Set<CGWindowID>()
    var decorationsSuppressed = false   // a screenshot tool is up → overlays hidden until it leaves
    var lastEmittedWorkspace: Int? = -1   // sentinel: forces the first emit through

    // MARK: - Emulated workspaces (v2 — replaces the CGS Space layer)

    /// The synthetic id of the workspace currently placed on `screen`. This is the emulated
    /// stand-in for `currentWorkspace(for:)`: it reads OUR own placement map, never the
    /// window server, so a workspace only "changes" on a screen when we park/unpark it.
    func currentWorkspace(for screen: NSScreen) -> UInt64? {
        shownOnDisplay[displayID(of: screen)]
    }

    // MARK: Workspace ↔ monitor assignment (model A: global 1-9, each pinned to a monitor)

    /// Present monitors ordered left→right by frame x. The basis for the workspace→monitor
    /// partition, so the assignment is deterministic and recomputes on dock/undock.
    func orderedDisplays() -> [CGDirectDisplayID] {
        NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }.map(displayID(of:))
    }

    /// The monitor workspace `n` (1-9) is pinned to, among the CURRENTLY PRESENT monitors.
    /// Default: the nine workspaces split into contiguous blocks left→right, as even as
    /// possible (3 monitors → 1-3 | 4-6 | 7-9; 2 monitors → 1-5 | 6-9; 1 monitor → all). A
    /// config override (`workspaceMonitors: {"5": 2}`) pins a workspace to a monitor index
    /// (1-based, left→right). Because it's computed from present monitors, unplugging a display
    /// re-partitions the numbers over what's left — the emulated answer to home↔office.
    func assignedDisplay(forWorkspace n: Int) -> CGDirectDisplayID? {
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
    func homeScreen(forWorkspace n: Int) -> NSScreen? {
        assignedDisplay(forWorkspace: n).flatMap(screen(forDisplayID:))
    }

    /// The default workspace to show when a monitor is first visited: the lowest-numbered
    /// workspace pinned to it (left monitor → 1, middle → 4, right → 7 on a triple-screen).
    func defaultWorkspaceNumber(for screen: NSScreen) -> Int {
        let did = displayID(of: screen)
        return (1...9).first { assignedDisplay(forWorkspace: $0) == did } ?? 1
    }

    /// Cocoa rect a parked workspace is laid out in — the screen's ON-SCREEN tiling rect pushed off
    /// its OWN home monitor's void-facing edge (see `Geometry.parkRect`). Using `layoutRect(screen)`
    /// (the exact rect unpark restores) makes park a pure translation on that monitor: no cross-
    /// resolution clamp, so windows never come back resized, and the strip stays on the home screen.
    func parkRect(for screen: NSScreen) -> NSRect {
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
    func parkWorkspace(_ ws: SpaceState) {
        guard let r = ws.root else { return }
        guard let screen = screen(forDisplayID: ws.displayID) ?? screenUnderMouse() ?? NSScreen.screens.first
        else { return }
        r.arrange(in: parkRect(for: screen))
    }

    /// Unpark a workspace onto `screen`: un-minimize (in case a window was minimized — by the
    /// user, or a previous build), lay the tree on-screen, and lift its windows and strips above
    /// unmanaged windows. `setCocoaFrame`'s cache skips windows already at their on-screen frame.
    func unparkWorkspace(_ ws: SpaceState, on screen: NSScreen, raise: Bool = true) {
        guard let r = ws.root else { return }
        r.forEachLeaf { if let w = $0.window, AX.isMinimized(w.element) { AX.setMinimized(w.element, false) } }
        r.arrange(in: layoutRect(screen))
        if raise { r.raiseVisibleWindows() }   // caller may skip when a render() right after re-raises the same windows
        r.raiseVisibleStrips()
    }

    /// Raise every SHOWN workspace's windows so they sit above the parked workspaces' off-screen
    /// slivers (macOS keeps ~40px of a parked window on the nearest monitor edge; we can't hide it
    /// with alpha on recent macOS, so we cover it with the visible tiling instead). Called after
    /// any park so a just-parked window can't stay on top of the tiles that should hide it.
    func coverParkedSlivers() {
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
    func liftAppsAboveParked(_ ws: SpaceState) {
        let __perf = DispatchTime.now(); defer { Perf.record("liftApps", since: __perf) }
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

    /// Opt-in (`robustCrossAppTabs`): after switching the active workspace, cross-app tabbed groups on
    /// OTHER shown monitors can be left showing the wrong app — macOS z-orders windows by app GLOBALLY,
    /// so the switch's activation buries their selected tab under a sibling app (tab bar says Firefox,
    /// Chrome sits on top). Re-activate each such group's apps (selected tab last per group), then
    /// re-focus the ACTIVE workspace last so keyboard focus stays where the user is. Best-effort: two
    /// shown groups that need different apps of the SAME pair on top at once is a hard macOS limit.
    func reassertShownTabApps() {
        guard Config.shared.robustCrossAppTabs else { return }
        for (id, ws) in spaces where id != activeSpaceID && screen(forWorkspace: id) != nil {
            guard let r = ws.root, hasMultiAppTabGroup(r) else { continue }
            r.forEachLeaf { if let w = $0.window, !w.isFullscreen { w.app.activate() } }         // every app…
            r.forEachVisibleLeaf { if let w = $0.window, !w.isFullscreen { w.app.activate() } }  // …selected on top
        }
        if let a = active, let r = a.root, let w = (a.focused ?? r.firstLeaf()).window, !w.isFullscreen {
            AX.makeMain(w.element); w.activateApp(); AX.raise(w.element)   // focus back to the active workspace
        }
    }

    /// True if any tabbed container in this tree stacks windows from more than one app — the only
    /// case whose on-screen tab is fragile to global app-layer activation (same-app stacks are fine).
    func hasMultiAppTabGroup(_ root: Container) -> Bool {
        var found = false
        root.forEachTabbed { group in
            guard !found else { return }
            var pids = Set<pid_t>()
            group.forEachLeaf { if let w = $0.window { pids.insert(w.app.processIdentifier) } }
            if pids.count > 1 { found = true }
        }
        return found
    }

    /// Fetch (or create) the workspace numbered `n`, ensuring it's marked as placed on `screen`.
    @discardableResult
    func workspace(_ n: Int, on screen: NSScreen) -> SpaceState {
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

    func screen(forDisplayID id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var root: Container? {
        get { active?.root }
        set { active?.root = newValue }
    }
    var focused: Container? {
        get { active?.focused }
        set { active?.focused = newValue }
    }
    var mode: Mode {
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

        // A screenshot tool's overlay is a floating window → it won't trigger a reconcile render, so
        // hide our decorations the instant it activates, and restore them (no focus steal) when a
        // normal app comes back.
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.screenshotToolFrontmost() {
                self.decorationsSuppressed = true
                self.letterbox.hideAll(); self.windowBorders.hideAll(); self.focusIndicator.hide(); self.zoomBadge.hide()
            } else if self.decorationsSuppressed {
                self.decorationsSuppressed = false
                self.render(activate: false)
            }
        }
    }

    /// Dock/undock (home ↔ office) fires a burst of screen-parameter changes while macOS
    /// adds/removes displays and scatters windows. Freeze until the display set has been STABLE
    /// for a moment, then re-home workspaces onto present monitors and re-assert every
    /// placement. In the emulated model there are no real Spaces to drift between, so this is
    /// just geometry — no CGS moves, no per-window rehome heuristics.
    func handleDisplayChange() {
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
            self.ensureAllPresentMonitorsShown()   // dock: show/home ALL monitors, not just the mouse's
            self.invalidateAllFrameCaches()   // docking scattered windows out from under us → force re-placement
            self.reassertAllWorkspaces()
            self.emitWorkspaceState(self.activeSpaceID.map(Int.init))   // re-publish status.json (sketchybar)
        }
        displayChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// After wake, macOS scatters windows and hides our borderless overlays. Wait for it to
    /// settle, then re-assert every workspace's placement (parked off-screen or tiled on its
    /// monitor) — which also brings the tab bars back. No CGS, no drift heuristics.
    func handleWake() {
        suspended = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.suspended = false
            self.activeSpaceID = nil   // force a fresh detect of the current workspace
            self.checkSpaceChange()
            self.ensureAllPresentMonitorsShown()   // guard against wake re-assigning display ids
            self.invalidateAllFrameCaches()   // macOS scattered windows while asleep → force the re-tile writes
            self.reassertAllWorkspaces()
            self.emitWorkspaceState(self.activeSpaceID.map(Int.init))   // re-publish status.json (sketchybar)
            // A slow wake can re-hide the overlays AND nudge windows again after we refresh; drop the
            // frame cache and re-assert again at +2s and once more at +5s, so external monitors that
            // wake late (and any window macOS scatters after the first passes) still get corrected
            // without a manual visit to each workspace.
            for delay in [2.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    self.ensureAllPresentMonitorsShown()
                    self.invalidateAllFrameCaches()
                    self.reassertAllWorkspaces()
                    self.emitWorkspaceState(self.activeSpaceID.map(Int.init))
                }
            }
        }
    }

    /// Drop placements that point at a monitor that's no longer attached, so a workspace homed
    /// on a removed display can be re-shown on a present one at its next visit (its windows
    /// were migrated by macOS anyway). Keeps `shownOnDisplay` consistent with reality.
    func rehomeToPresentMonitors() {
        let present = Set(NSScreen.screens.map(displayID(of:)))
        for (did, _) in shownOnDisplay where !present.contains(did) { shownOnDisplay[did] = nil }
        for (_, ws) in spaces where ws.displayID != 0 && !present.contains(ws.displayID) {
            ws.displayID = 0   // parked, no home monitor until re-shown
        }
    }

    /// Make sure EVERY present monitor has a workspace assigned AND homed on it — not just the one
    /// under the mouse (all `checkSpaceChange` bootstraps). After docking, newly-attached monitors
    /// have no `shownOnDisplay` entry and workspaces whose home display was just re-added still have
    /// `displayID == 0` (cleared on the prior undock), so `screen(forWorkspace:)` returns nil for
    /// them and `reassertAllWorkspaces` PARKS them → those screens stay blank until the user
    /// manually ⌘⌥-switches each. Assign every present monitor its shown-or-default workspace and
    /// re-home it via `workspace(_:on:)` (which sets `displayID`), so reassert can tile them all.
    /// Snapshot which workspace is shown on each monitor, by left-to-right index. Only records at the
    /// full monitor count so a degraded (collapsed) wake can't clobber the good mapping.
    func rememberShown() {
        let ids = orderedDisplays()
        maxMonitorCount = max(maxMonitorCount, ids.count)
        guard ids.count == maxMonitorCount else { return }
        for (i, did) in ids.enumerated() { if let n = shownOnDisplay[did] { shownByMonitorIndex[i] = n } }
    }

    func ensureAllPresentMonitorsShown() {
        for (i, did) in orderedDisplays().enumerated() {
            guard let screen = screen(forDisplayID: did) else { continue }
            let n: Int
            if let existing = shownOnDisplay[did] {
                n = Int(existing)                       // already has a shown workspace → re-home it
            } else if let remembered = shownByMonitorIndex[i],
                      assignedDisplay(forWorkspace: Int(remembered)) == did {   // restore the last-shown one
                n = Int(remembered)
                shownOnDisplay[did] = remembered
            } else {
                let owned = (1...9).filter { assignedDisplay(forWorkspace: $0) == did }
                n = owned.first { spaces[UInt64($0)]?.root != nil } ?? defaultWorkspaceNumber(for: screen)
                shownOnDisplay[did] = UInt64(n)
            }
            workspace(n, on: screen)   // ensure it exists AND is homed on this monitor (sets displayID)
        }
    }

    /// Re-assert every workspace's placement: tile the ones shown on a present monitor, park
    /// the rest off-screen. The single source of truth for "where every window should be" —
    /// the emulated-model replacement for the whole drift/rehome/refresh machinery.
    /// Forget every managed window's last-written frame so the next `reassertAllWorkspaces` re-issues
    /// its AX placement even when the computed target is unchanged. Needed whenever the SYSTEM moved
    /// windows without us — sleep/wake, display reconfigure — because `setCocoaFrame`'s <1px cache
    /// would otherwise skip the corrective write and leave them where macOS scattered them (which is
    /// why revisiting each workspace by hand "fixed" it: park→unpark writes two different rects).
    func invalidateAllFrameCaches() {
        for (_, ws) in spaces { ws.root?.forEachLeaf { $0.window?.invalidateFrameCache() } }
    }

    func reassertAllWorkspaces() {
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

    func focusWindowUnderMouse() {
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
    func syncFocusToSystem() {
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
        refreshFocusAndDim()     // move the halo (+ follow the monitor dim if on). no re-tile/raise
    }

    /// The visible window under `point`: in a tabbed container only the selected child
    /// is on screen, so hidden tabs are never matched.
    func visibleLeaf(at point: NSPoint, in node: Container) -> Container? {
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
    func checkSpaceChange() {
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
        if Config.shared.dimInactiveMonitors {   // the active monitor changed → follow the dim now
            updateWindowBorders()
            dimInactiveMonitorTabBars()
            updateFocusIndicator()   // keep the halo on top of the re-drawn borders
        }
        showWorkspaceIndicator(for: screen)
        focusIndicator.pulse()
        reassertShownTabApps()   // mouse-cross also changes the active workspace → re-assert other monitors
    }

}

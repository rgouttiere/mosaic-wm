import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    let windowManager = WindowManager()
    private var hotkeys: HotkeyManager?
    private let cmdTabTap = CmdTabTap()
    private let comboTap = ComboTap()
    /// Actions routed through the event tap (not Carbon) so they beat reserved system shortcuts —
    /// e.g. workspace nav on Ctrl+←/→ works without disabling Mission Control's "move a space".
    private let tapRoutedActions: Set<String> = ["workspace-next", "workspace-prev"]
    private var statusItem: NSStatusItem!
    private var configWatch: DispatchSourceFileSystemObject?
    private var configReloadWork: DispatchWorkItem?
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AX.installMessagingTimeout()   // before anything talks to another app over AX
        presentCapabilityIssues()      // a private symbol Apple removed → say so, don't fail silently
        Health.noteCrashSinceLastStart()   // "Mosaic was gone this morning" → the cause, in the log
        // `killall Mosaic` and a launchd stop deliver SIGTERM, which by default ends the process
        // with no applicationWillTerminate: parked windows stayed off-screen, apps hidden for a
        // park stayed hidden. Route it through a normal quit so unparkAll + saveNow run.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term
        requestAccessibilityIfNeeded()
        setupStatusItem()
        windowManager.onWorkspaceChanged = { [weak self] number in
            self?.shownNumber = number; self?.refreshStatusTitle()
        }
        windowManager.onHealthChanged = { [weak self] issue in
            guard let self else { return }
            self.healthIssue = issue; self.refreshStatusTitle()
            guard let issue, !self.healthAlertShown else { return }
            self.healthAlertShown = true   // once per process: the icon keeps saying it afterwards
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Mosaic is not managing your windows"
            alert.informativeText = issue + "\n\n`mosaic doctor` has the full report."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        setupHotkeys()
        setupCmdTabTap()
        windowManager.switcherActions = { [weak self] in
            guard let self else { return [] }
            let actions = self.makeActions()
            let binds = Config.shared.keybindings
            return actions.keys.filter { $0 != "switcher" }.sorted()
                .map { (title: $0, subtitle: binds[$0] ?? "", run: actions[$0]!) }
        }
        windowManager.startObserving()
        presentConfigIssues()   // surface any problems from the startup config load
        startWatchingConfig()   // hot-reload config.json on save (no manual reload-config)
        // Three seconds, not now: the instance launchd relaunched right after a wake found the
        // multitouch service still settling and died again within a second (2026-10-04 10:12:18).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in self?.updateTrackpadGestures() }   // opt-in native 3-finger swipe → workspace nav
        updateWindowDrag()         // hold-modifier + left-drag to move any window

        // CLI channel: `mosaic <verb>` over the Unix socket; every request gets an answer.
        CommandServer.shared.handle = { [weak self] line in
            self?.respond(to: line) ?? (1, "Mosaic is shutting down\n")
        }
        CommandServer.shared.start()
    }

    /// Answer one CLI request. Reports and queries return text; an action runs and returns nothing;
    /// a name nobody knows is an error — it used to vanish silently.
    func respond(to line: String) -> (status: Int32, text: String) {
        let parts = line.split(separator: " ").map(String.init)
        guard let verb = parts.first, !verb.isEmpty else { return (1, "empty command\n") }
        switch verb {
        case "doctor":
            return (0, windowManager.doctorReport())
        case "dump-layout":
            return (0, windowManager.dumpLayout())
        case "query":
            let wm = windowManager
            let focused = wm.activeSpaceID.flatMap { wm.workspaceNumber(for: $0) }
            let dict = wm.statusDictionary(focused: focused)
            switch parts.dropFirst().first {
            case "focused", "workspace":
                return (0, (dict["focused"] as? Int).map { "\($0)\n" } ?? "\n")
            case "workspaces":
                return (0, ((dict["workspaces"] as? [Int]) ?? []).map(String.init).joined(separator: " ") + "\n")
            case "active":
                let mons = (dict["monitors"] as? [[String: Any]]) ?? []
                return (0, mons.compactMap { $0["workspace"] as? Int }.map(String.init).joined(separator: " ") + "\n")
            default:
                let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
                return (0, data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            }
        default:
            if let run = makeActions()[verb] { run(); return (0, "") }
            return (1, "unknown action '\(verb)' — see `mosaic --list`\n")
        }
    }

    /// Private symbols are resolved at runtime (`PrivateAPI`). Losing a cosmetic one is logged;
    /// losing the AX→window-id bridge means nothing can be managed, and the user must hear it from
    /// us — the alternative was a dyld launch failure with no message at all.
    private func presentCapabilityIssues() {
        Log.event("private API —\n" + PrivateAPI.report())
        let missing = PrivateAPI.missingEssential
        guard !missing.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "This macOS removed something Mosaic depends on"
        alert.informativeText = missing.map { "• \($0.symbol) — \($0.purpose)" }.joined(separator: "\n")
            + "\n\nMosaic will run but cannot manage windows until this is addressed. See dump-layout for details."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private var lastConfigIssues = ""
    private var isPresentingIssues = false

    /// Show a warning (once per distinct problem set) when config.json has issues, so a
    /// bad edit isn't silently reverted to defaults. No-op when the config is clean.
    private func presentConfigIssues() {
        let issues = Config.shared.loadIssues
        guard !issues.isEmpty else { lastConfigIssues = ""; return }
        let key = issues.joined(separator: "\n")
        guard key != lastConfigIssues, !isPresentingIssues else { return }   // no nag / no stacked modal
        lastConfigIssues = key
        isPresentingIssues = true
        defer { isPresentingIssues = false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "config.json: \(issues.count) issue\(issues.count > 1 ? "s" : "")"
        alert.informativeText = issues.map { "• \($0)" }.joined(separator: "\n")
            + "\n\nValid values are applied; everything else keeps its default."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open config.json")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(Config.shared.configURL)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Health.noteCleanExit()      // the next start must not read this exit as a death
        CommandServer.shared.stop()
        windowManager.unparkAll()   // bring parked (off-screen, transparent) windows back so none is stranded
        windowManager.saveNow()
    }

    // MARK: Accessibility permission

    /// Mosaic cannot move/resize other apps' windows without Accessibility trust.
    /// This prompts the user once; the grant persists for a signed, bundled build.
    private func requestAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog("Mosaic: Accessibility permission not yet granted — grant it in System Settings › Privacy & Security › Accessibility, then restart.")
        }
    }

    // MARK: Menu bar

    private var shownNumber: Int?
    private var healthIssue: String?
    private var healthAlertShown = false

    /// "▦3" normally; "▦!" while the self-check says the grant does not apply — a state that used
    /// to be invisible until you noticed nothing was tiling.
    private func refreshStatusTitle() {
        let number = shownNumber.map(String.init) ?? ""
        statusItem.button?.title = healthIssue == nil ? "▦\(number)" : "▦!\(number)"
        statusItem.button?.toolTip = healthIssue ?? "Mosaic"
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▦"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let bindings = Config.shared.keybindings

        // Clickable actions: title + the actual configured combo.
        let clickable: [(action: String, title: String, selector: Selector)] = [
            ("tile", "Tile current desktop", #selector(tileCurrentSpace)),
            ("cycle-mode", "Cycle layout: Columns → Grouped → Tabbed → Master-Stack", #selector(cycleMode)),
            ("manage-all", "Manage all desktops (toggle)", #selector(toggleManageAll)),
        ]
        for entry in clickable {
            let combo = MenuFormat.combo(bindings[entry.action])
            menu.addItem(withTitle: "\(entry.title)\(combo)", action: entry.selector, keyEquivalent: "")
        }

        // Navigation & overlays.
        menu.addItem(.separator())
        let nav: [(action: String, title: String, selector: Selector)] = [
            ("expose", "Overview (Exposé)", #selector(showExpose)),
            ("pip", "Picture-in-picture (focused window)", #selector(togglePiP)),
            ("switcher", "Quick-switcher / palette", #selector(showSwitcher)),
            ("hints", "Window hints", #selector(showHints)),
            ("workspace-back", "Back to previous workspace", #selector(workspaceBack)),
            ("workspace-prev", "Previous workspace (this screen)", #selector(workspacePrev)),
            ("workspace-next", "Next workspace (this screen)", #selector(workspaceNext)),
        ]
        for entry in nav {
            let combo = MenuFormat.combo(bindings[entry.action])
            menu.addItem(withTitle: "\(entry.title)\(combo)", action: entry.selector, keyEquivalent: "")
        }

        // Keyboard-only actions (directional): show the modifiers + "arrows".
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Keyboard shortcuts", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let directional: [(action: String, title: String)] = [
            ("focus-left", "Focus"),
            ("focus-group-left", "Focus group (skip tabs)"),
            ("move-left", "Move window"),
            ("resize-left", "Resize"),
        ]
        for entry in directional {
            let mods = MenuFormat.modifiers(bindings[entry.action])
            menu.addItem(withTitle: "  \(entry.title)   \(mods) + arrows", action: nil, keyEquivalent: "")
        }
        let screenMods = MenuFormat.modifiers(bindings["move-screen-next"])
        menu.addItem(withTitle: "  Move to screen   \(screenMods) [ / ]", action: nil, keyEquivalent: "")
        let deskMods = MenuFormat.modifiers(bindings["move-desktop-next"])
        menu.addItem(withTitle: "  Move to desktop   \(deskMods) [ / ]", action: nil, keyEquivalent: "")
        let wsMods = MenuFormat.modifiers(bindings["workspace-1"])
        let wsMoveMods = MenuFormat.modifiers(bindings["move-to-1"])
        let wsAssignMods = MenuFormat.modifiers(bindings["assign-1"])
        menu.addItem(withTitle: "  Switch to workspace N   \(wsMods) 1-9", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "  Send window to workspace N   \(wsMoveMods) 1-9", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "  Assign current desktop to N   \(wsAssignMods) 1-9", action: nil, keyEquivalent: "")

        let assignSubmenu = NSMenu()
        for n in 1...9 {
            let item = NSMenuItem(title: "Workspace \(n)", action: #selector(assignFromMenu(_:)), keyEquivalent: "")
            item.tag = n
            item.target = self
            assignSubmenu.addItem(item)
        }
        let assignItem = NSMenuItem(title: "Assign this desktop to…", action: nil, keyEquivalent: "")
        assignItem.submenu = assignSubmenu
        menu.addItem(assignItem)

        let unassignCombo = MenuFormat.combo(Config.shared.keybindings["unassign"])
        let unassignItem = NSMenuItem(title: "Unassign this desktop\(unassignCombo)",
                                      action: #selector(unassignThisDesktop), keyEquivalent: "")
        unassignItem.target = self
        menu.addItem(unassignItem)

        // More clickable actions.
        menu.addItem(.separator())
        let clickable2: [(action: String, title: String, selector: Selector)] = [
            ("group", "Group with neighbor as tab", #selector(groupWithNeighbor)),
            ("group-stacked", "Group with neighbor as stack", #selector(groupWithNeighborStacked)),
            ("preselect-vertical", "Preselect: split below", #selector(preselectVertical)),
            ("preselect-horizontal", "Preselect: split right", #selector(preselectHorizontal)),
            ("toggle-split", "Toggle split H/V", #selector(toggleSplit)),
            ("toggle-tabbed", "Toggle tabbed", #selector(toggleTabbed)),
            ("toggle-stacked", "Toggle stacked", #selector(toggleStacked)),
            ("equalize", "Equalize ratios", #selector(equalize)),
            ("rotate", "Rotate windows", #selector(rotate)),
            ("reset-desktop", "Reset desktop layout", #selector(resetDesktop)),
            ("float", "Float / unfloat app", #selector(toggleFloat)),
            ("zoom", "Zoom tile (monocle)", #selector(zoomTile)),
            ("scratchpad-send", "Send to scratchpad", #selector(scratchpadSend)),
            ("scratchpad-toggle", "Toggle scratchpad", #selector(scratchpadToggle)),
            ("scratchpad-release", "Release scratchpad", #selector(scratchpadRelease)),
            ("undo", "Undo last layout change", #selector(undoLayout)),
            ("recover", "Recover windows (heal)", #selector(recoverWindows)),
            ("dump-layout", "Dump layout (debug → /tmp/mosaic-dump.txt)", #selector(dumpLayout)),
            ("doctor", "Doctor (health report → /tmp/mosaic-doctor.txt)", #selector(runDoctor)),
        ]
        for entry in clickable2 {
            let combo = MenuFormat.combo(bindings[entry.action])
            menu.addItem(withTitle: "\(entry.title)\(combo)", action: entry.selector, keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Open config file…", action: #selector(openConfig), keyEquivalent: "")
        menu.addItem(withTitle: "Reload config", action: #selector(reloadConfig), keyEquivalent: "")
        menu.addItem(withTitle: "Clear layout", action: #selector(clearLayout), keyEquivalent: "")
        menu.addItem(withTitle: "Debug: dump layout → /tmp/mosaic-dump.txt",
                     action: #selector(dumpLayout), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Mosaic",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Target our own actions at self; leave Quit's target nil so it travels the
        // responder chain to NSApp (which is what actually handles terminate:).
        for item in menu.items
        where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func tileCurrentSpace() { windowManager.tileCurrentSpace() }
    @objc private func cycleMode() { windowManager.cycleMode() }
    @objc private func toggleManageAll() { windowManager.toggleManageAll() }
    @objc private func nextTab() { windowManager.nextTab() }
    @objc private func prevTab() { windowManager.prevTab() }
    @objc private func toggleSplit() { windowManager.toggleSplitOrientation() }
    @objc private func toggleTabbed() { windowManager.toggleTabbed() }
    @objc private func toggleStacked() { windowManager.toggleStacked() }
    @objc private func equalize() { windowManager.equalizeFocused() }
    @objc private func rotate() { windowManager.rotateFocused() }
    @objc private func resetDesktop() { windowManager.resetDesktop() }
    @objc private func groupWithNeighbor() { windowManager.groupWithNeighbor() }
    @objc private func groupWithNeighborStacked() { windowManager.groupWithNeighborStacked() }
    @objc private func preselectVertical() { windowManager.preselectSplit(vertical: true) }
    @objc private func preselectHorizontal() { windowManager.preselectSplit(vertical: false) }
    @objc private func toggleFloat() { windowManager.toggleFloatFocusedApp() }
    @objc private func zoomTile() { windowManager.toggleZoom() }
    @objc private func scratchpadSend() { windowManager.sendToScratchpad() }
    @objc private func scratchpadToggle() { windowManager.toggleScratchpad() }
    @objc private func scratchpadRelease() { windowManager.releaseScratchpad() }
    @objc private func recoverWindows() { windowManager.recover() }
    @objc private func undoLayout() { windowManager.undo() }
    @objc private func assignFromMenu(_ sender: NSMenuItem) { windowManager.assignWorkspace(sender.tag) }
    @objc private func unassignThisDesktop() { windowManager.unassignCurrent() }
    @objc private func showSwitcher() { windowManager.showSwitcher() }
    @objc private func showHints() { windowManager.showHints() }
    @objc private func showExpose() { windowManager.showExpose() }
    @objc private func togglePiP() { windowManager.togglePiP() }
    @objc private func workspaceBack() { windowManager.workspaceBack() }
    @objc private func workspaceNext() { windowManager.cycleWorkspace(next: true) }
    @objc private func workspacePrev() { windowManager.cycleWorkspace(next: false) }

    /// Start/stop the native 3-finger swipes from config.trackpadGestures. Idempotent: safe on
    /// launch and on every reload. Context-aware — the same swipe navigates the exposé when it's
    /// open, else drives workspaces / opens the exposé. Swipe left = next (macOS convention).
    private func updateTrackpadGestures() {
        let g = TrackpadGestures.shared
        guard Config.shared.trackpadGestures else { g.stop(); return }
        g.onSwipeLeft = { [weak self] in
            if ExposeOverlay.isOpen { ExposeOverlay.navLeft() }
            else { self?.windowManager.cycleWorkspace(next: false) }   // swipe left → workspace on the left
        }
        g.onSwipeRight = { [weak self] in
            if ExposeOverlay.isOpen { ExposeOverlay.navRight() }
            else { self?.windowManager.cycleWorkspace(next: true) }    // swipe right → workspace on the right
        }
        g.onSwipeUp = { [weak self] in
            if ExposeOverlay.isOpen { ExposeOverlay.navUp() }
            else { self?.windowManager.showExpose() }
        }
        g.onSwipeDown = {
            if ExposeOverlay.isOpen { ExposeOverlay.commit() }   // validate selection + close; closed: nothing
        }
        // 2-finger swipe → grid nav (columns + rows), but only while the exposé is open.
        g.isExposeNavActive = { ExposeOverlay.isOpen }
        g.onExposeNav = { col, row in
            if col < 0 { ExposeOverlay.navLeft() }
            else if col > 0 { ExposeOverlay.navRight() }
            else if row < 0 { ExposeOverlay.navUp() }
            else if row > 0 { ExposeOverlay.navDown() }
        }
        g.start()
    }
    /// Wire the "drag any window" capture (modifier-hold + left-drag). Reconfigured on hot-reload so a
    /// changed `dragModifier` takes effect immediately (empty = tear the tap down).
    private func updateWindowDrag() {
        let c = WindowDragCapture.shared
        c.beginGrab = { [weak self] p in self?.windowManager.beginWindowGrab(at: p) ?? false }
        c.moveGrab  = { [weak self] p in self?.windowManager.moveWindowGrab(to: p) }
        c.endGrab   = { [weak self] p in self?.windowManager.endWindowGrab(at: p) }
        c.configure(modifier: Config.shared.dragModifier)
    }

    @objc private func clearLayout() { windowManager.clear() }
    @objc private func openConfig() { NSWorkspace.shared.open(Config.shared.configURL) }
    @objc private func dumpLayout() { windowManager.dumpLayout() }
    @objc private func runDoctor() { windowManager.doctor() }

    // MARK: Global hotkeys

    private func setupHotkeys() {
        hotkeys = HotkeyManager()
        registerHotkeys()
    }

    /// Action name (matches config keybindings & CLI verbs) → what it does. Shared by the
    /// global hotkeys and the `mosaic <action>` CLI.
    func makeActions() -> [String: () -> Void] {
        let wm = windowManager
        var actions: [String: () -> Void] = [
            "tile": { wm.tileCurrentSpace() },
            "cycle-mode": { wm.cycleMode() },
            "manage-all": { wm.toggleManageAll() },
            "focus-left": { wm.focus(.left) },
            "focus-right": { wm.focus(.right) },
            "focus-up": { wm.focus(.up) },
            "focus-down": { wm.focus(.down) },
            "focus-group-left": { wm.focusGroup(.left) },
            "focus-group-right": { wm.focusGroup(.right) },
            "focus-group-up": { wm.focusGroup(.up) },
            "focus-group-down": { wm.focusGroup(.down) },
            "move-left": { wm.move(.left) },
            "move-right": { wm.move(.right) },
            "move-up": { wm.move(.up) },
            "move-down": { wm.move(.down) },
            "swap-left": { wm.swap(.left) },
            "swap-right": { wm.swap(.right) },
            "swap-up": { wm.swap(.up) },
            "swap-down": { wm.swap(.down) },
            "resize-left": { wm.resize(.left) },
            "resize-right": { wm.resize(.right) },
            "resize-up": { wm.resize(.up) },
            "resize-down": { wm.resize(.down) },
            "group": { wm.groupWithNeighbor() },
            "group-stacked": { wm.groupWithNeighborStacked() },
            "preselect-vertical": { wm.preselectSplit(vertical: true) },
            "preselect-horizontal": { wm.preselectSplit(vertical: false) },
            "toggle-split": { wm.toggleSplitOrientation() },
            "toggle-tabbed": { wm.toggleTabbed() },
            "toggle-stacked": { wm.toggleStacked() },
            "equalize": { wm.equalizeFocused() },
            "rotate": { wm.rotateFocused() },
            "reset-desktop": { wm.resetDesktop() },
            "float": { wm.toggleFloatFocusedApp() },
            "zoom": { wm.toggleZoom() },
            "scratchpad-send": { wm.sendToScratchpad() },
            "scratchpad-toggle": { wm.toggleScratchpad() },
            "scratchpad-release": { wm.releaseScratchpad() },
            "move-screen-next": { wm.moveToScreen(next: true) },
            "move-screen-prev": { wm.moveToScreen(next: false) },
            "move-desktop-next": { wm.moveToDesktop(next: true) },
            "move-desktop-prev": { wm.moveToDesktop(next: false) },
            "next-tab": { wm.nextTab() },
            "prev-tab": { wm.prevTab() },
            "clear": { wm.clear() },
            "switcher": { wm.showSwitcher() },
            "hints": { wm.showHints() },
            "expose": { wm.showExpose() },
            "pip": { wm.togglePiP() },
            "pip-here": { if #available(macOS 13.0, *) { PiP.shared.moveToMouse() } },
            "grab": { wm.beginKeyboardGrab() },
            "unassign": { wm.unassignCurrent() },
            "workspace-back": { wm.workspaceBack() },
            "workspace-next": { wm.cycleWorkspace(next: true) },
            "workspace-prev": { wm.cycleWorkspace(next: false) },
            "recover": { wm.recover() },
            "reload-config": { [weak self] in self?.reloadConfig() },
            "dump-layout": { wm.dumpLayout() },
            "undo": { wm.undo() },
            "doctor": { wm.doctor() },
        ]
        // i3-style numbered workspaces: ⌘⌥N switch, ⌘⌥⇧N move focused window.
        for n in 1...9 {
            actions["workspace-\(n)"] = { wm.switchToWorkspace(n) }
            actions["move-to-\(n)"] = { wm.moveToWorkspace(n) }
            actions["assign-\(n)"] = { wm.assignWorkspace(n) }
            actions["unassign-\(n)"] = { wm.unassignWorkspace(n) }
        }
        return actions
    }

    // MARK: ⌘Tab-style exposé switcher (Method A: hold to browse, release to commit)

    /// Wire the tap's callbacks once, then apply the configured combo.
    private func setupCmdTabTap() {
        let wm = windowManager
        cmdTabTap.onTrigger = { dir in
            // First press opens the overview highlighting the CURRENT workspace; only further
            // presses move the selection. (Releasing ⌘ right away thus stays put — a no-op.)
            if ExposeOverlay.isOpen { ExposeOverlay.advance(dir) }
            else { wm.showExpose(commitOnCmdRelease: true) }
        }
        cmdTabTap.onRelease = { ExposeOverlay.commitIfRelease() }
        applyExposeSwitch()
    }

    /// Enable/disable the exposé tap from `exposeSwitch` (e.g. "cmd tab"); empty = off.
    private func applyExposeSwitch() {
        let combo = Config.shared.exposeSwitch.trimmingCharacters(in: .whitespaces)
        guard !combo.isEmpty, let parsed = KeyCombo.parse(combo) else {
            cmdTabTap.disable()
            if !combo.isEmpty { NSLog("Mosaic: invalid exposeSwitch combo '\(combo)'") }
            return
        }
        // Carbon modifier mask → CGEventFlags.
        var flags: CGEventFlags = []
        if parsed.modifiers & UInt32(cmdKey)     != 0 { flags.insert(.maskCommand) }
        if parsed.modifiers & UInt32(optionKey)  != 0 { flags.insert(.maskAlternate) }
        if parsed.modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if parsed.modifiers & UInt32(shiftKey)   != 0 { flags.insert(.maskShift) }
        guard !flags.isEmpty else {   // a bare key with no modifier can't be a hold-to-commit combo
            NSLog("Mosaic: exposeSwitch '\(combo)' needs a modifier to hold"); cmdTabTap.disable(); return
        }
        cmdTabTap.disable()   // re-arm cleanly with the new combo
        cmdTabTap.enable(keyCode: Int64(parsed.keyCode), modMask: flags)
    }

    private func registerHotkeys() {
        guard let hk = hotkeys else { return }
        hk.unregisterAll()
        let actions = makeActions()

        var tapBindings: [ComboTap.Binding] = []
        for (action, combo) in Config.shared.keybindings {
            // A binding value may hold several combos, comma-separated ("ctrl alt k, ctrl alt up"),
            // so one action can fire from more than one shortcut. An empty/blank value = disabled.
            let combos = combo.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if combos.isEmpty { continue }
            guard let run = actions[action] else {
                NSLog("Mosaic: unknown action '\(action)' in keybindings"); continue
            }
            for one in combos {
                guard let parsed = KeyCombo.parse(one) else {
                    NSLog("Mosaic: invalid key combo '\(one)' for '\(action)'"); continue
                }
                if tapRoutedActions.contains(action) {
                    // Route through the CGEventTap so it fires BEFORE macOS' reserved shortcut (and is
                    // swallowed from apps). Carbon RegisterEventHotKey would lose the race to the system.
                    tapBindings.append(.init(keyCode: Int64(parsed.keyCode),
                                             mods: Self.cgFlags(fromCarbon: parsed.modifiers), action: run))
                } else {
                    hk.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers, action: run)
                }
            }
        }
        comboTap.setBindings(tapBindings)   // empty list tears the tap down
    }

    /// Carbon modifier mask (⌘⌥⌃⇧ from `KeyCombo.parse`) → `CGEventFlags` for the event tap.
    private static func cgFlags(fromCarbon mods: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mods & UInt32(cmdKey)     != 0 { flags.insert(.maskCommand) }
        if mods & UInt32(optionKey)  != 0 { flags.insert(.maskAlternate) }
        if mods & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if mods & UInt32(shiftKey)   != 0 { flags.insert(.maskShift) }
        return flags
    }

    /// Watch config.json and hot-reload it on save. Editors save atomically (write a temp
    /// file then rename over the original), so on a rename/delete we re-arm on the new inode.
    private func startWatchingConfig() {
        configWatch?.cancel()
        let fd = open(Config.shared.configURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let flags = src.data
            self.scheduleConfigReload()
            if flags.contains(.rename) || flags.contains(.delete) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.startWatchingConfig()   // re-arm on the replacement file
                }
            }
        }
        src.setCancelHandler { close(fd) }
        configWatch = src
        src.resume()
    }

    /// Debounce a burst of file events into a single reload.
    private func scheduleConfigReload() {
        configReloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadConfig() }
        configReloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    @objc private func reloadConfig() {
        Config.shared.load()
        windowManager.reloadConfig()
        registerHotkeys()   // unregisters old, applies new bindings
        applyExposeSwitch() // re-arm the ⌘Tab tap with the (possibly changed) combo
        rebuildMenu()       // refresh combos shown in the menu
        updateTrackpadGestures()   // (re)arm or disarm the trackpad swipe on config change
        updateWindowDrag()         // (re)configure the drag-any-window chord
        presentConfigIssues()   // warn if the edited config has problems
        NSLog("Mosaic: config reloaded")
    }
}

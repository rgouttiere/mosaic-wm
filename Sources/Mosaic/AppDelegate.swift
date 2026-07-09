import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    let windowManager = WindowManager()
    private var hotkeys: HotkeyManager?
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityIfNeeded()
        setupStatusItem()
        windowManager.onWorkspaceChanged = { [weak self] number in
            self?.statusItem.button?.title = number.map { "▦\($0)" } ?? "▦"
        }
        setupHotkeys()
        windowManager.startObserving()
        presentConfigIssues()   // surface any problems from the startup config load
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
        alert.messageText = "config.json : \(issues.count) problème\(issues.count > 1 ? "s" : "")"
        alert.informativeText = issues.map { "• \($0)" }.joined(separator: "\n")
            + "\n\nLes valeurs valides sont appliquées ; le reste reste au défaut."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Ouvrir config.json")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(Config.shared.configURL)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowManager.resetAllOpacity()
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
            ("cycle-mode", "Cycle layout: Columns → Grouped → Tabbed", #selector(cycleMode)),
            ("manage-all", "Manage all desktops (toggle)", #selector(toggleManageAll)),
        ]
        for entry in clickable {
            let combo = MenuFormat.combo(bindings[entry.action])
            menu.addItem(withTitle: "\(entry.title)\(combo)", action: entry.selector, keyEquivalent: "")
        }

        // Keyboard-only actions (directional): show the modifiers + "arrows".
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Raccourcis clavier", action: nil, keyEquivalent: "")
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
    @objc private func assignFromMenu(_ sender: NSMenuItem) { windowManager.assignWorkspace(sender.tag) }
    @objc private func clearLayout() { windowManager.clear() }
    @objc private func openConfig() { NSWorkspace.shared.open(Config.shared.configURL) }
    @objc private func dumpLayout() { windowManager.dumpLayout() }

    // MARK: Global hotkeys

    private func setupHotkeys() {
        hotkeys = HotkeyManager()
        registerHotkeys()
    }

    private func registerHotkeys() {
        guard let hk = hotkeys else { return }
        hk.unregisterAll()
        let wm = windowManager

        // action name (matches config keybindings) → what it does.
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
            "move-screen-next": { wm.moveToScreen(next: true) },
            "move-screen-prev": { wm.moveToScreen(next: false) },
            "move-desktop-next": { wm.moveToDesktop(next: true) },
            "move-desktop-prev": { wm.moveToDesktop(next: false) },
            "next-tab": { wm.nextTab() },
            "prev-tab": { wm.prevTab() },
            "clear": { wm.clear() },
        ]
        // i3-style numbered workspaces: ⌘⌥N switch, ⌘⌥⇧N move focused window.
        for n in 1...9 {
            actions["workspace-\(n)"] = { wm.switchToWorkspace(n) }
            actions["move-to-\(n)"] = { wm.moveToWorkspace(n) }
            actions["assign-\(n)"] = { wm.assignWorkspace(n) }
        }

        for (action, combo) in Config.shared.keybindings {
            guard let run = actions[action] else {
                NSLog("Mosaic: unknown action '\(action)' in keybindings"); continue
            }
            guard let parsed = KeyCombo.parse(combo) else {
                NSLog("Mosaic: invalid key combo '\(combo)' for '\(action)'"); continue
            }
            hk.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers, action: run)
        }
    }

    @objc private func reloadConfig() {
        Config.shared.load()
        windowManager.reloadConfig()
        registerHotkeys()   // unregisters old, applies new bindings
        rebuildMenu()       // refresh combos shown in the menu
        presentConfigIssues()   // warn if the edited config has problems
        NSLog("Mosaic: config reloaded")
    }
}

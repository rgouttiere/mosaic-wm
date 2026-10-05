import AppKit

/// Drag something (a file, a tab, some text) up to the top edge of any screen and a list of every
/// workspace drops down at the top-left; rest on one for `dragSwitchDwell` seconds — its row fills
/// as it counts down — and Mosaic switches to it and carries the pointer, still dragging, onto its
/// screen. Let go, or move away, and nothing happens. The problem it solves: emulated workspaces
/// cannot be reached mid-drag, and the bar only shows the workspaces of its own screen.
final class DragSwitch {
    weak var wm: WindowManager?
    private let menu = DragSwitchMenu()
    private var monitors: [Any] = []
    private var dragStartCount = 0
    private var dwellWork: DispatchWorkItem?
    private var armedRow: Int?
    private var lastSwitchAt = Date.distantPast

    func start() {
        guard monitors.isEmpty else { return }
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dragStartCount = NSPasteboard(name: .drag).changeCount
        }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in self?.dragged() }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.end() }
        monitors = [down, drag, up].compactMap { $0 }
    }

    /// A content drag is one that wrote the drag pasteboard since the button went down — a window
    /// being moved or a text selection being extended does not.
    private var contentDragActive: Bool { NSPasteboard(name: .drag).changeCount != dragStartCount }

    private func dragged() {
        guard Config.shared.dragSwitch, let wm, contentDragActive else { return }
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return }
        let bar = max(Config.shared.externalBarTop, screen.frame.maxY - screen.visibleFrame.maxY)
        let nearTop = p.y >= screen.frame.maxY - max(bar, 24) - 4
        if !menu.isVisible {
            guard nearTop, Date().timeIntervalSince(lastSwitchAt) > 1 else { return }
            menu.show(rows: wm.dragSwitchRows(), on: screen, below: bar)
            return
        }
        // Keep the list while the pointer is on it or still in the top band; drop it otherwise.
        let keep = menu.frame.insetBy(dx: -24, dy: -24).contains(p) || nearTop
        guard keep else { cancel(); return }
        let row = menu.rowIndex(at: p)
        guard row != armedRow else { return }
        armedRow = row
        dwellWork?.cancel(); dwellWork = nil
        let dwell = max(0.3, Config.shared.dragSwitchDwell)
        menu.setHovered(row, dwell: dwell)
        guard let row, menu.rows.indices.contains(row) else { return }
        let n = menu.rows[row].number
        let work = DispatchWorkItem { [weak self] in self?.fire(n) }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    private func fire(_ n: Int) {
        guard let wm, contentDragActive, NSEvent.pressedMouseButtons & 1 == 1 else { cancel(); return }
        Log.event("drag switch → ws\(n)")
        lastSwitchAt = Date()
        cancel()
        wm.switchToWorkspace(n)
        // switchToWorkspace warps the pointer when `warpMouseOnSwitch` is on; make sure it lands on
        // the destination screen either way — that is the whole point of the gesture.
        if let screen = wm.homeScreen(forWorkspace: n), !NSMouseInRect(NSEvent.mouseLocation, screen.frame, false) {
            wm.warpMouseToWorkspace(UInt64(n), on: screen, force: true)
        }
    }

    private func end() { cancel() }

    private func cancel() {
        dwellWork?.cancel(); dwellWork = nil
        armedRow = nil
        if menu.isVisible { menu.hide() }
    }
}

extension WindowManager {
    /// Every live workspace, in number order, with its name and the icons of its apps.
    func dragSwitchRows() -> [DragSwitchMenu.Row] {
        let shown = Set(shownOnDisplay.values)
        return spaces.keys.compactMap { workspaceNumber(for: $0) }.sorted().map { n in
            var icons: [NSImage] = [], seen = Set<String>()
            spaces[UInt64(n)]?.root?.forEachLeaf { leaf in
                guard let w = leaf.window, let icon = w.app.icon else { return }
                let key = w.app.bundleIdentifier ?? w.appName
                if seen.insert(key).inserted { icons.append(icon) }
            }
            return .init(number: n, name: Config.shared.workspaceNames[n] ?? "Workspace \(n)", icons: icons, shown: shown.contains(UInt64(n)))
        }
    }
}

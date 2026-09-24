import AppKit

/// Keyboard grab mode (#3): a 100%-keyboard twin of the drag. `grab` picks up the focused window;
/// hjkl / arrows move a target highlight tile-to-tile; ⏎ tabs the grabbed window into the target;
/// ⇧+hjkl splits it on that side of the target; Esc cancels. Reuses dropInto — same insert as a drag.
extension WindowManager {

    /// Pick up the focused window and enter grab mode. No-op if there's nothing else to place it against.
    func beginKeyboardGrab() {
        checkSpaceChange()
        endGrabKeyCapture()   // idempotent — a second press just restarts cleanly
        guard grabbedLeaf == nil, let focused, let screen = activeScreen, let root else { return }
        var others: [Container] = []
        root.forEachVisibleLeaf { if $0 !== focused { others.append($0) } }
        guard !others.isEmpty else { return }   // alone on this desktop → nothing to grab onto

        grabbedLeaf = focused
        grabTarget = neighborLeaf(from: focused, .right) ?? neighborLeaf(from: focused, .left)
                  ?? neighborLeaf(from: focused, .down)  ?? neighborLeaf(from: focused, .up) ?? others.first
        tabDragging = true    // freeze focus-sync / space-follow while grabbing
        startGrabKeyCapture(on: screen)
        updateGrabHighlight(zone: .center)
    }

    func grabNavigate(_ dir: Direction) {
        guard let cur = grabTarget else { return }
        var next = neighborLeaf(from: cur, dir)
        if next === grabbedLeaf { next = next.flatMap { neighborLeaf(from: $0, dir) } }   // skip over ourselves
        if let n = next, n !== grabbedLeaf { grabTarget = n; updateGrabHighlight(zone: .center) }
    }

    func grabCommit(_ zone: DropZone) {
        guard let g = grabbedLeaf, let t = grabTarget else { cancelKeyboardGrab(); return }
        endGrabKeyCapture()
        grabbedLeaf = nil; grabTarget = nil; tabDragging = false
        dropInto(g, onto: t, zone: zone)   // same insert as a drag drop
    }

    func cancelKeyboardGrab() {
        endGrabKeyCapture()
        TabDragGhost.shared.hide()
        dropHighlight.hide()
        grabbedLeaf = nil; grabTarget = nil; tabDragging = false
    }

    private func updateGrabHighlight(zone: DropZone) {
        guard let leaf = grabTarget, let frame = leaf.window?.frame else { dropHighlight.hide(); return }
        let f = Geometry.flip(frame)
        dropHighlight.show(tile: f, zoneRect: zoneRect(zone, in: f))
        if let g = grabbedLeaf {   // a floating reminder of what's being moved, over the target
            TabDragGhost.shared.show(g.title, at: NSPoint(x: f.midX, y: f.midY))
        }
    }

    private func startGrabKeyCapture(on screen: NSScreen) {
        let panel = GrabKeyPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
        panel.collectionBehavior = [.ignoresCycle, .moveToActiveSpace]
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        grabKeyWindow = panel

        grabMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
            guard let self, self.grabbedLeaf != nil else { return e }
            if e.type == .leftMouseDown { self.cancelKeyboardGrab(); return nil }   // click anywhere = cancel
            let shift = e.modifierFlags.contains(.shift)
            switch e.keyCode {
            case 4:  shift ? self.grabCommit(.left)   : self.grabNavigate(.left);  return nil   // h / ⇧H
            case 37: shift ? self.grabCommit(.right)  : self.grabNavigate(.right); return nil   // l / ⇧L
            case 38: shift ? self.grabCommit(.bottom) : self.grabNavigate(.down);  return nil   // j / ⇧J
            case 40: shift ? self.grabCommit(.top)    : self.grabNavigate(.up);    return nil   // k / ⇧K
            case 123: self.grabNavigate(.left);  return nil    // ←
            case 124: self.grabNavigate(.right); return nil    // →
            case 125: self.grabNavigate(.down);  return nil    // ↓
            case 126: self.grabNavigate(.up);    return nil    // ↑
            case 36, 76: self.grabCommit(.center); return nil  // ⏎ = tab into target
            case 53: self.cancelKeyboardGrab(); return nil     // esc
            default: return nil                                // swallow everything else (modal)
            }
        }
    }

    private func endGrabKeyCapture() {
        if let m = grabMonitor { NSEvent.removeMonitor(m); grabMonitor = nil }
        grabKeyWindow?.orderOut(nil); grabKeyWindow = nil
        TabDragGhost.shared.hide()
    }
}

/// Borderless panels don't become key by default — grab mode needs keys, so force it.
final class GrabKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

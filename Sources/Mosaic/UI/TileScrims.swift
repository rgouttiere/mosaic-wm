import AppKit

/// Shades every visible tile except the focused one: a black, click-through sheet over each inactive
/// window, at `1 − inactiveOpacity`. This is the public-API form of the old window-alpha dimming.
/// The window server stopped honouring `CGSSetWindowAlpha` on macOS 27 (the symbol resolves, the
/// call returns success, the window keeps alpha 1.0 — measured), so the effect moved to our side of
/// the glass. Same construction as the borders — borderless, ignores the mouse — one window level
/// under them, so the hairline stays crisp on top of the shade.
///
/// Keyed by window id rather than pooled by index: a tile keeps its sheet across renders, so a focus
/// change fades exactly one sheet out and one in, in place. Nothing travels.
final class TileScrims {
    private var sheets: [CGWindowID: NSWindow] = [:]
    private var touched = Set<CGWindowID>()

    func begin() { touched.removeAll(keepingCapacity: true) }

    /// Shade the window `id` whose frame is `cocoaFrame`, at `darkness` (0 = none, 1 = black).
    func cover(_ id: CGWindowID, frame cocoaFrame: NSRect, darkness: CGFloat) {
        guard darkness > 0.005, cocoaFrame.width > 2, cocoaFrame.height > 2 else { return }
        touched.insert(id)
        let w: NSWindow
        if let existing = sheets[id] { w = existing } else { w = makeSheet(); sheets[id] = w }
        if w.frame != cocoaFrame { w.setFrame(cocoaFrame, display: false) }   // steady tile: no re-frame
        w.contentView?.layer?.cornerRadius = CGFloat(Config.shared.borderCornerRadius)
        if w.isVisible {
            if abs(w.alphaValue - darkness) > 0.01 { w.alphaValue = darkness }   // config reload
        } else if reduceMotion {
            w.alphaValue = darkness
            w.orderFront(nil)
        } else {
            w.alphaValue = 0
            w.orderFront(nil)
            fade(w, to: darkness)
        }
    }

    /// Fade out and drop every sheet that was not covered this pass.
    func end() {
        for (id, w) in sheets where !touched.contains(id) {
            sheets[id] = nil
            if reduceMotion { w.orderOut(nil) } else { fade(w, to: 0) { w.orderOut(nil) } }
        }
    }

    /// `animated`: fade out in place (a zoom), else drop instantly (a switch must not leave ghosts).
    func hideAll(animated: Bool = false) {
        let fade = animated && !reduceMotion
        for w in sheets.values {
            if fade { self.fade(w, to: 0) { w.orderOut(nil) } } else { w.orderOut(nil) }
        }
        sheets.removeAll()
        touched.removeAll()
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func fade(_ w: NSWindow, to alpha: CGFloat, then: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            w.animator().alphaValue = alpha
        }, completionHandler: then)
    }

    private func makeSheet() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        // One level under the other overlays (borders, strips, letterbox, halo all sit at
        // .floating), still above every app window: the hairline and the tab bar stay crisp on top
        // of the shade whatever order the windows were shown in — a sheet created on a focus change
        // would otherwise land above its tile's border until the next full render re-fronted it.
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.ignoresCycle, .stationary]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.layer?.masksToBounds = true
        v.autoresizingMask = [.width, .height]
        win.contentView = v
        return win
    }
}

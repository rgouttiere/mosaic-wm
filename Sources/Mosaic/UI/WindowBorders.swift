import AppKit

/// A dim accent hairline around every visible tiled window EXCEPT the focused one (which keeps its
/// bright FocusIndicator + halo). Turns the whole tiling into a cohesive "outlined" layout. Opt-in
/// via `borderInactive`. A reused pool, like LetterboxFill: `begin` → `border(around:)` per window
/// → `end` hides the leftovers. Borderless, click-through, `.floating` so the stroke sits over each
/// window's edge just like the focus border.
final class WindowBorders {
    private var pool: [NSWindow] = []
    private var used = 0
    private var stale = false   // set by invalidateAll: the next pass redraws every border

    func begin() { used = 0 }

    /// Force a redraw of every border on the next pass — the colour, width or radius changed.
    func invalidateAll() { stale = true }

    /// Draw a dim border framing `cocoaFrame` (a window's frame, Cocoa coords). `dim` fades it
    /// further, for tiles on a monitor that doesn't have keyboard focus.
    func border(around cocoaFrame: NSRect, dim: Bool = false) {
        guard cocoaFrame.width > 2, cocoaFrame.height > 2 else { return }
        let w: NSWindow
        if used < pool.count { w = pool[used] } else { w = makeBorder(); pool.append(w) }
        used += 1
        let view = w.contentView as? InactiveBorderView
        // Same frame, same dim, already up: nothing to do. During a live resize only the two
        // tiles at the divider move, yet this ran for every tile on every shown monitor at the
        // live cadence — a setFrame, a full redraw and a window-server ordering per border, per
        // frame. Slots are index-based and the tile order is stable through a drag, so slot i is
        // the same tile from one pass to the next.
        if !stale, w.isVisible, w.frame == cocoaFrame, view?.dimmed == dim { return }
        w.setFrame(cocoaFrame, display: false)
        w.contentView?.frame = NSRect(origin: .zero, size: cocoaFrame.size)
        view?.dimmed = dim
        w.contentView?.needsDisplay = true   // pick up size / config-colour changes
        // A border that was not on screen fades in, in place (a switch hides them all first, so the
        // whole set appears as one). One already showing just moves — a live resize never fades.
        if w.isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            w.alphaValue = 1
            w.orderFront(nil)
        } else {
            w.alphaValue = 0
            w.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; w.animator().alphaValue = 1 }
        }
    }

    func end() {
        for i in used..<pool.count { pool[i].orderOut(nil) }
        stale = false
    }
    /// `animated`: fade out in place (a zoom), else drop instantly (a switch must not leave ghosts).
    func hideAll(animated: Bool = false) {
        used = 0
        let fade = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for w in pool where w.isVisible {
            if fade { NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.1; w.animator().alphaValue = 0 }, completionHandler: { w.orderOut(nil) }) }
            else { w.orderOut(nil) }
        }
    }

    private func makeBorder() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.ignoresCycle, .stationary]
        win.contentView = InactiveBorderView()
        return win
    }
}

private final class InactiveBorderView: NSView {
    var dimmed = false
    override func draw(_ dirtyRect: NSRect) {
        let width = max(1, CGFloat(Config.shared.borderWidth))   // a hair thinner than the focus line
        let radius = CGFloat(Config.shared.borderCornerRadius)
        let op = Config.shared.inactiveBorderOpacity
        Config.shared.borderNSColor.withAlphaComponent(dimmed ? op * Config.shared.inactiveMonitorDim : op).setStroke()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
        p.lineWidth = width
        p.stroke()
    }
}

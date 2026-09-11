import AppKit

/// A dim accent hairline around every visible tiled window EXCEPT the focused one (which keeps its
/// bright FocusIndicator + halo). Turns the whole tiling into a cohesive "outlined" layout. Opt-in
/// via `borderInactive`. A reused pool, like LetterboxFill: `begin` → `border(around:)` per window
/// → `end` hides the leftovers. Borderless, click-through, `.floating` so the stroke sits over each
/// window's edge just like the focus border.
final class WindowBorders {
    private var pool: [NSWindow] = []
    private var used = 0

    func begin() { used = 0 }

    /// Draw a dim border framing `cocoaFrame` (a window's frame, Cocoa coords).
    func border(around cocoaFrame: NSRect) {
        guard cocoaFrame.width > 2, cocoaFrame.height > 2 else { return }
        let w: NSWindow
        if used < pool.count { w = pool[used] } else { w = makeBorder(); pool.append(w) }
        used += 1
        w.setFrame(cocoaFrame, display: false)
        w.contentView?.frame = NSRect(origin: .zero, size: cocoaFrame.size)
        w.contentView?.needsDisplay = true   // pick up size / config-colour changes
        w.orderFront(nil)
    }

    func end() { for i in used..<pool.count { pool[i].orderOut(nil) } }
    func hideAll() { for w in pool { w.orderOut(nil) }; used = 0 }

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
    override func draw(_ dirtyRect: NSRect) {
        let width = max(1, CGFloat(Config.shared.borderWidth) + 1)   // a touch thicker than the focus line
        let radius = CGFloat(Config.shared.borderCornerRadius)
        Config.shared.borderNSColor.withAlphaComponent(0.32).setStroke()   // quiet, so the focused one still leads
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
        p.lineWidth = width
        p.stroke()
    }
}

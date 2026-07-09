import AppKit

/// A translucent highlight shown over the window/group under the cursor while dragging
/// a tab, so you can see where it will land.
final class DropHighlight {
    private let window: FillWindow

    init() {
        window = FillWindow()
    }

    func show(around cocoaFrame: NSRect) {
        window.setFrame(cocoaFrame, display: true)
        window.contentView?.frame = NSRect(origin: .zero, size: cocoaFrame.size)
        window.contentView?.needsDisplay = true
        window.orderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }
}

private final class FillWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating   // above windows, below the drag ghost (.popUpMenu)
        // NOT canJoinAllSpaces: it must stay on the desktop it's shown on (never leak
        // onto full-screen Spaces), and macOS hides it the instant the Space changes.
        collectionBehavior = [.ignoresCycle, .stationary]
        contentView = FillView()
    }
}

private final class FillView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let color = Config.color(from: Config.shared.dropHighlightColor)
        let radius = CGFloat(Config.shared.borderCornerRadius)
        let rect = bounds.insetBy(dx: 2, dy: 2)
        color.withAlphaComponent(0.18).setFill()
        color.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.fill()
        path.lineWidth = 3
        path.stroke()
    }
}

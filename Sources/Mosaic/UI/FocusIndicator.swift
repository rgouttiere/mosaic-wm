import AppKit

/// A borderless overlay that draws a colored border around the focused window, so
/// keyboard-driven operations (group, move, toggle) have an obvious target.
final class FocusIndicator {
    private let window: BorderWindow

    init() {
        window = BorderWindow()
    }

    /// Show the border around `cocoaFrame` (Cocoa, bottom-left coords). `preselect` (i3):
    /// nil = none, true = a split armed below, false = armed to the right — draws an
    /// accent fill on that half so you see where the next window will land.
    func show(around cocoaFrame: NSRect, preselect: Bool? = nil) {
        window.setFrame(cocoaFrame, display: true)
        window.contentView?.frame = NSRect(origin: .zero, size: cocoaFrame.size)
        (window.contentView as? BorderView)?.preselect = preselect
        window.contentView?.needsDisplay = true   // pick up config color/width changes
        window.orderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }
}

private final class BorderWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true   // never intercept clicks
        level = .floating
        // NOT canJoinAllSpaces: it must belong to the desktop it's shown on, so macOS
        // hides it the instant you switch desktops (no lingering rectangle). orderFront
        // moves it to the current desktop when we render a managed one.
        collectionBehavior = [.ignoresCycle, .stationary]
        contentView = BorderView()
    }
}

private final class BorderView: NSView {
    /// nil = no preselect; true = split armed below; false = armed to the right.
    var preselect: Bool?

    override func draw(_ dirtyRect: NSRect) {
        let thickness = CGFloat(Config.shared.borderWidth)
        let radius = CGFloat(Config.shared.borderCornerRadius)
        let accent = Config.shared.borderNSColor

        // Preselect cue: tint the half where the next window will land (Cocoa y=0 = bottom).
        if let ps = preselect {
            accent.withAlphaComponent(0.28).setFill()
            let half = ps ? NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2)
                          : NSRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)
            NSBezierPath(rect: half.insetBy(dx: thickness, dy: thickness)).fill()
        }

        accent.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: thickness / 2, dy: thickness / 2),
                                xRadius: radius, yRadius: radius)
        path.lineWidth = thickness
        path.stroke()
    }
}

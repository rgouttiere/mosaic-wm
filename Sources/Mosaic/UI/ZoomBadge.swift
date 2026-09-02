import AppKit

/// A small persistent pill shown while the active workspace is in monocle/zoom (⌘⌥⏎). The zoomed
/// tile fills the screen and hides its siblings + tab strips, so without a cue it's easy to forget
/// you're zoomed. Borderless passive overlay — same pattern as `FocusIndicator` / `WorkspaceHUD`.
final class ZoomBadge {
    private let window: NSWindow
    private let view = ZoomBadgeView()

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 110, height: 32),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true   // never intercept clicks
        // moveToActiveSpace so it lands on the desktop actually being looked at (two workspaces can
        // share a display), like the focus border and tab bars — never stranded on the old Space.
        window.collectionBehavior = [.ignoresCycle, .moveToActiveSpace]
        window.contentView = view
    }

    /// Show the badge in the top-right corner of `screen`. Idempotent — cheap to call each render.
    func show(on screen: NSScreen) {
        let s = view.intrinsicContentSize
        window.setContentSize(s)
        view.needsDisplay = true   // pick up config accent-colour changes
        let f = screen.visibleFrame
        let m: CGFloat = 12
        window.setFrameOrigin(NSPoint(x: f.maxX - s.width - m, y: f.maxY - s.height - m))
        window.orderFrontRegardless()
    }

    func hide() { window.orderOut(nil) }
}

private final class ZoomBadgeView: NSView {
    private let label = "⛶ ZOOM"
    private var attrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: Config.shared.borderNSColor]
    }

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize {
        let ts = (label as NSString).size(withAttributes: attrs)
        return NSSize(width: ts.width + 26, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = Config.shared.borderNSColor
        // Dark pill so the accent text reads over any window content underneath.
        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        // Accent hairline border.
        accent.setStroke()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                             xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        p.lineWidth = 1.5
        p.stroke()
        // Centered label.
        let str = label as NSString
        let ts = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - ts.height / 2), withAttributes: attrs)
    }
}

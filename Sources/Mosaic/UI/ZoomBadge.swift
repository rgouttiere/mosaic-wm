import AppKit

/// A small persistent pill shown while the active workspace is in monocle/zoom (⌘⌥⏎). The zoomed
/// tile fills the screen and hides its siblings + tab strips, so without a cue it's easy to forget
/// you're zoomed. Borderless passive overlay — same pattern as `FocusIndicator` / `WorkspaceHUD`.
final class ZoomBadge {
    private let window: NSWindow
    private let view = ZoomBadgeView()
    private let effect = NSVisualEffectView()   // frosted pill, matching the other overlays

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 110, height: 32),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.ignoresMouseEvents = true   // never intercept clicks
        // moveToActiveSpace so it lands on the desktop actually being looked at (two workspaces can
        // share a display), like the focus border and tab bars — never stranded on the old Space.
        window.collectionBehavior = [.ignoresCycle, .moveToActiveSpace]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)
        window.contentView = effect
    }

    /// Show the badge in the top-right corner of `screen`. Idempotent — cheap to call each render.
    func show(on screen: NSScreen) {
        let s = view.intrinsicContentSize
        window.setContentSize(s)
        effect.frame = NSRect(origin: .zero, size: s)
        effect.layer?.cornerRadius = s.height / 2   // pill
        effect.layer?.masksToBounds = true
        view.frame = effect.bounds
        view.needsDisplay = true   // pick up config accent-colour changes
        let f = screen.visibleFrame
        let m: CGFloat = 12
        window.setFrameOrigin(NSPoint(x: f.maxX - s.width - m, y: f.maxY - s.height - m))
        let fadeIn = !window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.alphaValue = fadeIn ? 0 : 1
        window.orderFrontRegardless()
        if fadeIn {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                window.animator().alphaValue = 1
            }
        }
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
        // Subtle tint over the frosted pill (the blur is the window's NSVisualEffectView).
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        // Neon: accent border + label with an accent glow.
        NSGraphicsContext.saveGraphicsState()
        let neon = NSShadow()
        neon.shadowColor = accent.withAlphaComponent(0.9); neon.shadowBlurRadius = 6; neon.shadowOffset = .zero
        neon.set()
        accent.setStroke()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                             xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        p.lineWidth = 1.5
        p.stroke(); p.stroke()
        let str = label as NSString
        let ts = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - ts.height / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}

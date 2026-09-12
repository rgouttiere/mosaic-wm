import AppKit

/// A frosted accent highlight shown over the window/group half where a dragged tab will land, so
/// the drop target (and, for an edge drop, which side) reads at a glance. The window is sized to the
/// exact landing slice by `updateDropHighlight` (full tile = tab, a half = split).
final class DropHighlight {
    private let window: FillWindow

    init() {
        window = FillWindow()
    }

    func show(around cocoaFrame: NSRect) {
        window.setFrame(cocoaFrame, display: true)
        window.layout(to: cocoaFrame.size)
        window.orderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }
}

private final class FillWindow: NSWindow {
    /// Frosted backdrop — blurs the target area so it reads as "about to be replaced".
    private let effect = NSVisualEffectView()
    /// Accent tint + crisp border, drawn on top of the blur.
    private let overlay = FillView()

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
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        let container = NSView()
        container.addSubview(effect)
        container.addSubview(overlay)
        contentView = container
    }

    /// Inset the frosted panel + tint/border to match, with the theme corner radius.
    func layout(to size: NSSize) {
        let full = NSRect(origin: .zero, size: size)
        contentView?.frame = full
        effect.frame = full.insetBy(dx: 2, dy: 2)
        effect.layer?.cornerRadius = CGFloat(Config.shared.borderCornerRadius)
        effect.layer?.masksToBounds = true
        overlay.frame = full
        overlay.needsDisplay = true
    }
}

private final class FillView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let color = Config.color(from: Config.shared.dropHighlightColor)
        let radius = CGFloat(Config.shared.borderCornerRadius)
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        color.withAlphaComponent(0.22).setFill()   // accent wash over the frosted blur
        path.fill()
        color.withAlphaComponent(0.95).setStroke()
        path.lineWidth = 2.5
        path.stroke()
    }
}

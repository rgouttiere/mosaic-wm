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
        // orderFrontRegardless (like the tab bars) so a .stationary window actually
        // migrates to the current Space — orderFront leaves it stuck on its old Space,
        // which shows the border on the wrong workspace when two share a display.
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    /// One-shot glow around the focused window (e.g. after a workspace switch) to draw the
    /// eye to what's now focused. Ramps a translucent halo down to nothing over ~0.25s.
    func pulse() {
        guard Config.shared.focusPulseWidth > 0,   // 0 = disabled
              let v = window.contentView as? BorderView, window.isVisible else { return }
        let duration = max(0.05, Config.shared.focusPulseDuration)
        let steps = max(6, Int(duration / 0.024))
        v.pulse = 1
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * Double(i) / Double(steps)) { [weak v] in
                v?.pulse = 1 - CGFloat(i) / CGFloat(steps)   // ease-out
            }
        }
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
        // moveToActiveSpace: the border follows to whatever Space is active when we order
        // it front — so it lands on the desktop you're actually looking at, even when two
        // workspaces share a display or you switch with ⌃←/→. (.stationary kept it pinned
        // to its original Space, which left the border on the previous workspace.)
        collectionBehavior = [.ignoresCycle, .moveToActiveSpace]
        contentView = BorderView()
    }
}

private final class BorderView: NSView {
    /// nil = no preselect; true = split armed below; false = armed to the right.
    var preselect: Bool?
    /// 0 = none, 1 = full one-shot glow (see FocusIndicator.pulse()).
    var pulse: CGFloat = 0 { didSet { needsDisplay = true } }

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

        // Border — thickened + brightened for a one-shot pulse, drawn INSET by its own
        // half-width so a wide pulse never clips against the window bounds.
        let lineWidth = thickness + pulse * Config.shared.focusPulseWidth
        let stroke = pulse > 0 ? (accent.blended(withFraction: 0.45 * pulse, of: .white) ?? accent) : accent
        stroke.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                                xRadius: radius, yRadius: radius)
        path.lineWidth = lineWidth
        path.stroke()
    }
}

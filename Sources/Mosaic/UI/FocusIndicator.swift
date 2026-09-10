import AppKit
import QuartzCore

/// A borderless overlay that draws a colored border around the focused window, so
/// keyboard-driven operations (group, move, toggle) have an obvious target. A soft accent halo
/// (config `focusGlowRadius`) makes the focused window read as "lit up" above its neighbours.
final class FocusIndicator {
    private let window: BorderWindow
    private var lastCocoaFrame: NSRect = .zero

    init() {
        window = BorderWindow()
    }

    /// Show the border around `cocoaFrame` (Cocoa, bottom-left coords). `preselect` (i3):
    /// nil = none, true = a split armed below, false = armed to the right — draws an
    /// accent fill on that half so you see where the next window will land.
    func show(around cocoaFrame: NSRect, preselect: Bool? = nil) {
        // Grow the overlay by the halo radius on every side so the glow has room to bloom
        // OUTSIDE the window edge instead of clipping at its bounds.
        let g = CGFloat(max(0, Config.shared.focusGlowRadius))
        let outer = cocoaFrame.insetBy(dx: -g, dy: -g)

        // Fade the border in when focus JUMPS to a different window (not on a mere resize of the
        // same one) — an in-place cross-fade, never a travelling rectangle. Honour Reduce Motion.
        let jumped = !window.isVisible
            || abs(cocoaFrame.minX - lastCocoaFrame.minX) > 8
            || abs(cocoaFrame.minY - lastCocoaFrame.minY) > 8
        let animate = Config.shared.focusGlowFade && jumped
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        lastCocoaFrame = cocoaFrame

        window.setFrame(outer, display: true)
        window.contentView?.frame = NSRect(origin: .zero, size: outer.size)
        if let v = window.contentView as? BorderView { v.glowInset = g; v.preselect = preselect }
        window.contentView?.needsDisplay = true   // pick up config color/width changes
        // orderFrontRegardless (like the tab bars) so a .stationary window actually
        // migrates to the current Space — orderFront leaves it stuck on its old Space,
        // which shows the border on the wrong workspace when two share a display.
        if animate {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
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
    /// Padding between the view bounds and the true window edge — room for the halo to bloom.
    var glowInset: CGFloat = 0 { didSet { needsDisplay = true } }
    /// 0 = none, 1 = full one-shot glow (see FocusIndicator.pulse()).
    var pulse: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let thickness = CGFloat(Config.shared.borderWidth)
        let radius = CGFloat(Config.shared.borderCornerRadius)
        let accent = Config.shared.borderNSColor
        let edge = bounds.insetBy(dx: glowInset, dy: glowInset)   // the actual window rectangle

        // Preselect cue: tint the half where the next window will land (Cocoa y=0 = bottom).
        if let ps = preselect {
            accent.withAlphaComponent(0.28).setFill()
            let half = ps ? NSRect(x: edge.minX, y: edge.minY, width: edge.width, height: edge.height / 2)
                          : NSRect(x: edge.midX, y: edge.minY, width: edge.width / 2, height: edge.height)
            NSBezierPath(rect: half.insetBy(dx: thickness, dy: thickness)).fill()
        }

        // Border — thickened + brightened for a one-shot pulse, drawn INSET by its own
        // half-width so a wide pulse never clips against the window edge.
        let lineWidth = thickness + pulse * Config.shared.focusPulseWidth
        let path = NSBezierPath(roundedRect: edge.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                                xRadius: radius, yRadius: radius)
        path.lineWidth = lineWidth

        // Soft accent halo: cast the border's own shadow (no offset) so it blooms outward into the
        // padding. Two passes deepen the bloom. Skipped entirely when the halo is off (inset == 0).
        if glowInset > 0 {
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = accent.withAlphaComponent(0.85)
            sh.shadowBlurRadius = glowInset
            sh.shadowOffset = .zero
            sh.set()
            accent.setStroke()
            path.stroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Crisp border on top (brightened during a one-shot pulse).
        let stroke = pulse > 0 ? (accent.blended(withFraction: 0.45 * pulse, of: .white) ?? accent) : accent
        stroke.setStroke()
        path.stroke()
    }
}

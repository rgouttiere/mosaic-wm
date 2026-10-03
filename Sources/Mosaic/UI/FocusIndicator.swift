import AppKit
import QuartzCore

/// A borderless overlay that draws a colored border around the focused window, so
/// keyboard-driven operations (group, move, toggle) have an obvious target. A soft accent halo
/// (config `focusGlowRadius`) makes the focused window read as "lit up" above its neighbours.
final class FocusIndicator {
    private let window: BorderWindow
    private let ghost = BorderWindow()   // lingers the OLD halo at its old spot and dissolves it
    private var lastCocoaFrame: NSRect = .zero
    private var lastPreselect: Bool?? = .none   // what the halo currently shows (nil = no preselect)
    private var lastGlow: CGFloat = -1

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
        // Pad MORE than the blur radius: a Gaussian shadow of radius g spreads past g points, so a
        // g-wide margin would clip its soft tail into a hard seam. Give it half again as much room.
        let pad = (g * 1.5).rounded(.up)
        let outer = cocoaFrame.insetBy(dx: -pad, dy: -pad)
        // Same place, same look, already up: nothing to draw. The live-resize pass calls this
        // every frame for the focused tile even when the divider being dragged is elsewhere, and
        // the Gaussian glow is the costliest thing we paint.
        if window.isVisible, window.frame == outer, lastPreselect == preselect, lastGlow == g { return }
        lastPreselect = preselect; lastGlow = g

        // Fade the border in when focus JUMPS to a different window (not on a mere resize of the
        // same one) — an in-place cross-fade, never a travelling rectangle. Honour Reduce Motion.
        let jumped = !window.isVisible
            || abs(cocoaFrame.minX - lastCocoaFrame.minX) > 8
            || abs(cocoaFrame.minY - lastCocoaFrame.minY) > 8
        let animate = Config.shared.focusGlowFade && jumped
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // True cross-fade (never a travelling rectangle): before the halo moves, park a ghost copy
        // at the OLD position with the OLD appearance and dissolve it there, while the real halo
        // fades in at the new one. Only on a real jump from an already-visible halo.
        if animate, window.isVisible, let old = window.contentView as? BorderView {
            ghost.setFrame(window.frame, display: false)
            if let gv = ghost.contentView as? BorderView {
                gv.glowInset = old.glowInset; gv.glowBlur = old.glowBlur; gv.preselect = nil
            }
            ghost.contentView?.frame = NSRect(origin: .zero, size: window.frame.size)
            (ghost.contentView as? BorderView)?.update()
            ghost.alphaValue = 1
            if !ghost.isVisible { ghost.orderFrontRegardless() }   // stays up at alpha 0 between jumps: one window-server call saved per jump
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.26
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ghost.animator().alphaValue = 0
            }
        }
        lastCocoaFrame = cocoaFrame

        window.setFrame(outer, display: false)
        window.contentView?.frame = NSRect(origin: .zero, size: outer.size)
        if let v = window.contentView as? BorderView { v.glowInset = pad; v.glowBlur = g; v.preselect = preselect; v.update() }
        // orderFrontRegardless (like the tab bars) so a .stationary window actually
        // migrates to the current Space — orderFront leaves it stuck on its old Space,
        // which shows the border on the wrong workspace when two share a display.
        // Ordering is a window-server round trip that stalls for hundreds of ms right after an app
        // relayout (halo.show 31 ms on average, 537 worst, on cross-app tab switches). The halo sits
        // one level above every other overlay, so once it is up it needs no re-ordering.
        if animate {
            window.alphaValue = 0
            if !window.isVisible { window.orderFrontRegardless() }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
            if !window.isVisible { window.orderFrontRegardless() }
        }
    }

    func hide() {
        window.orderOut(nil)
    }

    var isShowing: Bool { window.isVisible }

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
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)   // above borders, letterbox, scrims, handles — by level, not by re-ordering
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
    var preselect: Bool? { didSet { update() } }
    /// Padding between the view bounds and the true window edge — room for the halo to bloom.
    var glowInset: CGFloat = 0 { didSet { update() } }
    /// The halo's actual shadow blur radius (kept < glowInset so its soft tail fades within bounds).
    var glowBlur: CGFloat = 0 { didSet { update() } }
    /// 0 = none, 1 = full one-shot glow (see FocusIndicator.pulse()).
    var pulse: CGFloat = 0 { didSet { update() } }

    // Layers, not draw(_:). The halo used to be an NSShadow cast twice by a stroked path inside
    // draw(_:), re-rasterised on the CPU at every change — 4–7 ms per frame of a live resize,
    // measured, the costliest thing Mosaic painted. As CAShapeLayers with a shadowPath the glow
    // is composited on the GPU: a move or a resize updates a path, nothing is rasterised here.
    private let preselectLayer = CALayer()
    private let glowLayers = [CAShapeLayer(), CAShapeLayer()]   // two, like the two strokes before
    private let borderLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        root.addSublayer(preselectLayer)
        for g in glowLayers {
            g.fillColor = nil
            g.shadowOffset = .zero
            g.shadowOpacity = 0.85
            root.addSublayer(g)
        }
        borderLayer.fillColor = nil
        root.addSublayer(borderLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); update() }

    /// Re-derive every layer from the current bounds + config. No implicit animations: a focus
    /// jump is handled by the window cross-fade, and an animated path would be a travelling shape.
    func update() {
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        let thickness = CGFloat(Config.shared.borderWidth)
        let radius = CGFloat(Config.shared.borderCornerRadius)
        let accent = Config.shared.borderNSColor
        let edge = bounds.insetBy(dx: glowInset, dy: glowInset)   // the actual window rectangle

        // Preselect cue: tint the half where the next window will land (Cocoa y=0 = bottom).
        if let ps = preselect {
            let half = ps ? NSRect(x: edge.minX, y: edge.minY, width: edge.width, height: edge.height / 2)
                          : NSRect(x: edge.midX, y: edge.minY, width: edge.width / 2, height: edge.height)
            preselectLayer.frame = half.insetBy(dx: thickness, dy: thickness)
            preselectLayer.backgroundColor = accent.withAlphaComponent(0.28).cgColor
            preselectLayer.isHidden = false
        } else {
            preselectLayer.isHidden = true
        }

        // Border — thickened + brightened for a one-shot pulse, drawn INSET by its own
        // half-width so a wide pulse never clips against the window edge.
        let lineWidth = thickness + pulse * Config.shared.focusPulseWidth
        let path = CGPath(roundedRect: edge.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                          cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Soft accent halo: the stroke's own shadow (no offset) blooming outward into the padding.
        // The shadowPath is the stroke's outline, so the blur hugs the line rather than the fill.
        let glowOn = glowInset > 0
        for g in glowLayers {
            g.isHidden = !glowOn
            guard glowOn else { continue }
            g.frame = bounds
            g.path = path
            g.lineWidth = lineWidth
            g.strokeColor = accent.cgColor
            g.shadowColor = accent.cgColor
            g.shadowRadius = glowBlur
            g.shadowPath = path.copy(strokingWithWidth: lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        }

        // Crisp border on top (brightened during a one-shot pulse).
        let stroke = pulse > 0 ? (accent.blended(withFraction: 0.45 * pulse, of: .white) ?? accent) : accent
        borderLayer.frame = bounds
        borderLayer.path = path
        borderLayer.lineWidth = lineWidth
        borderLayer.strokeColor = stroke.cgColor
    }
}

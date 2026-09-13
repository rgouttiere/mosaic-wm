import AppKit

/// A small frosted pill showing the split ratio (e.g. "62 / 38") at the divider while resizing,
/// then fading out shortly after the last change. Passive overlay — same language as ZoomBadge.
final class ResizeRatioHUD {
    private let window: NSWindow
    private let view = RatioView()
    private let effect = NSVisualEffectView()
    private var hideWork: DispatchWorkItem?

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 22),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        // Above the letterbox fill + window borders (all at .floating), which are re-ordered front on
        // every live-resize frame — otherwise the gap fill of an aspect tile covers the ratio readout.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.ignoresCycle, .moveToActiveSpace]
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)
        window.contentView = effect
    }

    /// Show `text` centered at `center` (Cocoa coords). Auto-hides ~0.7s after the last call.
    func show(_ text: String, at center: NSPoint) {
        view.text = text
        let s = view.intrinsicContentSize
        window.setContentSize(s)
        effect.frame = NSRect(origin: .zero, size: s)
        effect.layer?.cornerRadius = 7
        effect.layer?.masksToBounds = true
        view.frame = effect.bounds
        view.needsDisplay = true
        window.setFrameOrigin(NSPoint(x: center.x - s.width / 2, y: center.y - s.height / 2))
        window.alphaValue = 1
        window.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.2; window.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.window.orderOut(nil) })
    }

    func hide() { hideWork?.cancel(); window.orderOut(nil) }
}

private final class RatioView: NSView {
    var text = "50 / 50"
    private var attrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
         .foregroundColor: Config.shared.borderNSColor]
    }
    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize {
        let ts = (text as NSString).size(withAttributes: attrs)
        return NSSize(width: ts.width + 18, height: 22)
    }
    override func draw(_ dirtyRect: NSRect) {
        let accent = Config.shared.borderNSColor
        NSColor.black.withAlphaComponent(0.28).setFill()   // subtle tint over the frosted blur
        bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        let neon = NSShadow()
        neon.shadowColor = accent.withAlphaComponent(0.8); neon.shadowBlurRadius = 3; neon.shadowOffset = .zero
        neon.set()
        accent.setStroke()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        p.lineWidth = 1; p.stroke()
        let str = text as NSString
        let ts = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - ts.height / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}

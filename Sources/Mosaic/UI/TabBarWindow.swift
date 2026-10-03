import AppKit

/// A borderless, transparent overlay window that floats above the managed windows
/// and hosts the `TabBarView`. This is how Mosaic draws tabs over arbitrary apps
/// without re-parenting their windows (which macOS forbids).
final class TabBarWindow: NSWindow {
    let tabView = TabBarView()
    /// Frosted-glass backdrop (blurs the windows behind the strip); the labels + active indicator
    /// draw on top of it. This is what gives the tab bar its modern material look.
    private let effect = NSVisualEffectView()
    /// The monitor dim: a black veil OVER the strip, never the window's alpha. Lowering the alpha
    /// made the bar translucent — the window behind bled through a frosted rail — when what was
    /// asked for was a darker bar. One static layer, composited by the GPU: no per-frame cost, one
    /// property write when the focused monitor changes (the same write the alpha used to be).
    private let veil = VeilView()

    /// Every strip ever created (weakly held). Lets the manager hide *all* strips
    /// before a render, so a container removed from the tree can never leave an
    /// orphan strip on screen — only strips re-shown by `arrange` remain visible.
    static let registry = NSHashTable<TabBarWindow>.weakObjects()

    init() {
        super.init(contentRect: .zero,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        TabBarWindow.registry.add(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true   // native rounded drop shadow (follows the rounded layer)
        // Above normal app windows so the strip is never occluded by a raised window.
        level = .floating
        // Stay on the Space where the layout was created: do NOT join all Spaces,
        // otherwise the strip bleeds onto adjacent desktops and overlaps fullscreen
        // apps (and can sit over the menu bar area).
        collectionBehavior = [.stationary, .ignoresCycle]
        ignoresMouseEvents = false

        // Dark, translucent material that blurs whatever's behind the strip.
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        tabView.wantsLayer = true
        tabView.autoresizingMask = [.width, .height]
        effect.addSubview(tabView)
        veil.wantsLayer = true
        veil.layer?.backgroundColor = NSColor.black.cgColor
        veil.alphaValue = 0
        veil.autoresizingMask = [.width, .height]
        effect.addSubview(veil, positioned: .above, relativeTo: tabView)
        contentView = effect
    }

    /// `keep` = fraction of brightness to keep (config `inactiveMonitorDim`); 1 = no veil.
    func setDim(keep: CGFloat) {
        let a = max(0, min(1, 1 - keep))
        if veil.alphaValue != a { veil.alphaValue = a }
    }

    /// `cocoaFrame` is in Cocoa (bottom-left) coordinates.
    func place(at cocoaFrame: NSRect) {
        if isVisible, frame == cocoaFrame { return }   // steady strip: no re-frame, no re-ordering
        setFrame(cocoaFrame, display: true)
        effect.frame = NSRect(origin: .zero, size: cocoaFrame.size)
        effect.layer?.cornerRadius = CGFloat(Config.shared.tabCornerRadius)
        effect.layer?.masksToBounds = true
        tabView.frame = effect.bounds
        veil.frame = effect.bounds
        orderFrontRegardless()
    }
}

/// Darkens whatever is under it and lets every event through — the strip beneath keeps its
/// clicks, drags and tooltips.
private final class VeilView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

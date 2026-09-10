import AppKit

/// A borderless, transparent overlay window that floats above the managed windows
/// and hosts the `TabBarView`. This is how Mosaic draws tabs over arbitrary apps
/// without re-parenting their windows (which macOS forbids).
final class TabBarWindow: NSWindow {
    let tabView = TabBarView()
    /// Frosted-glass backdrop (blurs the windows behind the strip); the labels + active indicator
    /// draw on top of it. This is what gives the tab bar its modern material look.
    private let effect = NSVisualEffectView()

    /// Every strip ever created (weakly held). Lets the manager hide *all* strips
    /// before a render, so a container removed from the tree can never leave an
    /// orphan strip on screen — only strips re-shown by `arrange` remain visible.
    static let registry = NSHashTable<TabBarWindow>.weakObjects()

    static func hideAllStrips() {
        for strip in registry.allObjects { strip.orderOut(nil) }
    }

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
        contentView = effect
    }

    /// `cocoaFrame` is in Cocoa (bottom-left) coordinates.
    func place(at cocoaFrame: NSRect) {
        setFrame(cocoaFrame, display: true)
        effect.frame = NSRect(origin: .zero, size: cocoaFrame.size)
        effect.layer?.cornerRadius = CGFloat(Config.shared.tabCornerRadius)
        effect.layer?.masksToBounds = true
        tabView.frame = effect.bounds
        orderFrontRegardless()
    }
}

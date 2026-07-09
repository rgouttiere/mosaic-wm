import AppKit

/// A borderless, transparent overlay window that floats above the managed windows
/// and hosts the `TabBarView`. This is how Mosaic draws tabs over arbitrary apps
/// without re-parenting their windows (which macOS forbids).
final class TabBarWindow: NSWindow {
    let tabView = TabBarView()

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
        tabView.wantsLayer = true
        // Above normal app windows so the strip is never occluded by a raised window.
        level = .floating
        // Stay on the Space where the layout was created: do NOT join all Spaces,
        // otherwise the strip bleeds onto adjacent desktops and overlaps fullscreen
        // apps (and can sit over the menu bar area).
        collectionBehavior = [.stationary, .ignoresCycle]
        ignoresMouseEvents = false
        contentView = tabView
    }

    /// `cocoaFrame` is in Cocoa (bottom-left) coordinates.
    func place(at cocoaFrame: NSRect) {
        setFrame(cocoaFrame, display: true)
        tabView.frame = NSRect(origin: .zero, size: cocoaFrame.size)
        orderFrontRegardless()
    }
}

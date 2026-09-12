import AppKit

/// A frosted accent highlight over the window/group slice where a dragged tab will land. The window
/// covers the whole target tile; an inner indicator SLIDES/resizes to the landing slice (full tile =
/// tab, a half = split), so moving between edge zones glides instead of snapping. Border/tint are
/// layer-based so they stay crisp during the frame animation.
final class DropHighlight {
    private let window: NSWindow
    private let indicator = NSView()   // the highlighted zone; animates within the window
    private let effect = NSVisualEffectView()
    private let tint = NSView()
    private var currentTile: NSRect = .zero

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating   // above windows, below the drag ghost (.popUpMenu)
        window.collectionBehavior = [.ignoresCycle, .stationary]

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        tint.wantsLayer = true
        indicator.wantsLayer = true
        indicator.addSubview(effect)
        indicator.addSubview(tint)

        let container = NSView()
        container.addSubview(indicator)
        window.contentView = container
    }

    /// `tile` = the full target tile (Cocoa); `zoneRect` = the slice that will be occupied (Cocoa).
    /// Snap the window to the tile; slide the inner indicator to the zone within it.
    func show(tile: NSRect, zoneRect: NSRect) {
        let appearing = !window.isVisible
        let tileChanged = tile != currentTile
        currentTile = tile
        window.setFrame(tile, display: false)
        window.contentView?.frame = NSRect(origin: .zero, size: tile.size)

        let radius = CGFloat(Config.shared.borderCornerRadius)
        let color = Config.color(from: Config.shared.dropHighlightColor)
        effect.layer?.cornerRadius = radius
        effect.layer?.masksToBounds = true
        tint.layer?.backgroundColor = color.withAlphaComponent(0.22).cgColor
        tint.layer?.cornerRadius = radius
        indicator.layer?.cornerRadius = radius
        indicator.layer?.borderWidth = 2.5
        indicator.layer?.borderColor = color.withAlphaComponent(0.95).cgColor
        indicator.layer?.masksToBounds = true

        let local = NSRect(x: zoneRect.minX - tile.minX, y: zoneRect.minY - tile.minY,
                           width: zoneRect.width, height: zoneRect.height)
        let inner = NSRect(origin: .zero, size: local.size)
        window.orderFront(nil)
        if appearing || tileChanged || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            indicator.frame = local; effect.frame = inner; tint.frame = inner
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                indicator.animator().frame = local
                effect.animator().frame = inner
                tint.animator().frame = inner
            }
        }
    }

    func hide() { window.orderOut(nil); currentTile = .zero }
}

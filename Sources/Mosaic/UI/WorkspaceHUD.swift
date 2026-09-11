import AppKit

/// One workspace cell in the HUD strip: its number, optional name, the distinct app icons of the
/// windows it holds, whether it holds any windows, and whether it's the one just switched to.
struct WorkspaceHUDItem {
    let number: Int
    let name: String?
    let icons: [NSImage]
    let occupied: Bool
    let current: Bool
}

/// A brief overlay shown on workspace switch: a row of the current monitor's workspaces so you
/// see at a glance which one you're on AND which of the others hold windows (a dot) — no more
/// guessing where a parked window went.
final class WorkspaceHUD {
    private let window: NSWindow
    private let strip = WorkspaceStripView()
    private let effect = NSVisualEffectView()   // frosted backdrop, matching the tab bars
    private var hideWork: DispatchWorkItem?
    private var hideGen = 0   // bumped each show(); a stale fade's completion checks it before hiding

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.ignoresMouseEvents = true
        // NOT canJoinAllSpaces: show only on the desktop it's ordered onto, never flash elsewhere.
        window.collectionBehavior = [.ignoresCycle, .stationary]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        strip.autoresizingMask = [.width, .height]
        effect.addSubview(strip)
        window.contentView = effect
    }

    func show(_ items: [WorkspaceHUDItem], on screen: NSScreen, position: String) {
        guard !items.isEmpty else { return }
        strip.items = items
        let s = strip.intrinsicContentSize
        window.setContentSize(s)
        effect.frame = NSRect(origin: .zero, size: s)
        effect.layer?.cornerRadius = CGFloat(Config.shared.tabCornerRadius)   // match the theme's square corners
        effect.layer?.masksToBounds = true
        strip.frame = effect.bounds
        strip.needsDisplay = true

        let f = screen.visibleFrame
        let m: CGFloat = 28
        let origin: NSPoint
        switch position.lowercased() {
        case "top":          origin = NSPoint(x: f.midX - s.width / 2, y: f.maxY - s.height - m)
        case "bottom":       origin = NSPoint(x: f.midX - s.width / 2, y: f.minY + m)
        case "top-left", "topleft":         origin = NSPoint(x: f.minX + m, y: f.maxY - s.height - m)
        case "top-right", "topright":       origin = NSPoint(x: f.maxX - s.width - m, y: f.maxY - s.height - m)
        case "bottom-left", "bottomleft":   origin = NSPoint(x: f.minX + m, y: f.minY + m)
        case "bottom-right", "bottomright": origin = NSPoint(x: f.maxX - s.width - m, y: f.minY + m)
        default:             origin = NSPoint(x: f.midX - s.width / 2, y: f.midY - s.height / 2)
        }
        window.setFrameOrigin(origin)
        // Fade in when it first appears (not on a rapid re-show while already up). In place, honours
        // Reduce Motion.
        let fadeIn = !window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.alphaValue = fadeIn ? 0 : 1
        window.orderFront(nil)
        if fadeIn {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                window.animator().alphaValue = 1
            }
        }

        hideWork?.cancel()
        hideGen += 1
        let gen = hideGen
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                // A newer show() (rapid switch) bumped hideGen and re-displayed us — don't hide it.
                guard let self, self.hideGen == gen else { return }
                self.window.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
}

/// Draws the workspace strip: rounded dark backdrop, one cell per workspace. Current = accent
/// pill; every occupied workspace shows the distinct app icons of its windows (dimmed when it's
/// not the current one); empty = a dimmed number alone.
private final class WorkspaceStripView: NSView {
    var items: [WorkspaceHUDItem] = []

    private let barH: CGFloat = 64, pad: CGFloat = 9, gap: CGFloat = 5
    private let numFont: CGFloat = 15
    private let iconSize: CGFloat = 16, iconGap: CGFloat = 3, maxIcons = 4
    private let minCellW: CGFloat = 42
    private var accent: NSColor { Palette.accent }
    private var inkOnAccent: NSColor { Palette.ink }

    /// Width the icon row (with a "+N" overflow chip) needs for `count` distinct apps.
    private func iconsWidth(_ count: Int) -> CGFloat {
        let n = min(count, maxIcons)
        guard n > 0 else { return 0 }
        var w = CGFloat(n) * iconSize + CGFloat(n - 1) * iconGap
        if count > maxIcons { w += iconGap + 14 }
        return w
    }
    private func cellWidth(_ item: WorkspaceHUDItem) -> CGFloat {
        max(minCellW, iconsWidth(item.icons.count) + 12)
    }

    override var intrinsicContentSize: NSSize {
        let total = items.reduce(0) { $0 + cellWidth($1) }
        let n = CGFloat(items.count)
        return NSSize(width: pad * 2 + total + max(0, n - 1) * gap, height: barH)
    }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Subtle tint over the frosted backdrop (provided by the HUD's NSVisualEffectView).
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        var x = pad
        for item in items {
            let cw = cellWidth(item)
            let cell = NSRect(x: x, y: pad, width: cw, height: barH - 2 * pad)
            if item.current {
                accent.setFill()
                NSBezierPath(roundedRect: cell, xRadius: 8, yRadius: 8).fill()
            }
            let hasIcons = !item.icons.isEmpty
            let lit = item.current || item.occupied

            // Number: top when there are icons below, centred otherwise.
            let numColor: NSColor = item.current ? inkOnAccent
                : (item.occupied ? .white : NSColor.white.withAlphaComponent(0.32))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: numFont, weight: lit ? .bold : .regular),
                .foregroundColor: numColor]
            let s = "\(item.number)" as NSString
            let ts = s.size(withAttributes: attrs)
            let numY = hasIcons ? cell.maxY - ts.height - 3 : cell.midY - ts.height / 2
            s.draw(at: NSPoint(x: cell.midX - ts.width / 2, y: numY), withAttributes: attrs)

            // App icons: centred row along the bottom, dimmed when the workspace isn't current.
            if hasIcons {
                let iw = iconsWidth(item.icons.count)
                var ix = cell.midX - iw / 2
                let iy = cell.minY + 5
                let frac: CGFloat = item.current ? 1 : 0.62
                for icon in item.icons.prefix(maxIcons) {
                    icon.draw(in: NSRect(x: ix, y: iy, width: iconSize, height: iconSize),
                              from: .zero, operation: .sourceOver, fraction: frac)
                    ix += iconSize + iconGap
                }
                if item.icons.count > maxIcons {
                    let extra = "+\(item.icons.count - maxIcons)" as NSString
                    let ea: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                        .foregroundColor: item.current ? inkOnAccent : NSColor.white.withAlphaComponent(0.7)]
                    let es = extra.size(withAttributes: ea)
                    extra.draw(at: NSPoint(x: ix + 1, y: iy + iconSize / 2 - es.height / 2), withAttributes: ea)
                }
            }
            x += cw + gap
        }
    }
}

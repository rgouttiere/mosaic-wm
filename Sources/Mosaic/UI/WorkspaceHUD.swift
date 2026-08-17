import AppKit

/// One workspace cell in the HUD strip: its number, optional name, whether it holds any
/// windows, and whether it's the one just switched to.
struct WorkspaceHUDItem {
    let number: Int
    let name: String?
    let occupied: Bool
    let current: Bool
}

/// A brief overlay shown on workspace switch: a row of the current monitor's workspaces so you
/// see at a glance which one you're on AND which of the others hold windows (a dot) — no more
/// guessing where a parked window went.
final class WorkspaceHUD {
    private let window: NSWindow
    private let strip = WorkspaceStripView()
    private var hideWork: DispatchWorkItem?

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        // NOT canJoinAllSpaces: show only on the desktop it's ordered onto, never flash elsewhere.
        window.collectionBehavior = [.ignoresCycle, .stationary]
        window.contentView = strip
    }

    func show(_ items: [WorkspaceHUDItem], on screen: NSScreen, position: String) {
        guard !items.isEmpty else { return }
        strip.items = items
        let s = strip.intrinsicContentSize
        window.setContentSize(s)
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
        window.alphaValue = 1
        window.orderFront(nil)

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self?.window.animator().alphaValue = 0
            } completionHandler: { self?.window.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
}

/// Draws the workspace strip: rounded dark backdrop, one cell per workspace. Current = accent
/// pill; occupied (non-current) = bright number + accent dot; empty = dimmed number.
private final class WorkspaceStripView: NSView {
    var items: [WorkspaceHUDItem] = []

    private let cellW: CGFloat = 46, barH: CGFloat = 60, pad: CGFloat = 9, gap: CGFloat = 5
    private let accent = NSColor(srgbRed: 0xa6/255, green: 0xe3/255, blue: 0xa1/255, alpha: 1)
    private let inkOnAccent = NSColor(srgbRed: 0x14/255, green: 0x18/255, blue: 0x14/255, alpha: 1)

    override var intrinsicContentSize: NSSize {
        let n = CGFloat(items.count)
        return NSSize(width: pad * 2 + n * cellW + max(0, n - 1) * gap, height: barH)
    }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()

        var x = pad
        for item in items {
            let cell = NSRect(x: x, y: pad, width: cellW, height: barH - 2 * pad)
            if item.current {
                accent.setFill()
                NSBezierPath(roundedRect: cell, xRadius: 11, yRadius: 11).fill()
            }
            let color: NSColor = item.current ? inkOnAccent
                : (item.occupied ? .white : NSColor.white.withAlphaComponent(0.32))
            let weight: NSFont.Weight = (item.current || item.occupied) ? .bold : .regular
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 22, weight: weight), .foregroundColor: color,
            ]
            let s = "\(item.number)" as NSString
            let ts = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: cell.midX - ts.width / 2, y: cell.midY - ts.height / 2 + 2), withAttributes: attrs)

            // Occupancy dot under the number for non-current workspaces that hold windows.
            if item.occupied && !item.current {
                accent.setFill()
                let d: CGFloat = 5
                NSBezierPath(ovalIn: NSRect(x: cell.midX - d / 2, y: cell.minY + 3, width: d, height: d)).fill()
            }
            x += cellW + gap
        }
    }
}

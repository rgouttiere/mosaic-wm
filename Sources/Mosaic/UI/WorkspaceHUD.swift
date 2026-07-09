import AppKit

/// A brief centered overlay showing the current workspace number on desktop switch.
final class WorkspaceHUD {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        let size = NSSize(width: 96, height: 96)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        // NOT canJoinAllSpaces: it must show only on the desktop it's ordered onto,
        // never flash over another Space (e.g. a full-screen video).
        window.collectionBehavior = [.ignoresCycle, .stationary]

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        content.layer?.cornerRadius = 18

        label.font = .systemFont(ofSize: 52, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (size.height - 64) / 2, width: size.width, height: 64)
        content.addSubview(label)
        window.contentView = content
    }

    func show(_ text: String, on screen: NSScreen, position: String) {
        label.stringValue = text
        let f = screen.visibleFrame
        let s = window.frame.size
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}

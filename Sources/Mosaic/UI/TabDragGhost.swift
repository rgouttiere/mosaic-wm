import AppKit

/// A small floating label that follows the cursor while dragging a tab, so the drag
/// is visible instead of blind. Shared across all tab bars.
final class TabDragGhost {
    static let shared = TabDragGhost()

    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")
    private let height: CGFloat = 28

    private init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 28),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu   // above tab bars and everything else
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]

        let content = NSView(frame: window.frame)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
        content.layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        content.addSubview(label)
        window.contentView = content
    }

    func show(_ title: String, at point: NSPoint) {
        label.stringValue = title
        label.sizeToFit()
        let width = min(300, max(90, label.frame.width + 24))
        window.setContentSize(NSSize(width: width, height: height))
        window.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        label.frame = NSRect(x: 0, y: (height - 16) / 2, width: width, height: 16)
        move(to: point)
        window.orderFront(nil)
    }

    func move(to point: NSPoint) {
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: point.x + 12, y: point.y - size.height - 4))
    }

    func hide() {
        window.orderOut(nil)
    }
}

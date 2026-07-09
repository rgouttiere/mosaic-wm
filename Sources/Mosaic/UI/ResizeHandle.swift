import AppKit

/// A thin, invisible, draggable overlay sitting on the border between two tiles of a
/// split. Dragging it resizes the two adjacent children. The cursor turns into the
/// resize arrows over it.
final class ResizeHandle: NSWindow {
    weak var container: Container?
    var index = 0
    var horizontal = true
    var onDrag: ((ResizeHandle, NSPoint) -> Void)?
    var onUp: (() -> Void)?

    let handleView = HandleView()

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = false
        collectionBehavior = [.ignoresCycle]
        contentView = handleView
        handleView.onDrag = { [weak self] point in
            guard let self else { return }
            self.onDrag?(self, point)
        }
        handleView.onUp = { [weak self] in self?.onUp?() }
    }

    override var canBecomeKey: Bool { false }

    func place(at frame: NSRect, horizontal: Bool) {
        self.horizontal = horizontal
        handleView.horizontal = horizontal
        setFrame(frame, display: false)
        handleView.frame = NSRect(origin: .zero, size: frame.size)
        invalidateCursorRects(for: handleView)
        orderFront(nil)
    }
}

final class HandleView: NSView {
    var horizontal = true
    var onDrag: ((NSPoint) -> Void)?
    var onUp: (() -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDragged(with event: NSEvent) { onDrag?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onUp?() }
}

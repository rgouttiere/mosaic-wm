import AppKit

/// Opaque black bars that fill the gap between a tile and a window that doesn't fill it (e.g. IINA
/// keeping its video aspect). macOS refuses to move a parked window fully off-screen — it keeps a
/// ~40px strip — and that strip pokes through a letterboxed tile's uncovered gap. The gap never
/// overlaps the window, so a black bar at `.floating` (above every app window) covers the strip
/// WITHOUT covering the video, and reads as a natural letterbox bar. A small reused pool: each
/// render claims the bars it needs via `fill`, and `end` hides whatever's left over.
final class LetterboxFill {
    private var pool: [NSWindow] = []
    private var used = 0

    /// Start a render pass — reset the claim counter.
    func begin() { used = 0 }

    /// Cover `rect` (Cocoa coords) with an opaque black bar, reusing a pooled window.
    func fill(_ rect: NSRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        let w: NSWindow
        if used < pool.count { w = pool[used] } else { w = makeBar(); pool.append(w) }
        used += 1
        w.setFrame(rect, display: false)
        w.orderFrontRegardless()
    }

    /// Finish the pass — hide bars this render didn't claim.
    func end() {
        for i in used..<pool.count { pool[i].orderOut(nil) }
    }

    func hideAll() { for w in pool { w.orderOut(nil) }; used = 0 }

    private func makeBar() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = true
        win.backgroundColor = .black
        win.hasShadow = false
        win.level = .floating           // above app windows so it covers a parked window's residual strip
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.ignoresCycle, .stationary]
        return win
    }
}

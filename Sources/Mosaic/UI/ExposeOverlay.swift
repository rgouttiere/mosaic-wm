import AppKit

/// One tab within a tile (a plain window = a tile with one tab).
struct ExposeTab { let label: String; let icon: NSImage?; let selected: Bool }
/// A tile in a workspace: its frame (in the workspace's screen coords) + its tab(s).
struct ExposeTile { let frame: CGRect; let tabs: [ExposeTab] }

/// One workspace to draw in the exposé grid.
struct ExposeWorkspace {
    let title: String       // "2 · main"
    let screen: CGRect      // the workspace's display frame (Cocoa) — for aspect + window mapping
    let tiles: [ExposeTile]
    let current: Bool
    let jump: () -> Void
}

/// Schematic workspace overview on a SINGLE overlay (the screen it's invoked on): all
/// workspaces of all screens together, one column per screen, workspaces stacked within.
/// ←/→ move between columns, ↑/↓ within a column, ⏎ jump, Esc cancel.
final class ExposeOverlay {
    private static var shared: ExposeOverlay?

    static var isOpen: Bool { shared != nil }
    static func show(_ ws: [ExposeWorkspace], on screen: NSScreen, commitOnRelease: Bool = false) {
        shared?.dismiss()
        guard !ws.isEmpty else { return }
        shared = ExposeOverlay(ws, screen: screen, commitOnRelease: commitOnRelease)
    }
    static func advance(_ d: Int) { shared?.move(d) }
    static func commit() { shared?.commitSelection() }
    /// Commit only if opened in hold-to-commit mode (⌘Tab); no-op otherwise.
    static func commitIfRelease() { if let s = shared, s.commitOnRelease { s.commitSelection() } }
    static func cancel() { shared?.dismiss() }

    private let panel: KeyPanel
    private let view: ExposeView
    private var monitor: Any?
    private let workspaces: [ExposeWorkspace]
    private let columns: [[Int]]   // grid: one column per screen (indices into workspaces)
    private var col = 0, row = 0
    private let commitOnRelease: Bool

    private var selected: Int { columns[col][row] }

    private init(_ ws: [ExposeWorkspace], screen: NSScreen, commitOnRelease: Bool) {
        self.commitOnRelease = commitOnRelease
        workspaces = ws
        columns = ExposeOverlay.buildColumns(ws)
        outer: for (c, column) in columns.enumerated() {
            for (r, idx) in column.enumerated() where ws[idx].current { col = c; row = r; break outer }
        }

        panel = KeyPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .modalPanel
        panel.hasShadow = false
        view = ExposeView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.workspaces = ws
        view.columns = columns
        view.selected = selected
        panel.contentView = view

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            switch e.keyCode {
            case 123: self.moveCol(-1); return nil          // ←
            case 124: self.moveCol(1);  return nil          // →
            case 126: self.moveRow(-1); return nil          // ↑
            case 125: self.moveRow(1);  return nil          // ↓
            case 48: self.move(e.modifierFlags.contains(.shift) ? -1 : 1); return nil   // ⇥
            case 36, 76: self.commitSelection(); return nil // ⏎
            case 53: self.dismiss(); return nil             // esc
            default: return e
            }
        }
    }

    /// One column per physical screen, ordered left→right; workspaces in array order within.
    private static func buildColumns(_ ws: [ExposeWorkspace]) -> [[Int]] {
        var groups: [(screen: CGRect, items: [Int])] = []
        for (i, w) in ws.enumerated() {
            if let g = groups.firstIndex(where: { $0.screen == w.screen }) { groups[g].items.append(i) }
            else { groups.append((w.screen, [i])) }
        }
        groups.sort { $0.screen.minX < $1.screen.minX }
        return groups.map { $0.items }
    }

    private func moveCol(_ d: Int) {
        col = min(max(col + d, 0), columns.count - 1)
        row = min(row, columns[col].count - 1)
        refresh()
    }
    private func moveRow(_ d: Int) {
        row = min(max(row + d, 0), columns[col].count - 1)
        refresh()
    }
    private func move(_ d: Int) {
        var flat = 0
        for c in 0..<col { flat += columns[c].count }
        flat += row
        let total = workspaces.count
        flat = ((flat + d) % total + total) % total
        var acc = 0
        for (ci, column) in columns.enumerated() {
            if flat < acc + column.count { col = ci; row = flat - acc; break }
            acc += column.count
        }
        refresh()
    }
    private func refresh() { view.selected = selected; view.needsDisplay = true }

    private func commitSelection() {
        let jump = workspaces[selected].jump
        dismiss()
        jump()
    }

    private func dismiss() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        panel.orderOut(nil)
        if ExposeOverlay.shared === self { ExposeOverlay.shared = nil }
    }
}

private final class ExposeView: NSView {
    var workspaces: [ExposeWorkspace] = []
    var columns: [[Int]] = []
    var selected = 0

    private let text    = NSColor(srgbRed: 0xf9/255, green: 0xf8/255, blue: 0xf5/255, alpha: 1)
    private let subtext = NSColor(srgbRed: 0xa8/255, green: 0x99/255, blue: 0x84/255, alpha: 1)
    private let accent  = NSColor(srgbRed: 0xa6/255, green: 0xe3/255, blue: 0xa1/255, alpha: 1)
    private let surface = NSColor(srgbRed: 0x2a/255, green: 0x2a/255, blue: 0x2a/255, alpha: 1)
    private let winFill = NSColor(srgbRed: 0x45/255, green: 0x47/255, blue: 0x5a/255, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(CGFloat(Config.shared.exposeDim)).setFill(); bounds.fill()

        let margin: CGFloat = 60, colGap: CGFloat = 34, rowGap: CGFloat = 22
        let cols = columns.count
        guard cols > 0 else { return }
        let colW = (bounds.width - 2 * margin - colGap * CGFloat(cols - 1)) / CGFloat(cols)
        let top = bounds.height - margin, colH = bounds.height - 2 * margin
        guard colW > 0, colH > 0 else { return }

        for (c, column) in columns.enumerated() {
            let colX = margin + CGFloat(c) * (colW + colGap)
            let count = column.count
            let cellH = (colH - rowGap * CGFloat(count - 1)) / CGFloat(count)
            for (r, idx) in column.enumerated() {
                let cellY = top - CGFloat(r + 1) * cellH - CGFloat(r) * rowGap
                draw(workspaces[idx], in: NSRect(x: colX, y: cellY, width: colW, height: cellH),
                     selected: idx == selected)
            }
        }
    }

    private func draw(_ ws: ExposeWorkspace, in cell: NSRect, selected: Bool) {
        let headerH: CGFloat = 26
        let area = NSRect(x: cell.minX, y: cell.minY, width: cell.width, height: cell.height - headerH)
        let aspect = ws.screen.height > 0 ? ws.screen.width / ws.screen.height : 16.0 / 10
        var bw = area.width, bh = bw / aspect
        if bh > area.height { bh = area.height; bw = bh * aspect }
        let box = NSRect(x: area.minX, y: area.maxY - bh, width: bw, height: bh)   // top-aligned under header

        (ws.title as NSString).draw(at: CGPoint(x: box.minX + 2, y: box.maxY + 5),
                   withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .bold),
                                    .foregroundColor: selected ? accent : (ws.current ? text : subtext)])

        (selected ? accent.withAlphaComponent(0.14) : surface).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()

        let labelStyle = NSMutableParagraphStyle(); labelStyle.lineBreakMode = .byTruncatingTail
        for tile in ws.tiles where ws.screen.width > 0 && ws.screen.height > 0 {
            let rx = (tile.frame.minX - ws.screen.minX) / ws.screen.width
            let ry = (tile.frame.minY - ws.screen.minY) / ws.screen.height
            let wr = NSRect(x: box.minX + rx * box.width, y: box.minY + ry * box.height,
                            width: tile.frame.width / ws.screen.width * box.width,
                            height: tile.frame.height / ws.screen.height * box.height).insetBy(dx: 1.5, dy: 1.5)
            guard wr.width > 4, wr.height > 4 else { continue }
            winFill.setFill()
            NSBezierPath(roundedRect: wr, xRadius: 3, yRadius: 3).fill()

            if tile.tabs.count > 1 {
                // Mini tab strip along the top: one segment per tab, the active one in accent.
                let stripH = min(18, max(11, wr.height * 0.32))
                let segW = wr.width / CGFloat(tile.tabs.count)
                for (i, tab) in tile.tabs.enumerated() {
                    let seg = NSRect(x: wr.minX + CGFloat(i) * segW, y: wr.maxY - stripH, width: segW, height: stripH)
                    (tab.selected ? accent.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.28)).setFill()
                    seg.fill()
                    if let icon = tab.icon, segW > 13 {
                        let s = min(CGFloat(14), stripH - 3)
                        icon.draw(in: NSRect(x: seg.midX - s / 2, y: seg.midY - s / 2, width: s, height: s))
                    }
                    if i > 0 {
                        NSColor.black.withAlphaComponent(0.45).setFill()
                        NSRect(x: seg.minX, y: seg.minY, width: 1, height: stripH).fill()
                    }
                }
            } else if wr.width > 44, wr.height > 22, let tab = tile.tabs.first {
                // Single window: icon + title top-left.
                var tx = wr.minX + 5
                if let icon = tab.icon { icon.draw(in: NSRect(x: wr.minX + 5, y: wr.maxY - 21, width: 16, height: 16)); tx += 20 }
                (tab.label as NSString).draw(
                    in: NSRect(x: tx, y: wr.maxY - 20, width: wr.maxX - tx - 4, height: 15),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                     .foregroundColor: text, .paragraphStyle: labelStyle])
            }
        }

        if selected {
            accent.setStroke()
            let p = NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: -1), xRadius: 9, yRadius: 9)
            p.lineWidth = 2.5
            p.stroke()
        }
    }
}

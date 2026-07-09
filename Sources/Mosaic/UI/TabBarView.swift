import AppKit

/// Draws the tab strip. Two modes:
///  • horizontal tabbed — one segment per window across a single row (`titles`);
///  • vertical stacked — one ROW per stack entry (`rows`); a row can hold several segments
///    when that entry is a nested tab group, so the group shows inline as tabs. A SINGLE
///    view draws the whole (possibly nested) decoration — nested containers never draw
///    their own bar, so overlays can never overlap.
final class TabBarView: NSView {
    // Horizontal tabbed mode.
    var titles: [String] = [] { didSet { needsDisplay = true } }
    var icons: [NSImage?] = [] { didSet { needsDisplay = true } }
    var selectedIndex = 0 { didSet { needsDisplay = true } }

    var vertical = false { didSet { needsDisplay = true } }

    // Vertical stacked mode.
    var rows: [[String]] = [] { didSet { needsDisplay = true } }
    var rowIcons: [[NSImage?]] = [] { didSet { needsDisplay = true } }
    var selectedRow = 0 { didSet { needsDisplay = true } }
    var selectedSeg: [Int] = [] { didSet { needsDisplay = true } }
    var onStackSelect: ((Int, Int) -> Void)?

    var onSelect: ((Int) -> Void)?
    var onReorder: ((Int, Int) -> Void)?
    var onDropOutside: ((Int, NSPoint) -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    var onDragMove: ((NSPoint) -> Void)?

    override var isFlipped: Bool { true }

    private var dragSourceIndex: Int?
    private var didDrag = false

    private var isStackedRows: Bool { vertical && !rows.isEmpty }
    private var segmentWidth: CGFloat {
        titles.isEmpty ? bounds.width : bounds.width / CGFloat(titles.count)
    }
    private var rowHeight: CGFloat {
        rows.isEmpty ? bounds.height : bounds.height / CGFloat(rows.count)
    }

    private func index(at point: NSPoint) -> Int {
        guard !titles.isEmpty, segmentWidth > 0 else { return 0 }
        return min(titles.count - 1, max(0, Int(point.x / segmentWidth)))
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        let cfg = Config.shared
        layer?.cornerRadius = CGFloat(cfg.tabCornerRadius)
        layer?.masksToBounds = true
        layer?.backgroundColor = Config.color(from: cfg.tabBarColor)
            .withAlphaComponent(CGFloat(cfg.tabBarOpacity)).cgColor
        if isStackedRows { drawStacked() } else { drawHorizontal() }
    }

    private func drawHorizontal() {
        guard !titles.isEmpty else { return }
        for (index, title) in titles.enumerated() {
            let rect = NSRect(x: CGFloat(index) * segmentWidth, y: 0, width: segmentWidth, height: bounds.height)
            drawSegment(title, icon: icons.indices.contains(index) ? icons[index] : nil,
                        in: rect, active: index == selectedIndex)
        }
    }

    private func drawStacked() {
        for (r, segs) in rows.enumerated() {
            let rowY = CGFloat(r) * rowHeight
            let segW = segs.isEmpty ? bounds.width : bounds.width / CGFloat(segs.count)
            let activeSeg = selectedSeg.indices.contains(r) ? selectedSeg[r] : 0
            for (s, title) in segs.enumerated() {
                let rect = NSRect(x: CGFloat(s) * segW, y: rowY, width: segW, height: rowHeight)
                let icon = rowIcons.indices.contains(r) && rowIcons[r].indices.contains(s) ? rowIcons[r][s] : nil
                drawSegment(title, icon: icon, in: rect, active: r == selectedRow && s == activeSeg)
            }
        }
    }

    private func drawSegment(_ title: String, icon: NSImage?, in rect: NSRect, active: Bool) {
        let cfg = Config.shared
        let radius = CGFloat(cfg.tabCornerRadius)
        let fontSize = CGFloat(cfg.tabFontSize)

        if active {
            Config.color(from: cfg.tabActiveColor).setFill()
            let pad = CGFloat(cfg.tabActivePadding)
            let pill = rect.insetBy(dx: pad, dy: pad + 1)
            let r = min(radius, pill.height / 2)
            NSBezierPath(roundedRect: pill, xRadius: r, yRadius: r).fill()
        }

        var textLeft = rect.minX + 10
        if let icon {
            let s = min(rect.height - 6, 16)
            icon.draw(in: NSRect(x: rect.minX + 8, y: rect.midY - s / 2, width: s, height: s))
            textLeft = rect.minX + 8 + s + 6
        }
        let style = NSMutableParagraphStyle()
        style.alignment = (isStackedRows || icon != nil) ? .left : .center
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: active ? .semibold : .regular),
            .foregroundColor: active ? Config.color(from: cfg.tabActiveTextColor)
                                     : Config.color(from: cfg.tabTextColor),
            .paragraphStyle: style,
        ]
        let textHeight = fontSize + 4
        let textRect = NSRect(x: textLeft, y: rect.midY - textHeight / 2,
                              width: max(0, rect.maxX - textLeft - 8), height: textHeight)
        (title as NSString).draw(in: textRect, withAttributes: attrs)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard !isStackedRows, !titles.isEmpty else { return }
        dragSourceIndex = index(at: convert(event.locationInWindow, from: nil))
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isStackedRows else { return }
        if !didDrag {
            onDragStateChange?(true)
            if let i = dragSourceIndex, titles.indices.contains(i) {
                TabDragGhost.shared.show(titles[i], at: NSEvent.mouseLocation)
            }
        } else {
            TabDragGhost.shared.move(to: NSEvent.mouseLocation)
        }
        onDragMove?(NSEvent.mouseLocation)
        didDrag = true
    }

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if isStackedRows {
            guard rowHeight > 0 else { return }
            let r = min(rows.count - 1, max(0, Int(local.y / rowHeight)))
            let segs = rows.indices.contains(r) ? rows[r] : []
            let segW = segs.isEmpty ? bounds.width : bounds.width / CGFloat(segs.count)
            let s = segW > 0 ? min(max(segs.count - 1, 0), max(0, Int(local.x / segW))) : 0
            onStackSelect?(r, s)
            return
        }
        TabDragGhost.shared.hide()
        guard let source = dragSourceIndex else { return }
        if didDrag {
            if bounds.contains(local) {
                let target = index(at: local)
                if target != source { onReorder?(source, target) }
            } else {
                onDropOutside?(source, NSEvent.mouseLocation)
            }
        } else {
            onSelect?(source)
        }
        let wasDragging = didDrag
        dragSourceIndex = nil
        didDrag = false
        if wasDragging { onDragStateChange?(false) }
    }
}

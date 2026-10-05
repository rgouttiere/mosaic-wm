import AppKit
import CoreImage

/// Draws the tab strip. Two modes:
///  • horizontal tabbed — one segment per window across a single row (`titles`);
///  • vertical stacked — one ROW per stack entry (`rows`); a row can hold several segments
///    when that entry is a nested tab group, so the group shows inline as tabs. A SINGLE
///    view draws the whole (possibly nested) decoration — nested containers never draw
///    their own bar, so overlays can never overlap.
final class TabBarView: NSView {
    // Horizontal tabbed mode.
    var titles: [String] = [] { didSet { guard oldValue != titles else { return }; needsDisplay = true; positionUnderline(animated: false) } }
    var icons: [NSImage?] = [] { didSet { needsDisplay = true } }
    /// Per-tab: this window is currently mirrored in the picture-in-picture → badge it.
    var pipFlags: [Bool] = [] { didSet { needsDisplay = true } }
    var rowPipFlags: [[Bool]] = [] { didSet { needsDisplay = true } }
    var selectedIndex = 0 { didSet { guard oldValue != selectedIndex else { return }; needsDisplay = true; positionUnderline(animated: true) } }

    // The active-tab underline is its own layer-backed subview so it slides via Core Animation
    // (GPU, vsync) instead of a per-frame full redraw of the frosted bar. Stacked keeps per-row.
    private let underlineView = TabUnderlineView()
    private let hoverView = TabHoverView()   // sliding hover wash (horizontal mode)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hoverView.wantsLayer = true
        hoverView.isHidden = true
        addSubview(hoverView)               // behind the underline, over the segments (translucent)
        underlineView.wantsLayer = true
        addSubview(underlineView)
    }
    required init?(coder: NSCoder) { fatalError() }

    var vertical = false { didSet { needsDisplay = true } }

    // Vertical stacked mode.
    var rows: [[String]] = [] { didSet { needsDisplay = true } }
    var rowIcons: [[NSImage?]] = [] { didSet { needsDisplay = true } }
    var selectedRow = 0 { didSet { needsDisplay = true } }
    var selectedSeg: [Int] = [] { didSet { needsDisplay = true } }
    var onStackSelect: ((Int, Int) -> Void)?
    /// Rail: the stacked strip as a narrow column of icons on the LEFT of the tile instead of
    /// full-width rows on top. Same rows / segments / selection / clicks / drags — only the
    /// geometry and the drawing differ, so nothing about a stack behaves differently in a rail.
    var rail = false { didSet { needsDisplay = true } }
    /// Per segment, what the window title says is unread (see `UnreadBadge`); drawn on the icon.
    var rowBadges: [[Int?]] = [] { didSet { needsDisplay = true; rebuildToolTips() } }
    /// Per segment, a stable key for its icon (bundle id) — the tinted variant is cached under it.
    var rowIconKeys: [[String]] = []
    /// Per segment, the window id behind it — the rail's hover preview shows that window.
    var rowWindowIDs: [[CGWindowID?]] = []

    var onSelect: ((Int) -> Void)?
    var onReorder: ((Int, Int) -> Void)?
    var onDropOutside: ((Int, NSPoint) -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    var onDragMove: ((NSPoint) -> Void)?

    override var isFlipped: Bool { true }

    private var dragSourceIndex: Int?
    private var didDrag = false
    private var scrollAccum: CGFloat = 0

    /// Which segment the pointer is over, for hover highlighting. Horizontal mode = row 0.
    private struct HoverKey: Equatable { let row: Int; let seg: Int }
    private var hover: HoverKey? { didSet { if oldValue != hover { needsDisplay = true; positionHover(animated: oldValue != nil); updateRailPreview() } } }

    /// Rail only: the hovered icon's window, unless it is the one already on screen.
    private func updateRailPreview() {
        guard rail, isStackedRows, let h = hover, let win = window,
              rows.indices.contains(h.row), rows[h.row].indices.contains(h.seg) else { RailPreview.shared.hide(); return }
        let activeSeg = selectedSeg.indices.contains(h.row) ? selectedSeg[h.row] : 0
        if h.row == selectedRow && h.seg == activeSeg { RailPreview.shared.hide(); return }
        let id = rowWindowIDs.indices.contains(h.row) && rowWindowIDs[h.row].indices.contains(h.seg) ? rowWindowIDs[h.row][h.seg] : nil
        let segs = rows[h.row]
        let segW = segs.isEmpty ? bounds.width : bounds.width / CGFloat(segs.count)
        let local = NSRect(x: CGFloat(h.seg) * segW, y: CGFloat(h.row) * rowHeight, width: segW, height: rowHeight)
        let screenRect = win.convertToScreen(convert(local, to: nil))
        RailPreview.shared.hover(windowID: id, title: segs[h.seg], cell: screenRect)
    }

    private var isStackedRows: Bool { vertical && !rows.isEmpty }
    private var segmentWidth: CGFloat {
        titles.isEmpty ? bounds.width : bounds.width / CGFloat(titles.count)
    }
    private var rowHeight: CGFloat {
        guard !rows.isEmpty else { return bounds.height }
        // Rail cells are square-ish and packed from the top; rows share the strip's full height.
        if rail { return min(bounds.width + 4, bounds.height / CGFloat(rows.count)) }
        return bounds.height / CGFloat(rows.count)
    }
    /// In a rail the strip runs the tile's full height; below the last cell there is nothing.
    private func rowIndex(at point: NSPoint) -> Int? {
        guard rowHeight > 0, !rows.isEmpty else { return nil }
        let r = Int(point.y / rowHeight)
        if rail, r >= rows.count { return nil }
        return min(rows.count - 1, max(0, r))
    }

    private func index(at point: NSPoint) -> Int {
        guard !titles.isEmpty, segmentWidth > 0 else { return 0 }
        return min(titles.count - 1, max(0, Int(point.x / segmentWidth)))
    }

    /// The (row, segment) under `point` for hover highlighting; nil when outside the strip.
    private func hoverKey(at point: NSPoint) -> HoverKey? {
        guard bounds.contains(point) else { return nil }
        if isStackedRows {
            guard let r = rowIndex(at: point) else { return nil }
            let segs = rows.indices.contains(r) ? rows[r] : []
            let segW = segs.isEmpty ? bounds.width : bounds.width / CGFloat(segs.count)
            let s = segW > 0 ? min(max(segs.count - 1, 0), max(0, Int(point.x / segW))) : 0
            return HoverKey(row: r, seg: s)
        }
        guard !titles.isEmpty else { return nil }
        return HoverKey(row: 0, seg: index(at: point))
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        let cfg = Config.shared
        // The frosted backdrop is the window's NSVisualEffectView; we only lay a hint of the theme
        // colour over it so the strip reads as "ours" rather than a neutral system grey.
        Config.color(from: cfg.tabBarColor).withAlphaComponent(0.22).setFill()
        bounds.fill()
        // A one-pixel lighter line along the top: the lit edge a frosted sheet has where it meets
        // the window above it. Reads as glass rather than a flat tinted band; costs nothing.
        NSColor.white.withAlphaComponent(0.09).setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1).fill()
        if isStackedRows { if rail { drawRail() } else { drawStacked() } } else { drawHorizontal() }
    }

    /// The rail: one cell per stack entry, icons only, packed from the top. A nested tab group's
    /// tabs sit side by side in its cell, shrunk to fit. The active cell carries the accent as a
    /// bar on its left edge (the rail's "underline"); the active tab of a pair is the lit icon.
    /// Titles are tooltips, unread counts are badges on the icons — this is the sidebar an
    /// aggregator app draws, done by the window manager over real windows.
    private func drawRail() {
        let cfg = Config.shared
        let accent = Config.color(from: cfg.tabActiveColor)
        let w = bounds.width
        // A lighter edge on the right, where the rail meets the window it stands beside.
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSRect(x: w - 1, y: 0, width: 1, height: bounds.height).fill()
        NSGraphicsContext.current?.imageInterpolation = .high
        for (r, segs) in rows.enumerated() {
            let cell = NSRect(x: 0, y: CGFloat(r) * rowHeight, width: w, height: rowHeight)
            let active = r == selectedRow
            let activeSeg = selectedSeg.indices.contains(r) ? selectedSeg[r] : 0
            if active {
                accent.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 3, dy: 2), xRadius: 3, yRadius: 3).fill()
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = accent.withAlphaComponent(0.7); glow.shadowBlurRadius = 4; glow.shadowOffset = .zero
                glow.set()
                accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: 1.5, y: cell.minY + 8, width: 2.5, height: cell.height - 16), xRadius: 1.25, yRadius: 1.25).fill()
                NSGraphicsContext.restoreGraphicsState()
            } else if hover?.row == r {
                accent.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 3, dy: 2), xRadius: 3, yRadius: 3).fill()
            }
            let k = max(1, segs.count)
            let s = max(10, min(CGFloat(cfg.railIconSize), (w - 10) / CGFloat(k) - 2))
            let total = CGFloat(k) * s + CGFloat(k - 1) * 3
            var x = cell.midX - total / 2
            for i in 0..<k {
                let box = NSRect(x: x, y: cell.midY - s / 2, width: s, height: s)
                let raw = rowIcons.indices.contains(r) && rowIcons[r].indices.contains(i) ? rowIcons[r][i] : nil
                let lit = !active || i == activeSeg || k == 1
                // "tinted": every icon becomes an accent-coloured monochrome — the iOS tinted look —
                // except the active row's, which keeps its colours: focus reads as the one lit thing.
                let key = rowIconKeys.indices.contains(r) && rowIconKeys[r].indices.contains(i) ? rowIconKeys[r][i] : "?"
                let tint = cfg.railIconStyle.lowercased() == "tinted" && !(active && lit)
                let icon = raw.map { tint ? TabBarView.tinted($0, key: key, size: s, color: accent) : $0 }
                icon?.draw(in: box, from: .zero, operation: .sourceOver, fraction: lit ? 1 : 0.45, respectFlipped: true, hints: nil)   // the view is flipped: this NSImage.draw variant ignores that unless told
                if active, k > 1, i == activeSeg {
                    accent.setFill()
                    NSBezierPath(roundedRect: NSRect(x: box.minX + 2, y: box.maxY + 2, width: box.width - 4, height: 2), xRadius: 1, yRadius: 1).fill()
                }
                if let badge = rowBadges.indices.contains(r) && rowBadges[r].indices.contains(i) ? rowBadges[r][i] : nil {
                    drawBadge(badge, at: NSPoint(x: box.maxX, y: box.minY), accent: accent)
                }
                let pip = rowPipFlags.indices.contains(r) && rowPipFlags[r].indices.contains(i) && rowPipFlags[r][i]
                if pip {
                    let ps: CGFloat = 9
                    let conf = NSImage.SymbolConfiguration(pointSize: ps, weight: .semibold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [accent]))
                    NSImage(systemSymbolName: "pip.fill", accessibilityDescription: "Mirrored in picture-in-picture")?
                        .withSymbolConfiguration(conf)?
                        .draw(in: NSRect(x: box.maxX - ps + 2, y: box.maxY - ps + 2, width: ps, height: ps))
                }
                x += s + 3
            }
        }
    }

    /// An icon as an accent-coloured monochrome (luminance → tint, alpha kept), rendered once per
    /// app, size and colour and cached: Core Image on every draw would turn a 6-row rail into
    /// ~6 ms of filtering per render for pixels that never change.
    private static var tintCache: [String: NSImage] = [:]
    static func tinted(_ icon: NSImage, key: String, size: CGFloat, color: NSColor) -> NSImage {
        let cacheKey = "\(key)|\(Int(size))|\(color.description)"
        if let hit = tintCache[cacheKey] { return hit }
        guard let tiff = icon.tiffRepresentation, let ci = CIImage(data: tiff),
              let mono = CIFilter(name: "CIColorMonochrome", parameters: [
                  kCIInputImageKey: ci, kCIInputColorKey: CIColor(color: color) ?? .white, kCIInputIntensityKey: 1.0,
              ])?.outputImage,
              let cg = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(mono, from: mono.extent)
        else { return icon }
        let out = NSImage(cgImage: cg, size: NSSize(width: size, height: size))
        if tintCache.count > 128 { tintCache.removeAll() }
        tintCache[cacheKey] = out
        return out
    }

    /// The unread badge: an accent dot at the icon's top-right corner, with the count when there
    /// is one (capped at 99+, the number is a nudge, not a statistic).
    private func drawBadge(_ count: Int, at corner: NSPoint, accent: NSColor) {
        let label = count <= 0 ? "" : (count > 99 ? "99+" : String(count))
        let font = NSFont.systemFont(ofSize: 8, weight: .bold)
        let textSize = label.isEmpty ? .zero : (label as NSString).size(withAttributes: [.font: font])
        let h: CGFloat = label.isEmpty ? 7 : 11
        let w = label.isEmpty ? 7 : max(h, textSize.width + 6)
        let pill = NSRect(x: corner.x - w + 3, y: corner.y - 3, width: w, height: h)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill.insetBy(dx: -1, dy: -1), xRadius: (h + 2) / 2, yRadius: (h + 2) / 2).fill()
        accent.setFill()
        NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill()
        guard !label.isEmpty else { return }
        (label as NSString).draw(at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2),
                                 withAttributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(0.85)])
    }

    /// Rail titles live in tooltips (there is no room for text); one per segment cell.
    private func rebuildToolTips() {
        removeAllToolTips()
        guard rail, isStackedRows, !Config.shared.railHoverPreview else { return }   // the preview card carries the title
        for (r, segs) in rows.enumerated() {
            let cell = NSRect(x: 0, y: CGFloat(r) * rowHeight, width: bounds.width, height: rowHeight)
            let segW = segs.isEmpty ? cell.width : cell.width / CGFloat(segs.count)
            for (i, title) in segs.enumerated() {
                addToolTip(NSRect(x: CGFloat(i) * segW, y: cell.minY, width: segW, height: cell.height), owner: title as NSString, userData: nil)
            }
        }
    }

    /// The active-tab accent underline (inset, rounded, soft glow) at the bottom of `rect` — used by
    /// the STACKED per-row path. Horizontal tabs use the sliding `underlineView` instead.
    private func drawUnderline(in rect: NSRect) {
        let accent = Config.color(from: Config.shared.tabActiveColor)
        let uh: CGFloat = 2.5, inset: CGFloat = 8
        let bar = NSRect(x: rect.minX + inset, y: rect.maxY - uh - 1.5,
                         width: max(4, rect.width - inset * 2), height: uh)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = accent.withAlphaComponent(0.7); glow.shadowBlurRadius = 4; glow.shadowOffset = .zero
        glow.set()
        accent.setFill()
        NSBezierPath(roundedRect: bar, xRadius: uh / 2, yRadius: uh / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func layout() {
        super.layout()
        positionUnderline(animated: false)   // snap on resize / initial place; selection changes animate
        positionHover(animated: false)
        if rail { rebuildToolTips() }
    }

    /// Slide (or snap/hide) the hover wash to the hovered segment (horizontal mode only). Hidden on
    /// the active tab (it has its own gradient) and when nothing is hovered.
    private func positionHover(animated: Bool) {
        guard !isStackedRows, let h = hover, h.row == 0, h.seg != selectedIndex,
              titles.indices.contains(h.seg), segmentWidth > 4 else { hoverView.isHidden = true; return }
        let frame = NSRect(x: CGFloat(h.seg) * segmentWidth, y: 0, width: segmentWidth, height: bounds.height)
        if hoverView.isHidden { hoverView.frame = frame; hoverView.isHidden = false; return }   // appearing → snap
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.11
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                hoverView.animator().frame = frame
            }
        } else {
            hoverView.frame = frame
        }
    }

    /// Slide (or snap) the horizontal underline subview to the active segment. Core Animation makes
    /// the slide smooth without redrawing the frosted bar.
    private func positionUnderline(animated: Bool) {
        guard !isStackedRows, !titles.isEmpty, segmentWidth > 4 else { underlineView.isHidden = true; return }
        underlineView.isHidden = false
        let i = min(max(selectedIndex, 0), titles.count - 1)
        let inset: CGFloat = 8, h: CGFloat = 12   // 12px tall so the bar's glow has room
        let frame = NSRect(x: CGFloat(i) * segmentWidth + inset, y: bounds.height - h,   // flipped: bottom
                           width: max(4, segmentWidth - inset * 2), height: h)
        if animated, underlineView.frame != .zero, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                underlineView.animator().frame = frame
            }
        } else {
            underlineView.frame = frame
        }
    }

    private func drawHorizontal() {
        guard !titles.isEmpty else { return }
        for (index, title) in titles.enumerated() {
            let rect = NSRect(x: CGFloat(index) * segmentWidth, y: 0, width: segmentWidth, height: bounds.height)
            drawSegment(title, icon: icons.indices.contains(index) ? icons[index] : nil,
                        in: rect, active: index == selectedIndex,
                        hovered: hover == HoverKey(row: 0, seg: index),
                        pip: pipFlags.indices.contains(index) && pipFlags[index])
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
                let isPip = rowPipFlags.indices.contains(r) && rowPipFlags[r].indices.contains(s) && rowPipFlags[r][s]
                drawSegment(title, icon: icon, in: rect, active: r == selectedRow && s == activeSeg,
                            hovered: hover == HoverKey(row: r, seg: s), pip: isPip)
            }
        }
    }

    private func drawSegment(_ title: String, icon: NSImage?, in rect: NSRect, active: Bool, hovered: Bool = false, pip: Bool = false) {
        let cfg = Config.shared
        let fontSize = CGFloat(cfg.tabFontSize)
        let accent = Config.color(from: cfg.tabActiveColor)

        // Hover cue on non-active tabs. Stacked rows draw it here; horizontal tabs use the sliding
        // hoverView so the wash glides between segments.
        if hovered && !active && isStackedRows {
            accent.withAlphaComponent(0.20).setFill()
            rect.fill()
        }

        if active {
            // Subtle vertical tint gradient (deeper toward the underline) for a touch of depth —
            // the view is flipped, so maxY is the bottom, where the accent bar sits.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).setClip()
            NSGradient(starting: accent.withAlphaComponent(0.22), ending: accent.withAlphaComponent(0.05))?
                .draw(from: NSPoint(x: rect.midX, y: rect.maxY), to: NSPoint(x: rect.midX, y: rect.minY),
                      options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
            NSGraphicsContext.restoreGraphicsState()

            // Stacked rows draw their underline per-row here; horizontal tabs use the single SLIDING
            // underline drawn once in draw() (so it can animate between segments).
            if isStackedRows { drawUnderline(in: rect) }
        }

        // Quiet hairline separator on the right edge (skip the rightmost) for gentle structure.
        if rect.maxX < bounds.width - 1 {
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSRect(x: rect.maxX - 1, y: rect.minY + 4, width: 1, height: rect.height - 8).fill()
        }

        var textLeft = rect.minX + 10
        if let icon {
            let s = min(rect.height - 8, 15)
            NSGraphicsContext.current?.imageInterpolation = .high
            icon.draw(in: NSRect(x: rect.minX + 8, y: rect.midY - s / 2, width: s, height: s))
            textLeft = rect.minX + 8 + s + 6
        }

        let style = NSMutableParagraphStyle()
        style.alignment = (isStackedRows || icon != nil) ? .left : .center
        style.lineBreakMode = .byTruncatingTail
        // A light shadow on every label keeps it legible over the (busy) frosted backdrop.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: active ? .semibold : .regular),
            .foregroundColor: active ? Config.color(from: cfg.tabActiveTextColor)
                                     : Config.color(from: cfg.tabTextColor),
            .paragraphStyle: style,
            .shadow: shadow,
        ]
        // "Mirrored in the PiP" badge, right-aligned — the tile may be showing a sibling tab, so this
        // is what tells you where the floating video is coming from. Drawn before the label so the
        // title truncates against it instead of running underneath.
        var textRight = rect.maxX - 8
        if pip {
            let s = min(rect.height - 10, 13)
            let box = NSRect(x: rect.maxX - 8 - s, y: rect.midY - s / 2, width: s, height: s)
            let conf = NSImage.SymbolConfiguration(pointSize: s, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [accent]))
            NSImage(systemSymbolName: "pip.fill", accessibilityDescription: "Mirrored in picture-in-picture")?
                .withSymbolConfiguration(conf)?
                .draw(in: box, from: .zero, operation: .sourceOver, fraction: active ? 1 : 0.75, respectFlipped: true, hints: nil)
            textRight = box.minX - 6
        }

        let textHeight = fontSize + 4
        let textRect = NSRect(x: textLeft, y: rect.midY - textHeight / 2,
                              width: max(0, textRight - textLeft), height: textHeight)
        (title as NSString).draw(in: textRect, withAttributes: attrs)
    }

    // MARK: - Mouse

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hover = hoverKey(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { hover = nil; RailPreview.shared.hide() }

    /// Scroll over the strip to cycle tabs (horizontal) or stack rows (vertical), wrapping.
    override func scrollWheel(with event: NSEvent) {
        guard Config.shared.tabScrollCycle else { return }
        let raw = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY : event.scrollingDeltaX
        guard raw != 0 else { return }
        if event.hasPreciseScrollingDeltas {
            scrollAccum += raw
            guard abs(scrollAccum) >= 28 else { return }   // one step per trackpad chunk
            cycleTab(scrollAccum > 0 ? -1 : 1)
            scrollAccum = 0
        } else {
            cycleTab(raw > 0 ? -1 : 1)                       // one step per wheel notch
        }
    }

    private func cycleTab(_ dir: Int) {
        if isStackedRows {
            let n = rows.count
            guard n > 1 else { return }
            onStackSelect?((selectedRow + dir + n) % n, 0)
        } else {
            let n = titles.count
            guard n > 1 else { return }
            onSelect?((selectedIndex + dir + n) % n)
        }
    }

    /// Top-level index under `point` (a tab segment when horizontal, a row when stacked).
    /// Rows map 1:1 to children, so this doubles as the child index for reorder/detach.
    private func sourceIndex(at point: NSPoint) -> Int? {
        if isStackedRows { return rowIndex(at: point) }
        guard !titles.isEmpty else { return nil }
        return index(at: point)
    }

    /// The label shown in the drag ghost for the top-level index being dragged.
    private func dragLabel(_ i: Int) -> String {
        if isStackedRows {
            let segs = rows.indices.contains(i) ? rows[i] : []
            let active = selectedSeg.indices.contains(i) ? selectedSeg[i] : 0
            return segs.indices.contains(active) ? segs[active] : (segs.first ?? "—")
        }
        return titles.indices.contains(i) ? titles[i] : "—"
    }

    override func mouseDown(with event: NSEvent) {
        dragSourceIndex = sourceIndex(at: convert(event.locationInWindow, from: nil))
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let source = dragSourceIndex else { return }
        hover = nil   // suppress the hover cue while dragging a tab
        if !didDrag {
            onDragStateChange?(true)
            TabDragGhost.shared.show(dragLabel(source), at: NSEvent.mouseLocation)
        } else {
            TabDragGhost.shared.move(to: NSEvent.mouseLocation)
        }
        onDragMove?(NSEvent.mouseLocation)
        didDrag = true
    }

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        TabDragGhost.shared.hide()
        guard let source = dragSourceIndex else { return }
        if didDrag {
            if bounds.contains(local) {
                if let target = sourceIndex(at: local), target != source { onReorder?(source, target) }
            } else {
                onDropOutside?(source, NSEvent.mouseLocation)
            }
        } else if isStackedRows {
            // Pure click in a stacked row: select the (row, segment) under the cursor.
            let segs = rows.indices.contains(source) ? rows[source] : []
            let segW = segs.isEmpty ? bounds.width : bounds.width / CGFloat(segs.count)
            let s = segW > 0 ? min(max(segs.count - 1, 0), max(0, Int(local.x / segW))) : 0
            onStackSelect?(source, s)
        } else {
            onSelect?(source)
        }
        let wasDragging = didDrag
        dragSourceIndex = nil
        didDrag = false
        if wasDragging { onDragStateChange?(false) }
    }
}

/// The sliding hover wash: a translucent accent fill that glides between tabs. Translucent so the
/// label under it stays readable.
private final class TabHoverView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        Config.color(from: Config.shared.tabActiveColor).withAlphaComponent(0.20).setFill()
        bounds.fill()
    }
}

/// The sliding active-tab underline: a crisp accent bar with a soft glow, at the bottom of its own
/// (unflipped) bounds. Layer-backed so its frame animates smoothly via Core Animation.
private final class TabUnderlineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never intercept tab clicks
    override func draw(_ dirtyRect: NSRect) {
        let accent = Config.color(from: Config.shared.tabActiveColor)
        let uh: CGFloat = 2.5
        let bar = NSRect(x: 0, y: 1.5, width: bounds.width, height: uh)   // bottom of the strip
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = accent.withAlphaComponent(0.7); glow.shadowBlurRadius = 4; glow.shadowOffset = .zero
        glow.set()
        accent.setFill()
        NSBezierPath(roundedRect: bar, xRadius: uh / 2, yRadius: uh / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

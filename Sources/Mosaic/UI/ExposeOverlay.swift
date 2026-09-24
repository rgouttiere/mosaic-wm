import AppKit
import QuartzCore

/// One tab within a tile (a plain window = a tile with one tab). `windowID` drives the live preview;
/// `focus` jumps to that window (switch to its workspace + focus it) when its hint key is typed.
struct ExposeTab {
    let label: String; let icon: NSImage?; let selected: Bool
    let windowID: CGWindowID?
    var focus: (() -> Void)? = nil
}
/// A tile in a workspace: its frame (in the workspace's screen coords) + its tab(s).
struct ExposeTile {
    let frame: CGRect
    let tabs: [ExposeTab]
    /// Window whose thumbnail backs the tile: the selected tab's (or the first).
    var displayedWindowID: CGWindowID? { (tabs.first(where: { $0.selected }) ?? tabs.first)?.windowID }
}

/// One workspace to draw in the exposé grid.
struct ExposeWorkspace {
    let title: String       // "2 · main"
    let screen: CGRect      // the workspace's display frame (Cocoa) — for aspect + window mapping
    let tiles: [ExposeTile]
    let current: Bool
    var shown: Bool = false   // currently on a monitor (not parked) → its windows get jump-hints
    let jump: () -> Void
}

/// Schematic workspace overview: all workspaces of all screens together, one column per
/// screen, workspaces stacked within. ←/→ move between columns, ↑/↓ within a column, ⏎ jump,
/// Esc cancel. Rendered on the invoked screen, or mirrored on EVERY screen when
/// `exposeAllScreens` is set — one panel per display, all sharing the same selection.
final class ExposeOverlay {
    private static var shared: ExposeOverlay?

    static var isOpen: Bool { shared != nil }
    static func show(_ ws: [ExposeWorkspace], on screen: NSScreen,
                     allScreens: Bool = false, commitOnRelease: Bool = false) {
        shared?.dismiss()
        guard !ws.isEmpty else { return }
        shared = ExposeOverlay(ws, screen: screen, allScreens: allScreens, commitOnRelease: commitOnRelease)
    }
    static func advance(_ d: Int) { shared?.move(d) }
    // Directional navigation (trackpad swipes) — same grid moves as the h/j/k/l keys.
    static func navLeft()  { shared?.moveCol(-1) }
    static func navRight() { shared?.moveCol(1) }
    static func navUp()    { shared?.moveRow(-1) }
    static func navDown()  { shared?.moveRow(1) }
    static func commit() { shared?.commitSelection() }
    /// Commit only if opened in hold-to-commit mode (⌘Tab); no-op otherwise.
    static func commitIfRelease() { if let s = shared, s.commitOnRelease { s.commitSelection() } }
    static func cancel() { shared?.dismiss() }

    private var panels: [KeyPanel] = []   // one overlay window per rendered screen
    private var views: [ExposeView] = []
    private var monitor: Any?
    private let workspaces: [ExposeWorkspace]
    private let columns: [[Int]]   // grid: one column per screen (indices into workspaces)
    private var col = 0, row = 0
    private let commitOnRelease: Bool
    private let thumbs = ThumbnailStore()   // live previews, filled in as async captures land

    private var selected: Int { columns[col][row] }

    private init(_ ws: [ExposeWorkspace], screen: NSScreen, allScreens: Bool, commitOnRelease: Bool) {
        self.commitOnRelease = commitOnRelease
        workspaces = ws
        columns = ExposeOverlay.buildColumns(ws)
        outer: for (c, column) in columns.enumerated() {
            for (r, idx) in column.enumerated() where ws[idx].current { col = c; row = r; break outer }
        }

        // One panel per screen (mirroring the same grid) when allScreens, else just the invoked one.
        let screens = allScreens ? NSScreen.screens : [screen]
        for scr in screens {
            let panel = KeyPanel(contentRect: scr.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .modalPanel
            panel.hasShadow = false
            let v = ExposeView(frame: NSRect(origin: .zero, size: scr.frame.size))
            v.workspaces = ws
            v.columns = columns
            v.selected = selected
            v.thumbs = thumbs
            panel.contentView = v
            panels.append(panel)
            views.append(v)
        }

        NSApp.activate(ignoringOtherApps: true)
        // The invoked screen's panel takes key focus (input); the rest are passive mirrors.
        for (i, scr) in screens.enumerated() {
            if scr === screen { panels[i].makeKeyAndOrderFront(nil) } else { panels[i].orderFrontRegardless() }
        }
        if !panels.contains(where: { $0.isKeyWindow }) { panels.first?.makeKeyAndOrderFront(nil) }

        // Bloom the overview in: fade each panel + a subtle scale-in (0.96 → 1.0) of its grid.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for (v, panel) in zip(views, panels) {
                v.wantsLayer = true
                if let layer = v.layer {
                    let c = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
                    func scaled(_ s: CGFloat) -> CATransform3D {
                        var t = CATransform3DTranslate(CATransform3DIdentity, c.x, c.y, 0)
                        t = CATransform3DScale(t, s, s, 1)
                        return CATransform3DTranslate(t, -c.x, -c.y, 0)
                    }
                    let a = CABasicAnimation(keyPath: "transform")
                    a.fromValue = scaled(0.97); a.toValue = scaled(1.0); a.duration = 0.18
                    a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.add(a, forKey: "exposeBloom")
                }
                panel.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; panel.animator().alphaValue = 1 }
            }
        }

        loadThumbnails(ws)

        buildHints()
        for v in views { v.hintByWindowID = hintByWindowID }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            switch e.keyCode {
            case 123, 4:  self.moveCol(-1); return nil       // ← / h
            case 124, 37: self.moveCol(1);  return nil       // → / l
            case 126, 40: self.moveRow(-1); return nil       // ↑ / k
            case 125, 38: self.moveRow(1);  return nil       // ↓ / j
            case 48: self.move(e.modifierFlags.contains(.shift) ? -1 : 1); return nil   // ⇥
            case 36, 76: self.commitSelection(); return nil  // ⏎
            case 53:                                         // esc: clear a partial hint first, else close
                if self.typedHint.isEmpty { self.dismiss() } else { self.typedHint = ""; self.refreshHints() }
                return nil
            case 51:                                         // ⌫: back one hint char
                if !self.typedHint.isEmpty { self.typedHint.removeLast(); self.refreshHints() }
                return nil
            default:
                // A hint letter (h/j/k/l are captured above as navigation) → type it.
                if let ch = e.charactersIgnoringModifiers?.lowercased().first,
                   ExposeOverlay.hintAlphabet.contains(ch) {
                    self.typeHint(String(ch)); return nil
                }
                return e
            }
        }
    }

    // MARK: - Window hints (vimium-style jump to any window across workspaces)

    static let hintAlphabet = Array("asdfgqwertyuiopzxcvbnm")   // no h/j/k/l — those navigate
    private var hintActions: [String: () -> Void] = [:]
    private var hintByWindowID: [CGWindowID: String] = [:]
    private var typedHint = ""

    /// Label every displayed window with a hint key and wire it to focus that window.
    private func buildHints() {
        var targets: [(id: CGWindowID, focus: () -> Void)] = []
        for w in workspaces where w.shown {   // hint only on-screen windows, not parked workspaces
            for tile in w.tiles {
                guard let tab = tile.tabs.first(where: { $0.selected }) ?? tile.tabs.first,
                      let id = tab.windowID, let focus = tab.focus else { continue }
                targets.append((id, focus))
            }
        }
        let a = ExposeOverlay.hintAlphabet
        let labels: [String]
        if targets.count <= a.count {
            labels = targets.indices.map { String(a[$0]) }
        } else {
            var out: [String] = []
            outer: for x in a { for y in a { out.append("\(x)\(y)"); if out.count == targets.count { break outer } } }
            labels = out
        }
        for (i, t) in targets.enumerated() {
            hintActions[labels[i]] = t.focus
            hintByWindowID[t.id] = labels[i]
        }
    }

    private func typeHint(_ ch: String) {
        typedHint += ch
        let matches = hintActions.keys.filter { $0.hasPrefix(typedHint) }
        if matches.isEmpty { typedHint = ""; refreshHints(); return }
        if matches.count == 1, matches.first == typedHint, let action = hintActions[typedHint] {
            dismiss(); action(); return
        }
        refreshHints()
    }

    private func refreshHints() { for v in views { v.typedHint = typedHint; v.needsDisplay = true } }

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

    /// Fire off live captures of every displayed window and redraw tiles as each lands. No-op when
    /// the feature is off or the OS is too old; a denied Screen Recording grant just yields no images
    /// (tiles stay schematic). Captures run off-main; the store + redraw are touched on main only.
    private func loadThumbnails(_ ws: [ExposeWorkspace]) {
        guard Config.shared.exposeThumbnails, #available(macOS 14.0, *) else { return }
        let ids = ws.flatMap { $0.tiles.compactMap { $0.displayedWindowID } }
        guard !ids.isEmpty else { return }
        Task { [weak self] in
            let imgs = await Thumbnails.captureAll(ids)
            guard !imgs.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, cg) in imgs {
                    self.thumbs.images[id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
                for v in self.views { v.fadeInThumbnails() }   // in-place fade as the previews land
            }
        }
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
    private func refresh() { for v in views { v.selected = selected; v.needsDisplay = true } }

    private func commitSelection() {
        let jump = workspaces[selected].jump
        dismiss()
        jump()
    }

    private func dismiss() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        for p in panels { p.orderOut(nil) }
        panels.removeAll(); views.removeAll()
        if ExposeOverlay.shared === self { ExposeOverlay.shared = nil }
    }
}

private final class ExposeView: NSView {
    var workspaces: [ExposeWorkspace] = []
    var columns: [[Int]] = []
    var selected = 0 { didSet { crossfadeRing(animated: ringConfigured) } }
    private let ring = NSView(), ringGhost = NSView()   // cross-fading accent selection ring
    private var ringConfigured = false
    var thumbs: ThumbnailStore?   // live previews, shared with the overlay; nil until captured
    var hintByWindowID: [CGWindowID: String] = [:]   // window → its jump-hint key
    var typedHint = ""            // hint prefix typed so far (dims matched keys, filters the rest)
    private var thumbAlpha: CGFloat = 1   // ramps 0→1 as previews land, for an in-place fade-in
    private var fadeTimer: Timer?

    /// Fade the freshly-captured previews in over ~0.15s (in place, honours Reduce Motion).
    func fadeInThumbnails() {
        fadeTimer?.invalidate()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { thumbAlpha = 1; needsDisplay = true; return }
        thumbAlpha = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.thumbAlpha = min(1, self.thumbAlpha + 1.0 / 9)
            self.needsDisplay = true
            if self.thumbAlpha >= 1 { t.invalidate() }
        }
    }
    deinit { fadeTimer?.invalidate() }

    private var text: NSColor    { Palette.text }
    private var subtext: NSColor { Palette.subtext }
    private var accent: NSColor  { Palette.accent }
    private var surface: NSColor { Palette.surface }
    private var winFill: NSColor { Palette.schematic }

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

    /// The box rect (thumbnail area) of the tile whose workspace index is `idx`, if it's in this
    /// view's grid — mirrors draw()'s geometry. Used to place the selection ring.
    private func boxRect(for idx: Int) -> NSRect? {
        let margin: CGFloat = 60, colGap: CGFloat = 34, rowGap: CGFloat = 22, headerH: CGFloat = 26
        let cols = columns.count
        guard cols > 0, idx < workspaces.count else { return nil }
        let colW = (bounds.width - 2 * margin - colGap * CGFloat(cols - 1)) / CGFloat(cols)
        let top = bounds.height - margin, colH = bounds.height - 2 * margin
        guard colW > 0, colH > 0 else { return nil }
        for (c, column) in columns.enumerated() {
            guard let r = column.firstIndex(of: idx) else { continue }
            let colX = margin + CGFloat(c) * (colW + colGap)
            let cellH = (colH - rowGap * CGFloat(column.count - 1)) / CGFloat(column.count)
            let cellY = top - CGFloat(r + 1) * cellH - CGFloat(r) * rowGap
            let area = NSRect(x: colX, y: cellY, width: colW, height: cellH - headerH)
            let sc = workspaces[idx].screen
            let aspect = sc.height > 0 ? sc.width / sc.height : 16.0 / 10
            var bw = area.width, bh = bw / aspect
            if bh > area.height { bh = area.height; bw = bh * aspect }
            return NSRect(x: area.minX, y: area.maxY - bh, width: bw, height: bh)
        }
        return nil
    }

    private func styleRing(_ v: NSView) {
        v.wantsLayer = true
        v.layer?.borderWidth = 2
        v.layer?.borderColor = accent.cgColor
        v.layer?.cornerRadius = 8
        v.layer?.shadowColor = accent.cgColor
        v.layer?.shadowRadius = 8
        v.layer?.shadowOpacity = 0.85
        v.layer?.shadowOffset = .zero
        v.layer?.masksToBounds = false
    }

    /// Cross-fade the accent ring to the selected tile: the old ring dissolves where it was while a
    /// fresh one fades in on the new tile — in place, no travelling.
    private func crossfadeRing(animated: Bool) {
        if !ringConfigured {
            styleRing(ring); styleRing(ringGhost); ringGhost.isHidden = true
            addSubview(ringGhost); addSubview(ring)
            ringConfigured = true
        }
        guard let box = boxRect(for: selected) else { ring.isHidden = true; ringGhost.isHidden = true; return }
        let target = box.insetBy(dx: 1, dy: 1)
        if !animated || ring.isHidden || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            ring.isHidden = false; ring.frame = target; ring.alphaValue = 1; ringGhost.isHidden = true
            return
        }
        ringGhost.frame = ring.frame; ringGhost.alphaValue = 1; ringGhost.isHidden = false
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.16; ringGhost.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.ringGhost.isHidden = true })
        ring.frame = target; ring.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.16; ring.animator().alphaValue = 1 }
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
        // The glowing accent selection ring is a cross-fading subview (see crossfadeRing).

        let labelStyle = NSMutableParagraphStyle(); labelStyle.lineBreakMode = .byTruncatingTail
        for tile in ws.tiles where ws.screen.width > 0 && ws.screen.height > 0 {
            let rx = (tile.frame.minX - ws.screen.minX) / ws.screen.width
            let ry = (tile.frame.minY - ws.screen.minY) / ws.screen.height
            let wr = NSRect(x: box.minX + rx * box.width, y: box.minY + ry * box.height,
                            width: tile.frame.width / ws.screen.width * box.width,
                            height: tile.frame.height / ws.screen.height * box.height).insetBy(dx: 1.5, dy: 1.5)
            guard wr.width > 4, wr.height > 4 else { continue }
            let clip = NSBezierPath(roundedRect: wr, xRadius: 3, yRadius: 3)
            if let id = tile.displayedWindowID, let img = thumbs?.images[id] {
                NSGraphicsContext.saveGraphicsState()
                clip.addClip()
                drawAspectFill(img, in: wr)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                winFill.setFill()
                clip.fill()
            }
            // Hairline so adjacent tiles read apart, over image or fill alike.
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let edge = NSBezierPath(roundedRect: wr, xRadius: 3, yRadius: 3); edge.lineWidth = 1; edge.stroke()

            let hasImage = tile.displayedWindowID.flatMap { thumbs?.images[$0] } != nil

            if tile.tabs.count > 1 {
                // Mini tab strip along the top. The active tab reads without a full accent block:
                // a faint tint, its icon at full opacity (the others dimmed), and a crisp accent
                // underline — matching the real tab bars.
                let stripH = min(18, max(11, wr.height * 0.32))
                let segW = wr.width / CGFloat(tile.tabs.count)
                NSColor.black.withAlphaComponent(0.32).setFill()
                NSRect(x: wr.minX, y: wr.maxY - stripH, width: wr.width, height: stripH).fill()
                for (i, tab) in tile.tabs.enumerated() {
                    let seg = NSRect(x: wr.minX + CGFloat(i) * segW, y: wr.maxY - stripH, width: segW, height: stripH)
                    if tab.selected {
                        accent.withAlphaComponent(0.16).setFill()
                        seg.fill()
                    }
                    if let icon = tab.icon, segW > 13 {
                        let s = min(CGFloat(14), stripH - 3)
                        icon.draw(in: NSRect(x: seg.midX - s / 2, y: seg.midY - s / 2, width: s, height: s),
                                  from: .zero, operation: .sourceOver, fraction: tab.selected ? 1 : 0.5)
                    }
                    if tab.selected {   // accent underline along the strip's inner edge
                        accent.setFill()
                        NSRect(x: seg.minX, y: seg.minY, width: seg.width, height: 2).fill()
                    }
                    if i > 0 {
                        NSColor.black.withAlphaComponent(0.45).setFill()
                        NSRect(x: seg.minX, y: seg.minY, width: 1, height: stripH).fill()
                    }
                }
            } else if wr.width > 44, wr.height > 22, let tab = tile.tabs.first {
                // Single window: icon + title top-left. Over a bright thumbnail the light text needs
                // a scrim to stay legible; over the flat schematic fill it already reads.
                if hasImage {
                    let scrimH = min(26, wr.height * 0.4)
                    let scrim = NSRect(x: wr.minX, y: wr.maxY - scrimH, width: wr.width, height: scrimH)
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: wr, xRadius: 3, yRadius: 3).addClip()
                    if let g = NSGradient(colors: [NSColor.black.withAlphaComponent(0.6), .clear]) {
                        g.draw(in: scrim, angle: -90)
                    }
                    NSGraphicsContext.restoreGraphicsState()
                }
                var tx = wr.minX + 5
                if let icon = tab.icon { icon.draw(in: NSRect(x: wr.minX + 5, y: wr.maxY - 21, width: 16, height: 16)); tx += 20 }
                (tab.label as NSString).draw(
                    in: NSRect(x: tx, y: wr.maxY - 20, width: wr.maxX - tx - 4, height: 15),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                     .foregroundColor: text, .paragraphStyle: labelStyle])
            }

            // Jump hint: type its key to focus this window directly (dims the part you've typed).
            if let id = tile.displayedWindowID, let hint = hintByWindowID[id], hint.hasPrefix(typedHint) {
                drawHint(hint, in: wr)
            }
        }

        if selected {
            accent.setStroke()
            let p = NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: -1), xRadius: 9, yRadius: 9)
            p.lineWidth = 2.5
            p.stroke()
        }
    }

    /// A vimium-style jump-hint chip centered on a tile: dark frosted chip + accent border/text,
    /// the already-typed prefix dimmed (matches the window-hints overlay).
    private func drawHint(_ hint: String, in wr: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: min(15, max(9, wr.height * 0.28)), weight: .bold)
        let up = hint.uppercased()
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: accent.withAlphaComponent(0.4)]
        let hot: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: accent]
        let ts = (up as NSString).size(withAttributes: hot)
        let padX: CGFloat = 6
        let chip = NSRect(x: wr.midX - (ts.width + padX * 2) / 2, y: wr.midY - (ts.height + 6) / 2,
                          width: ts.width + padX * 2, height: ts.height + 6)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3).fill()
        accent.setStroke()
        let b = NSBezierPath(roundedRect: chip.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
        b.lineWidth = 1; b.stroke()
        let n = min(typedHint.count, up.count)
        let pfx = String(up.prefix(n)) as NSString
        let rest = String(up.dropFirst(n)) as NSString
        let tx = chip.minX + padX, ty = chip.minY + 3
        pfx.draw(at: CGPoint(x: tx, y: ty), withAttributes: dim)
        rest.draw(at: CGPoint(x: tx + pfx.size(withAttributes: dim).width, y: ty), withAttributes: hot)
    }

    /// Draw `img` filling `rect` while preserving aspect (overflow cropped by the caller's clip).
    private func drawAspectFill(_ img: NSImage, in rect: NSRect) {
        let iw = img.size.width, ih = img.size.height
        guard iw > 0, ih > 0 else { return }
        let scale = max(rect.width / iw, rect.height / ih)
        let dw = iw * scale, dh = ih * scale
        let dst = NSRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh)
        img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: thumbAlpha)
    }
}

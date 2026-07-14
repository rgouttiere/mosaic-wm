import AppKit

/// One selectable entry: a workspace, a window, or a Mosaic action.
struct SwitcherItem {
    enum Kind { case workspace, window, action }
    let kind: Kind
    let title: String
    let subtitle: String
    let badge: String
    let icon: NSImage?
    let run: () -> Void          // ⏎
    let moveHere: (() -> Void)?  // ⌘⏎ (move focused window here) — nil for actions
}

/// A titled group of items inside a mode (renders a section header).
struct SwitcherSection { let header: String; let items: [SwitcherItem] }
/// A mode is one ←/→ page of the palette (e.g. "Aller" vs "Actions").
struct SwitcherMode { let name: String; let sections: [SwitcherSection] }

private enum Sw {
    static let bg      = NSColor(srgbRed: 0x1e/255, green: 0x1e/255, blue: 0x1e/255, alpha: 0.98)
    static let text    = NSColor(srgbRed: 0xf9/255, green: 0xf8/255, blue: 0xf5/255, alpha: 1)
    static let subtext = NSColor(srgbRed: 0xa8/255, green: 0x99/255, blue: 0x84/255, alpha: 1)
    static let accent  = NSColor(srgbRed: 0xa6/255, green: 0xe3/255, blue: 0xa1/255, alpha: 1)
    static let sel     = NSColor(srgbRed: 0x2e/255, green: 0x7d/255, blue: 0x32/255, alpha: 0.55)
    static let badgeBg = NSColor(srgbRed: 0x31/255, green: 0x32/255, blue: 0x44/255, alpha: 1)
}

/// Fuzzy quick-switcher / command palette. Type to filter; ↑/↓ move (skipping headers);
/// ←/→ switch mode; ⏎ run; ⌘⏎ move the focused window; Esc dismiss.
final class SwitcherPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static var shared: SwitcherPanel?

    private let field = NSTextField()
    private let table = NSTableView()
    private let footer = NSTextField(labelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "")
    private let modes: [SwitcherMode]
    private var currentMode = 0
    private enum Row { case header(String); case item(SwitcherItem) }
    private var rows: [Row] = []
    private var keyMonitor: Any?
    private var closing = false

    static func present(modes: [SwitcherMode], on screen: NSScreen) {
        shared?.forceClose()
        let p = SwitcherPanel(modes: modes, screen: screen)
        shared = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(p.field)
        if Config.shared.switcherFadeIn {
            p.alphaValue = 0
            for i in 1...10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.017) { [weak p] in
                    p?.alphaValue = CGFloat(i) / 10   // ~0.17s fade-in (bypasses Reduce Motion)
                }
            }
        }
    }

    override var canBecomeKey: Bool { true }

    init(modes: [SwitcherMode], screen: NSScreen) {
        self.modes = modes.isEmpty ? [SwitcherMode(name: "", sections: [])] : modes
        let w: CGFloat = 640, h: CGFloat = 440
        let rect = NSRect(x: screen.frame.midX - w / 2,
                          y: screen.frame.midY - h / 2 + 100, width: w, height: h)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = Sw.bg.cgColor
        container.layer?.cornerRadius = 14
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Sw.accent.withAlphaComponent(0.35).cgColor
        contentView = container

        field.frame = NSRect(x: 18, y: h - 56, width: w - 36, height: 40)
        field.font = .systemFont(ofSize: 22)
        field.textColor = Sw.text
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.placeholderAttributedString = NSAttributedString(
            string: "Filtrer…",
            attributes: [.foregroundColor: Sw.subtext, .font: NSFont.systemFont(ofSize: 22)])
        field.delegate = self
        container.addSubview(field)

        let sep = NSView(frame: NSRect(x: 14, y: h - 64, width: w - 28, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = Sw.subtext.withAlphaComponent(0.2).cgColor
        container.addSubview(sep)

        modeLabel.frame = NSRect(x: 18, y: h - 86, width: w - 36, height: 18)
        modeLabel.alignment = .center
        container.addSubview(modeLabel)

        let scroll = NSScrollView(frame: NSRect(x: 8, y: 34, width: w - 16, height: h - 124))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay   // translucent, floats over content instead of taking a column
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.action = #selector(rowClicked)
        table.target = self
        let col = NSTableColumn(identifier: .init("main"))
        col.width = w - 24
        table.addTableColumn(col)
        scroll.documentView = table
        container.addSubview(scroll)

        footer.frame = NSRect(x: 18, y: 10, width: w - 36, height: 16)
        footer.font = .systemFont(ofSize: 11)
        footer.alignment = .center
        container.addSubview(footer)

        updateModeLabel()
        updateFooter(cmd: false)
        reloadResults()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                self.updateFooter(cmd: event.modifierFlags.contains(.command)); return event
            }
            switch event.keyCode {
            case 125: self.move(1);  return nil   // ↓
            case 126: self.move(-1); return nil   // ↑
            case 123: self.switchMode(-1); return nil   // ←
            case 124: self.switchMode(1);  return nil   // →
            case 48:  self.move(event.modifierFlags.contains(.shift) ? -1 : 1); return nil  // ⇥
            case 36, 76: self.confirm(move: event.modifierFlags.contains(.command)); return nil
            case 53:  self.forceClose(); return nil   // esc
            default:  return event
            }
        }
    }

    // MARK: - Modes / filtering

    func controlTextDidChange(_ obj: Notification) { reloadResults() }

    private func switchMode(_ dir: Int) {
        guard modes.count > 1 else { return }
        currentMode = (currentMode + dir + modes.count) % modes.count
        updateModeLabel()
        reloadResults()
    }

    private func reloadResults() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        var out: [Row] = []
        for section in modes[currentMode].sections {
            let matched: [SwitcherItem]
            if q.isEmpty {
                matched = section.items
            } else {
                matched = section.items.compactMap { item -> (SwitcherItem, Int)? in
                    guard let s = Self.fuzzyScore(q, "\(item.title) \(item.subtitle) \(item.badge)") else { return nil }
                    return (item, s)
                }.sorted { $0.1 > $1.1 }.map { $0.0 }
            }
            if !matched.isEmpty {
                out.append(.header(section.header))
                out.append(contentsOf: matched.map { .item($0) })
            }
        }
        rows = out
        table.reloadData()
        if let first = firstItem(from: 0, dir: 1) { table.selectRowIndexes([first], byExtendingSelection: false) }
    }

    private static func fuzzyScore(_ needle: String, _ haystack: String) -> Int? {
        if needle.isEmpty { return 0 }
        let n = Array(needle.lowercased()), h = Array(haystack.lowercased())
        var score = 0, ni = 0, last = -2
        for (hi, hc) in h.enumerated() where ni < n.count {
            if hc == n[ni] {
                score += 10
                if hi == last + 1 { score += 15 }
                if hi == 0 || h[hi - 1] == " " || h[hi - 1] == "-" { score += 12 }
                last = hi; ni += 1
            }
        }
        return ni == n.count ? score - h.count : nil
    }

    // MARK: - Navigation (skips header rows)

    private func isItem(_ i: Int) -> Bool {
        guard rows.indices.contains(i) else { return false }
        if case .item = rows[i] { return true }; return false
    }
    private func firstItem(from start: Int, dir: Int) -> Int? {
        var i = start
        while rows.indices.contains(i) { if isItem(i) { return i }; i += dir }
        return nil
    }
    private func move(_ delta: Int) {
        let cur = table.selectedRow
        if let next = firstItem(from: (cur < 0 ? -1 : cur) + delta, dir: delta) {
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
        }
    }

    private func confirm(move: Bool) { execute(row: table.selectedRow, move: move) }

    @objc private func rowClicked() {
        execute(row: table.clickedRow,
                move: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
    }

    private func execute(row: Int, move: Bool) {
        guard isItem(row), case .item(let it) = rows[row] else { return }
        forceClose()
        if move, let m = it.moveHere { m() } else { it.run() }
    }

    // MARK: - Chrome

    private func updateModeLabel() {
        let s = NSMutableAttributedString()
        if modes.count > 1 { s.append(NSAttributedString(string: "‹   ",
            attributes: [.foregroundColor: Sw.subtext, .font: NSFont.systemFont(ofSize: 12)])) }
        for (i, m) in modes.enumerated() {
            let on = i == currentMode
            s.append(NSAttributedString(string: m.name, attributes: [
                .foregroundColor: on ? Sw.accent : Sw.subtext,
                .font: NSFont.systemFont(ofSize: 12, weight: on ? .bold : .regular)]))
            if i < modes.count - 1 {
                s.append(NSAttributedString(string: "      ", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            }
        }
        if modes.count > 1 { s.append(NSAttributedString(string: "   ›",
            attributes: [.foregroundColor: Sw.subtext, .font: NSFont.systemFont(ofSize: 12)])) }
        modeLabel.attributedStringValue = s
    }

    private func updateFooter(cmd: Bool) {
        if cmd {
            footer.stringValue = "⌘⏎  déplacer la fenêtre focus ici"
            footer.textColor = Sw.accent
        } else {
            footer.stringValue = "↑↓ naviguer    ←→ mode    ⏎ valider    ⌘⏎ déplacer    esc"
            footer.textColor = Sw.subtext
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 26 }; return 46
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { isItem(row) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let h): return SwitcherHeader(text: h)
        case .item(let it): return SwitcherRow(item: it, query: field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SwitcherRowView() }

    // MARK: - Lifecycle

    override func resignKey() {
        super.resignKey()
        if !closing { forceClose() }
    }

    private func forceClose() {
        guard !closing else { return }
        closing = true
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if SwitcherPanel.shared === self { SwitcherPanel.shared = nil }
        orderOut(nil)
        close()
    }
}

private func swHighlightedTitle(_ title: String, query: String) -> NSAttributedString {
    let out = NSMutableAttributedString(string: title,
        attributes: [.foregroundColor: Sw.text, .font: NSFont.systemFont(ofSize: 15)])
    guard !query.isEmpty else { return out }
    let t = Array(title.lowercased()), q = Array(query.lowercased())
    var qi = 0
    let hit: [NSAttributedString.Key: Any] = [.foregroundColor: Sw.accent,
                                              .font: NSFont.systemFont(ofSize: 15, weight: .bold)]
    for (i, c) in t.enumerated() where qi < q.count {
        if c == q[qi] { out.addAttributes(hit, range: NSRange(location: i, length: 1)); qi += 1 }
    }
    return out
}

private final class SwitcherRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        Sw.sel.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
}

private final class SwitcherHeader: NSView {
    init(text: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = Sw.subtext
        label.frame = NSRect(x: 20, y: 4, width: 500, height: 14)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class SwitcherRow: NSView {
    init(item: SwitcherItem, query: String) {
        super.init(frame: .zero)
        wantsLayer = true

        let badge = NSTextField(labelWithString: " \(item.badge) ")
        badge.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        badge.textColor = item.kind == .workspace ? .black : Sw.text
        badge.wantsLayer = true
        badge.layer?.backgroundColor = (item.kind == .workspace ? Sw.accent : Sw.badgeBg).cgColor
        badge.layer?.cornerRadius = 6
        badge.alignment = .center
        badge.sizeToFit()
        badge.frame = NSRect(x: 18, y: 14, width: max(26, badge.frame.width + 8), height: 20)
        addSubview(badge)

        var titleX = badge.frame.maxX + 12
        if let icon = item.icon {
            let iv = NSImageView(frame: NSRect(x: badge.frame.maxX + 10, y: 13, width: 20, height: 20))
            iv.image = icon
            iv.imageScaling = .scaleProportionallyUpOrDown
            addSubview(iv)
            titleX = iv.frame.maxX + 8
        }

        let title = NSTextField(labelWithAttributedString: swHighlightedTitle(item.title, query: query))
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: titleX, y: 13, width: 400 - titleX, height: 20)
        addSubview(title)

        let sub = NSTextField(labelWithString: item.subtitle)
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = Sw.subtext
        sub.alignment = .right
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: 408, y: 14, width: 180, height: 18)   // ends ~588, clear of the scroller
        addSubview(sub)
    }
    required init?(coder: NSCoder) { fatalError() }
}

import AppKit

/// One row in the quick-switcher: a workspace or a window.
struct SwitcherItem {
    enum Kind { case workspace, window }
    let kind: Kind
    let title: String        // workspace name, or window title
    let subtitle: String     // "workspace" or the app name
    let badge: String        // workspace number/name it belongs to
    let run: () -> Void      // what to do when chosen
}

/// Theme colours (match the terminal/sketchybar setup).
private enum Sw {
    static let bg      = NSColor(srgbRed: 0x1e/255, green: 0x1e/255, blue: 0x1e/255, alpha: 0.98)
    static let text    = NSColor(srgbRed: 0xf9/255, green: 0xf8/255, blue: 0xf5/255, alpha: 1)
    static let subtext = NSColor(srgbRed: 0xa8/255, green: 0x99/255, blue: 0x84/255, alpha: 1)
    static let accent  = NSColor(srgbRed: 0xa6/255, green: 0xe3/255, blue: 0xa1/255, alpha: 1)
    static let sel     = NSColor(srgbRed: 0x2e/255, green: 0x7d/255, blue: 0x32/255, alpha: 0.55)
    static let badgeBg = NSColor(srgbRed: 0x31/255, green: 0x32/255, blue: 0x44/255, alpha: 1)
}

/// A centered, dark, fuzzy quick-switcher popup (⌘-palette style). Type to filter across
/// workspaces and windows; ↑/↓ to move, ⏎ to jump, Esc to dismiss.
final class SwitcherPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static var shared: SwitcherPanel?

    private let field = NSTextField()
    private let table = NSTableView()
    private var all: [SwitcherItem]
    private var filtered: [SwitcherItem]
    private var keyMonitor: Any?
    private var closing = false

    static func present(items: [SwitcherItem], on screen: NSScreen) {
        shared?.forceClose()
        let p = SwitcherPanel(items: items, screen: screen)
        shared = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(p.field)
    }

    override var canBecomeKey: Bool { true }

    init(items: [SwitcherItem], screen: NSScreen) {
        all = items
        filtered = items
        let w: CGFloat = 640, h: CGFloat = 420
        let rect = NSRect(x: screen.frame.midX - w / 2,
                          y: screen.frame.midY - h / 2 + 100, width: w, height: h)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = Sw.bg.cgColor
        container.layer?.cornerRadius = 14
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Sw.accent.withAlphaComponent(0.35).cgColor
        contentView = container

        field.frame = NSRect(x: 18, y: h - 58, width: w - 36, height: 40)
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.textColor = Sw.text
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.placeholderAttributedString = NSAttributedString(
            string: "Aller à un workspace ou une fenêtre…",
            attributes: [.foregroundColor: Sw.subtext, .font: NSFont.systemFont(ofSize: 22)])
        field.delegate = self
        container.addSubview(field)

        let sep = NSView(frame: NSRect(x: 14, y: h - 66, width: w - 28, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = Sw.subtext.withAlphaComponent(0.2).cgColor
        container.addSubview(sep)

        let scroll = NSScrollView(frame: NSRect(x: 8, y: 8, width: w - 16, height: h - 82))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 46
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

        table.reloadData()
        selectRow(0)

        // Robust key handling: intercept nav keys ourselves; let everything else reach the
        // search field. Avoids relying on single-line field-editor command routing.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 125: self.move(1);  return nil   // ↓
            case 126: self.move(-1); return nil   // ↑
            case 48:  self.move(event.modifierFlags.contains(.shift) ? -1 : 1); return nil  // ⇥
            case 36, 76: self.confirm(); return nil   // ⏎ / enter
            case 53:  self.forceClose(); return nil   // esc
            default:  return event
            }
        }
    }

    // MARK: - Filtering

    func controlTextDidChange(_ obj: Notification) { reloadResults() }

    private func reloadResults() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            filtered = all
        } else {
            filtered = all
                .compactMap { item -> (SwitcherItem, Int)? in
                    guard let s = Self.fuzzyScore(q, "\(item.title) \(item.subtitle) \(item.badge)")
                    else { return nil }
                    return (item, s + (item.kind == .workspace ? 5 : 0))
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }
        table.reloadData()
        selectRow(0)
    }

    /// Subsequence fuzzy match with consecutive / word-start bonuses. nil = no match.
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

    // MARK: - Navigation

    private func selectRow(_ i: Int) {
        guard i >= 0, i < filtered.count else { return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let cur = table.selectedRow < 0 ? 0 : table.selectedRow
        selectRow(min(max(cur + delta, 0), filtered.count - 1))
    }

    private func confirm() {
        let r = table.selectedRow
        guard r >= 0, r < filtered.count else { return }
        let item = filtered[r]
        forceClose()
        item.run()
    }

    @objc private func rowClicked() {
        let r = table.clickedRow
        guard r >= 0, r < filtered.count else { return }
        let item = filtered[r]
        forceClose()
        item.run()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        SwitcherRow(item: filtered[row])
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SwitcherRowView()
    }

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

/// Row background that draws our accent selection (no reloadData needed — the table
/// redraws row views on selection changes automatically).
private final class SwitcherRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let r = bounds.insetBy(dx: 6, dy: 2)
        Sw.sel.setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
    }
}

/// Row content: [badge] title … subtitle.
private final class SwitcherRow: NSView {
    init(item: SwitcherItem) {
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

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 15)
        title.textColor = Sw.text
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: badge.frame.maxX + 12, y: 13, width: 380, height: 20)
        addSubview(title)

        let sub = NSTextField(labelWithString: item.subtitle)
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = Sw.subtext
        sub.alignment = .right
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: 430, y: 14, width: 176, height: 18)
        addSubview(sub)
    }

    required init?(coder: NSCoder) { fatalError() }
}

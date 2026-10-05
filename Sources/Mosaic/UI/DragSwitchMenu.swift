import AppKit
import QuartzCore

/// The list of workspaces that drops down from the top-left of a screen while something is being
/// dragged near the top edge. One row per workspace; the hovered row fills with a progress bar over
/// the dwell time, in place. The panel never takes events: the drag stays with whatever app owns it,
/// Mosaic only watches the pointer.
final class DragSwitchMenu {
    struct Row { let number: Int; let name: String; let icons: [NSImage]; let shown: Bool }

    private let panel: NSPanel
    private let stack = NSView()
    private var rowViews: [RowView] = []
    private(set) var rows: [Row] = []
    private(set) var hovered: Int?
    static let rowHeight: CGFloat = 34
    static let width: CGFloat = 280

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)   // over sketchybar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.ignoresCycle, .canJoinAllSpaces, .transient]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.addSubview(stack)
        panel.contentView = effect
    }

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    func show(rows: [Row], on screen: NSScreen, below barHeight: CGFloat) {
        self.rows = rows
        let pad: CGFloat = 6
        let h = CGFloat(rows.count) * Self.rowHeight + pad * 2
        let f = NSRect(x: screen.frame.minX + 8, y: screen.frame.maxY - barHeight - 6 - h, width: Self.width, height: h)
        panel.setFrame(f, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: f.size)
        stack.frame = NSRect(x: pad, y: pad, width: Self.width - pad * 2, height: h - pad * 2)
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = rows.enumerated().map { i, row in
            let v = RowView(row: row)
            v.frame = NSRect(x: 0, y: stack.bounds.height - CGFloat(i + 1) * Self.rowHeight, width: stack.bounds.width, height: Self.rowHeight)
            stack.addSubview(v)
            return v
        }
        hovered = nil
        guard !panel.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1; panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0; panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        hovered = nil
        rowViews.forEach { $0.setProgress(nil, duration: 0) }
        panel.orderOut(nil)
    }

    /// The row index under a screen point, nil outside the rows.
    func rowIndex(at point: NSPoint) -> Int? {
        guard panel.isVisible, panel.frame.contains(point) else { return nil }
        for (i, v) in rowViews.enumerated() {
            let r = panel.convertToScreen(v.convert(v.bounds, to: nil))
            if r.contains(point) { return i }
        }
        return nil
    }

    /// Highlight a row and run its fill over `dwell` seconds (nil = none).
    func setHovered(_ i: Int?, dwell: TimeInterval) {
        guard i != hovered else { return }
        if let old = hovered, rowViews.indices.contains(old) { rowViews[old].setProgress(nil, duration: 0) }
        hovered = i
        if let i, rowViews.indices.contains(i) { rowViews[i].setProgress(1, duration: dwell) }
    }

    private final class RowView: NSView {
        private let fill = CALayer()
        private let row: Row
        init(row: Row) {
            self.row = row
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.masksToBounds = true
            fill.backgroundColor = Config.color(from: Config.shared.tabActiveColor).withAlphaComponent(0.35).cgColor
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
            layer?.addSublayer(fill)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            fill.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            fill.position = CGPoint(x: 0, y: bounds.midY)
            if fill.animation(forKey: "fill") == nil, fill.transform.m11 != 1 { fill.transform = CATransform3DMakeScale(0, 1, 1) }
            CATransaction.commit()
        }

        /// nil = no highlight; 1 = fill the row left to right over `duration`.
        func setProgress(_ p: CGFloat?, duration: TimeInterval) {
            fill.removeAllAnimations()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            fill.transform = CATransform3DMakeScale(0, 1, 1)
            CATransaction.commit()
            layer?.backgroundColor = p == nil ? nil : NSColor.white.withAlphaComponent(0.08).cgColor
            guard p != nil else { return }
            let a = CABasicAnimation(keyPath: "transform.scale.x")
            a.fromValue = 0; a.toValue = 1; a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            a.fillMode = .forwards; a.isRemovedOnCompletion = false
            fill.add(a, forKey: "fill")
        }

        override func draw(_ dirtyRect: NSRect) {
            let accent = Config.color(from: Config.shared.tabActiveColor)
            let numAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
                                                           .foregroundColor: row.shown ? accent : NSColor.secondaryLabelColor]
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor]
            let y = bounds.midY - 8
            ("\(row.number)" as NSString).draw(at: NSPoint(x: 10, y: y), withAttributes: numAttrs)
            var label = row.name
            if let dash = label.range(of: " - "), label.hasPrefix("\(row.number)") { label = String(label[dash.upperBound...]) }
            (label as NSString).draw(at: NSPoint(x: 30, y: y), withAttributes: nameAttrs)
            var x = bounds.width - 8
            for icon in row.icons.prefix(5).reversed() {
                x -= 20
                icon.draw(in: NSRect(x: x, y: bounds.midY - 9, width: 18, height: 18))
            }
        }
    }
}

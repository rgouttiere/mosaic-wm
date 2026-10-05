import AppKit
import ScreenCaptureKit

/// Hover a rail icon for a moment → a small frosted card beside the rail with the window's last
/// preview and its title, without clicking or moving keyboard focus. In place: it fades in where it
/// appears, never slides. The preview is the exposé's cached thumbnail, shown at once, then
/// refreshed by ONE capture of that window — not a live stream (a ScreenCaptureKit stream per hover
/// would keep the window server busy for as long as the pointer rests there).
final class RailPreview {
    static let shared = RailPreview()

    private let panel: NSPanel
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?
    private var shownID: CGWindowID?
    private static let width: CGFloat = 340

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)   // over the strips and the halo
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.ignoresCycle, .moveToActiveSpace, .transient]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        effect.addSubview(imageView)
        effect.addSubview(label)
        panel.contentView = effect
    }

    /// `cell` is the hovered icon's rect in screen (Cocoa) coordinates. nil id = pointer left.
    func hover(windowID: CGWindowID?, title: String, cell: NSRect) {
        pending?.cancel(); pending = nil
        guard Config.shared.railHoverPreview, let id = windowID else { hide(); return }
        if shownID == id, panel.isVisible { return }
        let work = DispatchWorkItem { [weak self] in self?.show(id: id, title: title, cell: cell) }
        pending = work
        // Already showing one: switch at once while the pointer runs down the rail; else wait a beat,
        // so crossing the rail on the way somewhere else never flashes a card.
        DispatchQueue.main.asyncAfter(deadline: .now() + (panel.isVisible ? 0 : 0.35), execute: work)
    }

    func hide() {
        pending?.cancel(); pending = nil
        shownID = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func show(id: CGWindowID, title: String, cell: NSRect) {
        shownID = id
        let cached = ThumbnailStore.shared.images[id]
        layout(image: cached, title: title, cell: cell)
        let first = !panel.isVisible
        if first && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; panel.animator().alphaValue = 1 }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        guard Config.shared.exposeThumbnails, #available(macOS 14.0, *) else { return }
        Task {
            let imgs = await Thumbnails.captureAll([id])
            await MainActor.run {
                guard let cg = imgs[id] else { return }
                ThumbnailStore.shared.set(cg, for: id)
                guard self.shownID == id, self.panel.isVisible else { return }
                self.layout(image: ThumbnailStore.shared.images[id], title: title, cell: cell)
            }
        }
    }

    private func layout(image: NSImage?, title: String, cell: NSRect) {
        let pad: CGFloat = 10, labelH: CGFloat = 18, w = Self.width
        let aspect = image.map { $0.size.height / max(1, $0.size.width) } ?? 0.6
        let imgH = (w - pad * 2) * min(max(aspect, 0.35), 1.2)
        let h = pad + labelH + 6 + imgH + pad
        label.stringValue = title
        imageView.image = image
        imageView.isHidden = image == nil
        let contentH = image == nil ? pad * 2 + labelH : h
        var frame = NSRect(x: cell.maxX + 8, y: cell.midY - contentH / 2, width: w, height: contentH)
        if let vis = (NSScreen.screens.first { $0.frame.intersects(cell) } ?? NSScreen.main)?.visibleFrame {
            frame.origin.y = min(max(frame.minY, vis.minY + 4), vis.maxY - contentH - 4)
            if frame.maxX > vis.maxX - 4 { frame.origin.x = cell.minX - w - 8 }
        }
        panel.setFrame(frame, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        label.frame = NSRect(x: pad, y: contentH - pad - labelH, width: w - pad * 2, height: labelH)
        imageView.frame = NSRect(x: pad, y: pad, width: w - pad * 2, height: imgH)
    }
}

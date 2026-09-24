import AppKit
import QuartzCore

/// One hintable window: where to draw its label (Cocoa, bottom-left) and how to focus it.
struct HintTarget { let frameCocoa: CGRect; let focus: () -> Void }

/// Vimium-style window hints: overlays a letter label on each visible window; type the
/// letter(s) to focus that window. Esc cancels. Keyboard-only, no arrows.
///
/// One borderless panel PER screen (a single window spanning several displays gets
/// constrained/repositioned by macOS, which throws off the coordinates).
final class HintsOverlay {
    private static var shared: HintsOverlay?

    private var panels: [KeyPanel] = []
    private var views: [HintsView] = []
    private var monitor: Any?
    private var typed = ""
    private let targets: [(hint: String, target: HintTarget)]

    static func show(_ raw: [HintTarget]) {
        if let open = shared { open.dismiss(); return }   // pressing the hotkey again toggles it off
        guard !raw.isEmpty, !NSScreen.screens.isEmpty else { return }
        shared = HintsOverlay(raw)
    }

    private init(_ raw: [HintTarget]) {
        let letters = Array("asdfghjklqwertyuiop")
        var labels: [String] = []
        if raw.count <= letters.count {
            labels = letters.prefix(raw.count).map(String.init)
        } else {
            outer: for a in letters { for b in letters {
                labels.append("\(a)\(b)"); if labels.count == raw.count { break outer }
            } }
        }
        targets = zip(labels, raw).map { ($0, $1) }

        for screen in NSScreen.screens {
            let sf = screen.frame
            let mine = targets.filter {
                sf.contains(CGPoint(x: $0.target.frameCocoa.midX, y: $0.target.frameCocoa.midY))
            }
            guard !mine.isEmpty else { continue }
            let panel = KeyPanel(contentRect: sf, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .modalPanel
            panel.hasShadow = false
            let view = HintsView(frame: NSRect(origin: .zero, size: sf.size))
            view.origin = sf.origin
            view.targets = mine
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }

        NSApp.activate(ignoringOtherApps: true)
        panels.first?.makeKeyAndOrderFront(nil)

        // Pop-in: quick fade + scale (0.9 → 1.0). The view's background is transparent (labels only),
        // so a bolder scale reveals no desktop at the edges.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for (view, panel) in zip(views, panels) {
                view.wantsLayer = true
                if let layer = view.layer {
                    let c = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
                    func scaled(_ s: CGFloat) -> CATransform3D {
                        var t = CATransform3DTranslate(CATransform3DIdentity, c.x, c.y, 0)
                        t = CATransform3DScale(t, s, s, 1)
                        return CATransform3DTranslate(t, -c.x, -c.y, 0)
                    }
                    let a = CABasicAnimation(keyPath: "transform")
                    a.fromValue = scaled(0.9); a.toValue = scaled(1.0); a.duration = 0.13
                    a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.add(a, forKey: "hintsPopIn")
                }
                panel.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.13; panel.animator().alphaValue = 1 }
            }
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { dismiss(); return }
        guard let ch = event.charactersIgnoringModifiers?.lowercased().first, ch.isLetter else { return }
        typed.append(ch)
        let matches = targets.filter { $0.hint.hasPrefix(typed) }
        if matches.isEmpty { dismiss(); return }
        if matches.count == 1, matches[0].hint == typed {
            let focus = matches[0].target.focus
            dismiss(); focus(); return
        }
        for v in views { v.typed = typed; v.needsDisplay = true }
    }

    private func dismiss() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll(); views.removeAll()
        if HintsOverlay.shared === self { HintsOverlay.shared = nil }
    }
}

/// A borderless panel that can still become key (needed to capture keys for the overlays).
final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

private final class HintsView: NSView {
    var origin = CGPoint.zero          // this screen's Cocoa origin
    var targets: [(hint: String, target: HintTarget)] = []
    var typed = ""

    private var accent: NSColor { Palette.accent }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
        let radius = CGFloat(Config.shared.tabCornerRadius)   // match the theme's square corners
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: accent.withAlphaComponent(0.4)]
        let hot: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: accent]
        for (hint, t) in targets where hint.hasPrefix(typed) {
            let f = t.frameCocoa
            let lx = f.minX - origin.x, ly = f.minY - origin.y
            let up = hint.uppercased()
            let size = (up as NSString).size(withAttributes: hot)
            let padX: CGFloat = 9, chipH = size.height + 8
            let chip = NSRect(x: lx + 8, y: ly + f.height - chipH - 8,
                              width: size.width + padX * 2, height: chipH)

            // Frosted-dark chip + accent hairline, matching the tab bars / switcher / HUD.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 4; shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor.black.withAlphaComponent(0.78).setFill()
            NSBezierPath(roundedRect: chip, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()

            // Neon: accent border + text with an accent glow.
            NSGraphicsContext.saveGraphicsState()
            let neon = NSShadow()
            neon.shadowColor = accent.withAlphaComponent(0.9); neon.shadowBlurRadius = 6; neon.shadowOffset = .zero
            neon.set()
            accent.setStroke()
            let border = NSBezierPath(roundedRect: chip.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
            border.lineWidth = 1.5; border.stroke(); border.stroke()

            // Text: the part you've already typed is dimmed, the rest is bright accent.
            let tx = chip.minX + padX, ty = chip.minY + 4
            let n = min(typed.count, up.count)
            let pfx = String(up.prefix(n)) as NSString
            let rest = String(up.dropFirst(n)) as NSString
            pfx.draw(at: CGPoint(x: tx, y: ty), withAttributes: dim)
            rest.draw(at: CGPoint(x: tx + pfx.size(withAttributes: dim).width, y: ty), withAttributes: hot)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

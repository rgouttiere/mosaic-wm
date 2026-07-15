import AppKit

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

private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

private final class HintsView: NSView {
    var origin = CGPoint.zero          // this screen's Cocoa origin
    var targets: [(hint: String, target: HintTarget)] = []
    var typed = ""

    private let accent = NSColor(srgbRed: 0xa6/255, green: 0xe3/255, blue: 0xa1/255, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
        for (hint, t) in targets where hint.hasPrefix(typed) {
            let f = t.frameCocoa
            let lx = f.minX - origin.x, ly = f.minY - origin.y
            let str = hint.uppercased() as NSString
            let size = str.size(withAttributes: [.font: font])
            let padX: CGFloat = 8, chipH = size.height + 6
            let chip = NSRect(x: lx + 8, y: ly + f.height - chipH - 8,
                              width: size.width + padX * 2, height: chipH)
            accent.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
            str.draw(at: CGPoint(x: chip.minX + padX, y: chip.minY + 3),
                     withAttributes: [.font: font, .foregroundColor: NSColor.black])
        }
    }
}

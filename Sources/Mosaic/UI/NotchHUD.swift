import AppKit
import QuartzCore

/// A dynamic-island-style HUD anchored under the notch (top-center pill on notchless/external
/// displays). On a workspace switch it MORPHS out of a compact rest pill into a frosted panel
/// showing the workspace number + name + its app icons, holds briefly, then recedes. In-place scale
/// only — nothing travels. Opt-in via `notchHud`; consolidates the scattered switch HUDs into one
/// branded surface. Same reused-window pattern as the other overlays.
final class NotchHUD {
    private let window: NSWindow
    private let effect = NSVisualEffectView()
    private let view = NotchHUDView()
    private var hideWork: DispatchWorkItem?
    private var hideGen = 0

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 30),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar          // over app windows and the bar, around the notch
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.ignoresCycle, .canJoinAllSpaces, .stationary]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)
        window.contentView = effect
    }

    /// Show workspace `n` (name + app icons) morphing out of the notch on `screen`.
    func show(workspace n: Int, name: String, icons: [NSImage], on screen: NSScreen) {
        view.number = n; view.name = name; view.icons = icons; view.needsDisplay = true
        let full = view.intrinsicContentSize
        // Anchor the top edge just BELOW the notch (safeAreaInsets.top) so it isn't hidden in the
        // physical cutout — on a notch display it hugs the notch from below; on external/notchless
        // screens the inset is 0, so it sits at the very top as a centered pill.
        let topY = screen.frame.maxY - screen.safeAreaInsets.top
        let fullFrame = NSRect(x: screen.frame.midX - full.width / 2, y: topY - full.height,
                               width: full.width, height: full.height)
        // Compact rest pill (roughly notch-sized) to morph out of.
        let restW = min(full.width, 90), restH = full.height
        let restFrame = NSRect(x: screen.frame.midX - restW / 2, y: topY - restH, width: restW, height: restH)

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        effect.layer?.cornerRadius = full.height / 2
        effect.layer?.masksToBounds = true
        window.orderFrontRegardless()

        hideWork?.cancel(); hideGen += 1; let gen = hideGen
        if reduce {
            window.setFrame(fullFrame, display: true); window.alphaValue = 1
        } else {
            window.setFrame(restFrame, display: false); window.alphaValue = 0.85
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.1, 1.05)  // gentle overshoot
                window.animator().setFrame(fullFrame, display: true)
                window.animator().alphaValue = 1
            }
        }

        // Recede: shrink back to the rest pill and fade out, unless a newer show() supersedes.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hideGen == gen else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                self.window.animator().setFrame(restFrame, display: true)
                self.window.animator().alphaValue = 0
            } completionHandler: { if self.hideGen == gen { self.window.orderOut(nil) } }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    func hide() { hideWork?.cancel(); hideGen += 1; window.orderOut(nil) }
}

private final class NotchHUDView: NSView {
    var number = 1
    var name = ""
    var icons: [NSImage] = []

    private let barH: CGFloat = 30, pad: CGFloat = 13, gap: CGFloat = 8
    private let iconSize: CGFloat = 18, iconGap: CGFloat = 4, maxIcons = 5
    private var numFont: NSFont { .systemFont(ofSize: 15, weight: .bold) }
    private var nameFont: NSFont { .systemFont(ofSize: 13, weight: .medium) }

    override var isFlipped: Bool { false }

    private var iconsWidth: Int { min(icons.count, maxIcons) }
    private func iconsPixelWidth() -> CGFloat {
        let n = iconsWidth
        guard n > 0 else { return 0 }
        var w = CGFloat(n) * iconSize + CGFloat(n - 1) * iconGap
        if icons.count > maxIcons { w += iconGap + 14 }
        return w
    }

    override var intrinsicContentSize: NSSize {
        let numW = ("\(number)" as NSString).size(withAttributes: [.font: numFont]).width
        let nameW = name.isEmpty ? 0 : (name as NSString).size(withAttributes: [.font: nameFont]).width + gap
        let iw = iconsPixelWidth()
        let iconsPart = iw > 0 ? iw + gap : 0
        return NSSize(width: pad * 2 + numW + nameW + iconsPart, height: barH)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.34).setFill()   // tint over the frosted material
        bounds.fill()

        var x = pad
        // Workspace number in accent.
        let numAttrs: [NSAttributedString.Key: Any] = [.font: numFont, .foregroundColor: Palette.accent]
        let numStr = "\(number)" as NSString
        let numSize = numStr.size(withAttributes: numAttrs)
        numStr.draw(at: NSPoint(x: x, y: bounds.midY - numSize.height / 2), withAttributes: numAttrs)
        x += numSize.width + gap

        // Name in crème.
        if !name.isEmpty {
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: Palette.text]
            let nameStr = name as NSString
            let nameSize = nameStr.size(withAttributes: nameAttrs)
            nameStr.draw(at: NSPoint(x: x, y: bounds.midY - nameSize.height / 2), withAttributes: nameAttrs)
            x += nameSize.width + gap
        }

        // App icons row.
        for icon in icons.prefix(maxIcons) {
            icon.draw(in: NSRect(x: x, y: bounds.midY - iconSize / 2, width: iconSize, height: iconSize))
            x += iconSize + iconGap
        }
        if icons.count > maxIcons {
            let extra = "+\(icons.count - maxIcons)" as NSString
            let ea: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                      .foregroundColor: Palette.subtext]
            extra.draw(at: NSPoint(x: x, y: bounds.midY - 7), withAttributes: ea)
        }
    }
}

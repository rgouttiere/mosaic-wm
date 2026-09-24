import AppKit

/// Opaque bars that fill the gap between a tile and a window that doesn't fill it (e.g. IINA
/// keeping its video aspect). macOS refuses to move a parked window fully off-screen — it keeps a
/// ~40px strip — and that strip pokes through a letterboxed tile's uncovered gap. The gap never
/// overlaps the window, so a bar at `.floating` (above every app window) covers the strip WITHOUT
/// covering the video. Style: plain black, or a static "matrix" rune rain (config `letterboxStyle`).
/// A small reused pool: each render claims the bars it needs via `fill`, `end` hides the leftovers.
final class LetterboxFill {
    private var pool: [NSWindow] = []
    private var used = 0

    /// Start a render pass — reset the claim counter.
    func begin() { used = 0 }

    /// Cover `rect` (Cocoa coords) with an opaque bar, reusing a pooled window.
    func fill(_ rect: NSRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        let w: NSWindow
        if used < pool.count { w = pool[used] } else { w = makeBar(); pool.append(w) }
        used += 1
        w.setFrame(rect, display: false)   // a size change repaints the view; a steady bar re-draws nothing
        w.orderFrontRegardless()
    }

    /// Finish the pass — hide bars this render didn't claim.
    func end() {
        for i in used..<pool.count { pool[i].orderOut(nil) }
    }

    func hideAll() { for w in pool { w.orderOut(nil) }; used = 0 }

    private func makeBar() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = true
        win.backgroundColor = .black
        win.hasShadow = false
        win.level = .floating           // above app windows so it covers a parked window's residual strip
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.ignoresCycle, .stationary]
        let v = MatrixView()
        v.autoresizingMask = [.width, .height]
        win.contentView = v
        return win
    }
}

/// A static "digital rain" of runic glyphs on black, drawn once per size (deterministic, so no
/// flicker and no animation). Falls back to plain black when `letterboxStyle` isn't "matrix".
private final class MatrixView: NSView {
    override var isFlipped: Bool { true }   // row 0 at top, streaks brighten downward toward their head

    // Elder-Futhark-ish runes, to match the Matrix-rune look.
    private static let glyphs = Array("ᚠᚢᚦᚨᚱᚲᚷᚹᚺᚾᛁᛃᛇᛈᛉᛊᛏᛒᛖᛗᛚᛜᛞᛟᛝᚻᚼᚽᛘᛦ")

    /// SplitMix64 — a stable hash so the pattern is fixed (a frozen frame of rain), never random per draw.
    private func rnd(_ s: UInt64) -> UInt64 {
        var z = s &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard Config.shared.letterboxStyle.lowercased() == "matrix",
              bounds.width > 4, bounds.height > 4 else { return }

        let cellW: CGFloat = 12, cellH: CGFloat = 15   // tight cells → dense columns
        let cols = Int(bounds.width / cellW) + 1
        let rows = max(1, Int(bounds.height / cellH) + 1)
        let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .bold)
        let green = Palette.accent
        let head0 = (green.blended(withFraction: 0.55, of: .white) ?? green).withAlphaComponent(0.85)

        // Every cell gets a glyph — a faint, textured base fills the black; brighter along each
        // column's streaks. Texture comes from: 1–3 streaks per column, coarse block-level
        // modulation (cloudy light/dark patches), and sparse flares — not one flat wash.
        for c in 0..<cols {
            let cseed = rnd(UInt64(bitPattern: Int64(c)) &* 2654435761)
            let nHeads = 1 + Int(cseed % 2)               // 1–2 distinct falling streaks per column
            var heads: [(row: Int, trail: Int)] = []
            for h in 0..<nHeads {
                let hs = rnd(cseed &+ UInt64(h) &* 0x9E3779B97F4A7C15)
                heads.append((Int(hs % UInt64(rows)), 10 + Int((hs >> 8) % 26)))   // longer comet tails
            }
            for r in 0..<rows {
                let cellSeed = rnd(cseed &+ UInt64(r) &* 6364136223846793005)
                // Coarse 4×4-block modulation → cloudy patches instead of a uniform fill.
                let region = 0.5 + CGFloat(rnd(UInt64(c / 4) &* 73856093 &+ UInt64(r / 4) &* 19349663) % 100) / 100 * 0.75
                var streak: CGFloat = 0
                for hd in heads {
                    let dist = hd.row - r
                    if dist >= 0 && dist <= hd.trail { streak = max(streak, 1 - CGFloat(dist) / CGFloat(hd.trail)) }
                }
                // Dim textured base so the bright falling streaks read clearly against it.
                var base = (0.05 + CGFloat(cellSeed % 100) / 100 * 0.10) * region
                if cellSeed % 37 == 0 { base = max(base, 0.30) }   // sparse flares (rarer, dimmer)
                let onHead = heads.contains { $0.row == r }
                let bright = max(base, streak)
                guard bright > 0.05 else { continue }
                let gi = Int((cellSeed >> 20) % UInt64(MatrixView.glyphs.count))
                let color = onHead ? head0
                    : green.withAlphaComponent(streak > base ? min(0.85, streak * 0.85)   // bright comet tail
                                                             : min(0.35, base))            // faint base
                (String(MatrixView.glyphs[gi]) as NSString).draw(
                    at: CGPoint(x: CGFloat(c) * cellW + 1, y: CGFloat(r) * cellH),
                    withAttributes: [.font: font, .foregroundColor: color])
            }
        }

        // Neon Apple logo centered — the  glyph (U+F8FF) as a glowing green OUTLINE.
        let logoSize = min(bounds.width, bounds.height) * 0.5
        if logoSize > 24 {
            let logo = "\u{F8FF}" as NSString
            let lf = NSFont.systemFont(ofSize: logoSize)
            let neon = green.blended(withFraction: 0.35, of: .white) ?? green
            let glow = NSShadow(); glow.shadowColor = green.withAlphaComponent(0.9)
            glow.shadowBlurRadius = logoSize * 0.12; glow.shadowOffset = .zero   // tighter halo
            let attrs: [NSAttributedString.Key: Any] = [
                .font: lf, .foregroundColor: NSColor.clear,   // outline only
                .strokeColor: neon, .strokeWidth: 2.0, .shadow: glow]           // thinner outline
            let ts = logo.size(withAttributes: [.font: lf])
            let pt = CGPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - ts.height / 2)
            logo.draw(at: pt, withAttributes: attrs)   // twice → the glow builds up brighter
            logo.draw(at: pt, withAttributes: attrs)
        }
    }
}

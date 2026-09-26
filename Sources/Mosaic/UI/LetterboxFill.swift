import AppKit
import CoreText

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
///
/// Drawn with Core Text, batched by shade — NOT one `NSString.draw` per cell. That earlier form
/// cost **32 ms for a single 1720x205 bar** (~2000 cells, each rebuilding the whole text-layout
/// stack) and IINA's tile carries two of them, so every letterboxed tile that changed size paid
/// ~64 ms of main-thread drawing before the next frame — felt as a stall when tabbing to IINA.
/// Same pattern, same pixels, ~15x cheaper.
private final class MatrixView: NSView {
    override var isFlipped: Bool { true }   // row 0 at top, streaks brighten downward toward their head

    // Elder-Futhark-ish runes, to match the Matrix-rune look.
    private static let glyphs = Array("ᚠᚢᚦᚨᚱᚲᚷᚹᚺᚾᛁᛃᛇᛈᛉᛊᛏᛒᛖᛗᛚᛜᛞᛟᛝᚻᚼᚽᛘᛦ")

    private static let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .bold)

    /// The covering font and glyph id of each rune, resolved ONCE. The monospaced system font has
    /// no runes: `NSString.draw` falls back to AppleSymbols silently, `CTFontDrawGlyphs` does not —
    /// it would draw glyph 0, i.e. nothing at all. Resolving up front also lets `draw` group its
    /// batches by font, since a cascade could in principle answer with more than one.
    private static let runes: (fonts: [CTFont], cells: [(font: Int, glyph: CGGlyph)]) = {
        let base = font as CTFont
        var fonts: [CTFont] = []
        var cells: [(font: Int, glyph: CGGlyph)] = []
        for g in glyphs {
            let s = String(g) as CFString
            let f = CTFontCreateForString(base, s, CFRange(location: 0, length: CFStringGetLength(s)))
            let idx: Int
            if let i = fonts.firstIndex(where: { CFEqual($0, f) }) { idx = i }
            else { fonts.append(f); idx = fonts.count - 1 }
            var chars = Array(String(g).utf16)
            var ids = [CGGlyph](repeating: 0, count: chars.count)
            CTFontGetGlyphsForCharacters(f, &chars, &ids, chars.count)
            cells.append((idx, ids[0]))
        }
        return (fonts, cells)
    }()

    /// Alpha steps the rain is quantized to. The brightness is continuous, but colour is context
    /// state: one glyph per fill colour means one draw call per cell. 16 steps collapses a whole
    /// bar to ~17 batched calls and is indistinguishable on a dim rune rain.
    private static let shades = 16

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
              bounds.width > 4, bounds.height > 4,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        let cellW: CGFloat = 12, cellH: CGFloat = 15   // tight cells → dense columns
        let cols = Int(bounds.width / cellW) + 1
        let rows = max(1, Int(bounds.height / cellH) + 1)
        let green = Palette.accent
        let head0 = (green.blended(withFraction: 0.55, of: .white) ?? green).withAlphaComponent(0.85)

        let (fonts, runes) = MatrixView.runes
        let shades = MatrixView.shades
        // Glyph positions are expressed in the un-flipped space installed just before the draw
        // below, so row r's baseline sits at height − (r·cellH + ascent).
        let ascent = CTFontGetAscent(MatrixView.font as CTFont)
        let height = bounds.height
        // [font][shade] → the cells to draw in one call; shade == `shades` is the streak head.
        var batch = [[[(glyph: CGGlyph, at: CGPoint)]]](
            repeating: [[(glyph: CGGlyph, at: CGPoint)]](repeating: [], count: shades + 1),
            count: fonts.count)

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
                guard max(base, streak) > 0.05 else { continue }
                let gi = Int((cellSeed >> 20) % UInt64(MatrixView.glyphs.count))
                let alpha = streak > base ? min(0.85, streak * 0.85)   // bright comet tail
                                          : min(0.35, base)            // faint base
                let shade = onHead ? shades : max(0, min(shades - 1, Int(alpha * CGFloat(shades))))
                let rune = runes[gi]
                batch[rune.font][shade].append(
                    (rune.glyph, CGPoint(x: CGFloat(c) * cellW + 1,
                                         y: height - (CGFloat(r) * cellH + ascent))))
            }
        }

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: height); ctx.scaleBy(x: 1, y: -1)   // undo the view's flip for text
        for (fi, perShade) in batch.enumerated() {
            for (shade, cells) in perShade.enumerated() where !cells.isEmpty {
                let color = shade == shades ? head0
                    : green.withAlphaComponent((CGFloat(shade) + 0.5) / CGFloat(shades))
                ctx.setFillColor(color.cgColor)
                var glyphs = cells.map(\.glyph)
                var points = cells.map(\.at)
                CTFontDrawGlyphs(fonts[fi], &glyphs, &points, glyphs.count, ctx)
            }
        }
        ctx.restoreGState()

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

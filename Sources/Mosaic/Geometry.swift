import AppKit

/// macOS has two coordinate systems we must bridge constantly:
///   • Cocoa (AppKit/NSScreen/NSWindow): origin bottom-left, y grows upward.
///   • Accessibility (AXUIElement): origin top-left of the primary display, y grows downward.
/// `flip` converts a rect between the two. It is its own inverse.
enum Geometry {
    /// Height of the primary display (the one whose Cocoa origin is (0,0)).
    static var primaryHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    static func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryHeight - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }

    /// Does `window` cover the whole of `screen`? Both in AX/CG coordinates. A couple of points
    /// of slack, because a game that rounds its size to the display mode shouldn't miss by a
    /// pixel — and nothing smaller than the screen can qualify, whatever the slack. Pure +
    /// unit-tested; see `WindowManager.coveredDisplays` for what it is used for.
    static func covers(screen: CGRect, window: CGRect) -> Bool {
        guard screen.width > 4, screen.height > 4 else { return false }
        return window.contains(screen.insetBy(dx: 2, dy: 2))
    }

    /// A learned tile minimum is never allowed past this share of the pair it belongs to. Strictly
    /// below 1/2 by construction — see `resizeLimits`.
    static let maxLearnedMinShare: CGFloat = 0.45

    /// Travel limits for the split point between two adjacent tiles, as ratios of their parent.
    ///
    /// `pair` is the two tiles' ratios summed, `axis` the parent's extent along the split, and
    /// `minI`/`minJ` each tile's known minimum in POINTS (nil → the 60pt baseline). Each minimum is
    /// capped at `maxLearnedMinShare` of the pair, which is strictly below half, so `lo < hi` always
    /// holds. Capping at half instead let two large minimums meet at `pair/2`: the range collapsed
    /// to a single point and the divider froze dead centre, unmovable by mouse OR keyboard until the
    /// learned minimums were dropped. Pure + unit-tested.
    static func resizeLimits(pair: CGFloat, axis: CGFloat,
                             minI: CGFloat?, minJ: CGFloat?) -> (lo: CGFloat, hi: CGFloat) {
        guard pair > 0, axis > 0 else { return (0, 0) }
        let cap = pair * maxLearnedMinShare
        let lo = min(cap, max(0.05, (minI ?? 60) / axis))
        let hi = pair - min(cap, max(0.05, (minJ ?? 60) / axis))
        return (lo, hi)
    }

    /// Has a window escaped the tile it was laid out in? A window is allowed to be SMALLER than its
    /// tile (an aspect-locked player letterboxes inside it), so this asks only whether it pokes
    /// OUTSIDE — which no correctly-placed tile window ever does. That single test catches the whole
    /// family: a leaf stranded at a park position, a tile computed for the wrong monitor, a frame
    /// write that macOS clamped. `tolerance` absorbs the pixel of slack apps add around themselves.
    /// Pure + unit-tested.
    static func escapesTile(window: CGRect, tile: CGRect, tolerance: CGFloat = 8) -> Bool {
        guard tile.width > 0, tile.height > 0 else { return false }
        return window.minX < tile.minX - tolerance
            || window.minY < tile.minY - tolerance
            || window.maxX > tile.maxX + tolerance
            || window.maxY > tile.maxY + tolerance
    }

    /// Which of the two AX writes to issue FIRST when re-framing a window: position, or size.
    ///
    /// The two attributes are written separately, so the window briefly exists at a mixed
    /// old/new geometry — and macOS clamps a window that lands past a screen edge. Moving a window
    /// that is still LARGE to its new origin can therefore get the origin clamped, and the size
    /// write that follows lands on that clamped origin: the window ends up offset from its tile.
    /// So shrink first, then move. Growing needs the opposite: move into the free space first,
    /// then grow, or the larger size is applied at the old origin and clamped instead.
    ///
    /// `current` unknown → keep position-first, the long-standing order. Pure + unit-tested.
    static func positionFirst(current: CGRect?, target: CGRect) -> Bool {
        guard let current else { return true }
        return target.width > current.width + 0.5 || target.height > current.height + 0.5
    }

    /// The largest box of the given width/height `aspect` that fits inside `tile`, centred. Used to
    /// place an aspect-locked window (IINA) inside its tile without overshooting — the leftover gap is
    /// letterboxed. `aspect` ≤ 0 or a degenerate tile → the tile unchanged. Pure + unit-tested.
    static func aspectFit(_ tile: CGRect, aspect: CGFloat) -> CGRect {
        guard aspect > 0, tile.width > 0, tile.height > 0 else { return tile }
        let tileAspect = tile.width / tile.height
        var w = tile.width, h = tile.height
        if tileAspect > aspect { w = tile.height * aspect }   // tile wider than content → pillarbox
        else { h = tile.width / aspect }                      // tile taller than content → letterbox
        return CGRect(x: tile.minX + (tile.width - w) / 2,
                      y: tile.minY + (tile.height - h) / 2,
                      width: w, height: h)
    }

    /// Emulated-workspace parking (v2): the Cocoa rect a parked workspace is laid out in — pushed
    /// off the edge of ITS OWN home monitor that faces empty space (no adjacent screen), so macOS'
    /// clamp lands the residual ~40px strip on that same monitor. This is the crux of the two bugs
    /// it fixes:
    ///   • RESIZE ON RETURN. macOS clamps an off-screen window to the nearest *visible* monitor.
    ///     The old code pushed every workspace to the desktop's far-right edge, so a workspace
    ///     living on a 1440p monitor landed on a shorter 1080p neighbour and got clamped to 1080p —
    ///     coming back shorter every park/unpark. Pushing off the home monitor's OWN edge keeps the
    ///     window within that monitor's span, so there is no cross-resolution clamp and no resize.
    ///   • 1080p / "random shift". Same root: foreign-sized windows never land on the small screen.
    ///
    /// Direction is chosen so the push is a translation along an axis the home monitor's own extent
    /// covers — never a corner (a corner push clamps BOTH axes and shrinks height):
    ///   • rightmost monitor  → off its right edge  (void to the right)  → 40px sliver, right edge
    ///   • leftmost monitor   → off its left edge   (void to the left)   → 40px sliver, left edge
    ///   • interior monitor   → straight DOWN off its bottom edge        → 40px band, bottom edge
    ///
    /// `layoutRect` is the on-screen tiling rect (what unpark restores); `screenFrame` is the home
    /// monitor's Cocoa frame; `desktop` is the union of all screens' frames. Pure + unit-tested.
    static func parkRect(layoutRect: CGRect, screenFrame: CGRect, desktop: CGRect) -> CGRect {
        let onRightEdge = screenFrame.maxX >= desktop.maxX - 1
        let onLeftEdge  = screenFrame.minX <= desktop.minX + 1
        if onRightEdge {   // push off this monitor's right edge — same monitor, no resize
            return CGRect(x: screenFrame.maxX, y: layoutRect.minY,
                          width: layoutRect.width, height: layoutRect.height)
        }
        if onLeftEdge {    // push off this monitor's left edge
            return CGRect(x: screenFrame.minX - layoutRect.width, y: layoutRect.minY,
                          width: layoutRect.width, height: layoutRect.height)
        }
        // Interior monitor (neighbours on both sides): the only void edge is the bottom. Push
        // straight down — X and width untouched, so no horizontal clamp and no height shrink.
        return CGRect(x: layoutRect.minX, y: screenFrame.minY - layoutRect.height,
                      width: layoutRect.width, height: layoutRect.height)
    }

    /// Among `candidates`, the frame closest to `saved` — if one is close enough to be the same
    /// window: size within `sizeTolerance` on both axes, origin within `originTolerance` (apps that
    /// restore their own geometry after a reboot may land a few points off). nil when none qualifies.
    /// Pure, so a restore scenario is three lines in a self-test.
    static func frameMatchIndex(saved: CGRect, candidates: [CGRect],
                                sizeTolerance: CGFloat = 6, originTolerance: CGFloat = 60) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, c) in candidates.enumerated() where !c.isNull {
            guard abs(c.width - saved.width) <= sizeTolerance, abs(c.height - saved.height) <= sizeTolerance,
                  abs(c.minX - saved.minX) <= originTolerance, abs(c.minY - saved.minY) <= originTolerance else { continue }
            let d = abs(c.minX - saved.minX) + abs(c.minY - saved.minY) + abs(c.width - saved.width) + abs(c.height - saved.height)
            if best == nil || d < best!.distance { best = (i, d) }
        }
        return best?.index
    }
}

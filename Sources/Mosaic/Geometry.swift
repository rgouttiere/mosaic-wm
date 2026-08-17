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
    /// `underBar` (experiment): push straight UP off the monitor's own top edge instead, so the
    /// residual sliver lands at the top where an opaque top bar (sketchybar) covers it. macOS
    /// protects the title bar from leaving the top, so this MAY keep more of the window on-screen
    /// than a down/side push — it's gated behind config and validated on real hardware.
    ///
    /// `layoutRect` is the on-screen tiling rect (what unpark restores); `screenFrame` is the home
    /// monitor's Cocoa frame; `desktop` is the union of all screens' frames. Pure + unit-tested.
    static func parkRect(layoutRect: CGRect, screenFrame: CGRect, desktop: CGRect, underBar: Bool = false) -> CGRect {
        if underBar {   // push up: bottom of window at the monitor's top edge, same X/size → no resize
            return CGRect(x: layoutRect.minX, y: screenFrame.maxY,
                          width: layoutRect.width, height: layoutRect.height)
        }
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
}

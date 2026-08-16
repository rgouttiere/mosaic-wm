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

    /// Emulated-workspace parking (v2): the Cocoa rect a parked workspace is laid out in —
    /// off the visible desktop, past the global BOTTOM-RIGHT corner. macOS refuses to place a
    /// window *fully* off-screen and clamps it back toward the nearest screen edge; a window
    /// pushed straight down keeps a full-width strip visible at the bottom (its nearest edge is
    /// the whole bottom), so we push it off BOTH the right and the bottom — then the nearest
    /// point is a single corner and only a ~1px corner sliver can remain (the AeroSpace-
    /// documented limit, mitigated by an auto-hiding Dock).
    ///
    /// Sized like the target screen (not squished) so unparking is a pure translation back —
    /// every window keeps the exact frame it had while parked, and `setCocoaFrame`'s cache
    /// then skips windows whose on-screen frame is unchanged. Pure + unit-tested.
    ///
    /// `screenFrame` is the destination screen's Cocoa frame; `desktop` is the union of all
    /// screens' Cocoa frames (the whole visible area to clear). The slab's top-left corner sits
    /// exactly on the desktop's bottom-right corner and extends down-and-right, off every screen.
    static func parkRect(screenFrame: CGRect, desktop: CGRect) -> CGRect {
        // Cocoa origin is bottom-left; the desktop's bottom-right corner is (maxX, minY). Put
        // the slab's TOP-left there (origin.y = corner.y - height) so it spills down and right.
        CGRect(x: desktop.maxX,
               y: desktop.minY - screenFrame.height,
               width: screenFrame.width,
               height: screenFrame.height)
    }
}

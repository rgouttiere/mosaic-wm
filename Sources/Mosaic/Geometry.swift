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
    /// off the visible desktop, past the global bottom-right corner. macOS refuses to place a
    /// window *fully* off-screen (a ~1px sliver always remains, an AeroSpace-documented limit
    /// mitigated by an auto-hiding Dock), so we push far enough that only that sliver shows.
    ///
    /// Sized like the target screen (not squished) so unparking is a pure translation back —
    /// every window keeps the exact frame it had while parked, and `setCocoaFrame`'s cache
    /// then skips windows whose on-screen frame is unchanged. Pure + unit-tested.
    ///
    /// `screenFrame` is the destination screen's Cocoa frame; `desktop` is the union of all
    /// screens' Cocoa frames (the whole visible area to clear).
    static func parkRect(screenFrame: CGRect, desktop: CGRect) -> CGRect {
        // Drop the whole slab just below the desktop's bottom edge (Cocoa y grows up, so
        // "below" = smaller y). One row down clears every screen; keep x aligned to the
        // screen so per-window offsets from on-screen to parked are a clean vertical shift.
        CGRect(x: screenFrame.origin.x,
               y: desktop.minY - screenFrame.height,
               width: screenFrame.width,
               height: screenFrame.height)
    }
}

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
    /// off the visible desktop, past its RIGHT edge. This is a PURE HORIZONTAL TRANSLATION of the
    /// on-screen layout rect: same size and same Y, shifted right until it clears every screen.
    /// Two reasons it must be horizontal-only, not a bottom/corner push:
    ///   • macOS clamps an off-screen window back toward the nearest edge. Pushed straight down,
    ///     it keeps a full-width bottom strip; pushed to the bottom-right *corner*, macOS also
    ///     shrinks its HEIGHT to keep it within vertical bounds — so windows came back shorter on
    ///     every park/unpark. Pushed only sideways, Y is untouched → the window keeps its exact
    ///     height, and unpark is the exact reverse shift (no resize at all).
    ///   • The remaining ~1px sliver lands on the far-right edge, clear of a bottom Dock.
    ///
    /// `layoutRect` is the on-screen tiling rect for the destination screen; `desktop` is the
    /// union of all screens' Cocoa frames. Pure + unit-tested.
    static func parkRect(layoutRect: CGRect, desktop: CGRect) -> CGRect {
        CGRect(x: desktop.maxX,
               y: layoutRect.minY,
               width: layoutRect.width,
               height: layoutRect.height)
    }
}

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
}

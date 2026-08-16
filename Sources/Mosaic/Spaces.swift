import AppKit

// v2 (emulated workspaces) dropped Mosaic's dependency on the private CGS *Spaces* SPI: there
// is a single macOS Space and the window manager owns every window's position, so it no longer
// reads or switches the current desktop. The only private call left is window alpha — a purely
// cosmetic dim of unfocused tiles, unrelated to Spaces — kept here behind the same façade.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSSetWindowAlpha")
private func CGSSetWindowAlpha(_ cid: Int32, _ wid: CGWindowID, _ alpha: Float) -> Int32

enum Spaces {
    /// Set a window's opacity (private API; used to dim unfocused windows).
    static func setAlpha(_ window: CGWindowID, _ alpha: Float) {
        _ = CGSSetWindowAlpha(CGSMainConnectionID(), window, alpha)
    }
}

import AppKit

// v2 (emulated workspaces) dropped Mosaic's dependency on the private CGS *Spaces* SPI: there
// is a single macOS Space and the window manager owns every window's position, so it no longer
// reads or switches the current desktop. The only private call left is window alpha — a purely
// cosmetic dim of unfocused tiles, unrelated to Spaces — kept here behind the same façade.
enum Spaces {
    /// Set a window's opacity (private API; used to dim unfocused windows). Resolved at runtime
    /// (`PrivateAPI`): should Apple drop it, dimming silently stops and nothing else does.
    static func setAlpha(_ window: CGWindowID, _ alpha: Float) {
        guard let cid = PrivateAPI.cgsMainConnectionID, let set = PrivateAPI.cgsSetWindowAlpha else { return }
        _ = set(cid(), window, alpha)
    }
}

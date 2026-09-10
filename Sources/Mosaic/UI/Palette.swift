import AppKit

/// The single source of truth for Mosaic's overlay colours. `accent` follows `accentColor` in the
/// config (system accent or a pinned hex); the neutrals are the crisp dark-theme set every overlay
/// shares — exposé, switcher, HUD, hints, drag ghost. Change the accent once and the whole UI
/// re-themes together, instead of the green being hardcoded in four separate files.
enum Palette {
    /// The configured accent. Recomputed on each access so config hot-reload takes effect live.
    static var accent: NSColor { Config.shared.accentNSColor }

    static let text      = NSColor(srgbRed: 0xf9/255, green: 0xf8/255, blue: 0xf5/255, alpha: 1)  // primary label (crème)
    static let subtext   = NSColor(srgbRed: 0xa8/255, green: 0x99/255, blue: 0x84/255, alpha: 1)  // secondary label
    static let surface   = NSColor(srgbRed: 0x2a/255, green: 0x2a/255, blue: 0x2a/255, alpha: 1)  // panel / tile background
    static let ink       = NSColor(srgbRed: 0x14/255, green: 0x18/255, blue: 0x14/255, alpha: 1)  // dark text on the accent
    static let schematic = NSColor(srgbRed: 0x45/255, green: 0x47/255, blue: 0x5a/255, alpha: 1)  // exposé window fallback fill
}

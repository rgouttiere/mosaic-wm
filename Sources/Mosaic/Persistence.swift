import Foundation

/// On-disk representation of the layout, saved to ~/.config/mosaic/state.json and
/// restored on launch. Windows are referenced by CGWindowID (stable while the app
/// keeps running) with bundle id + title as a fallback across restarts.
struct SavedWindow: Codable {
    var windowID: UInt32?
    var bundleID: String?
    var title: String?
}

struct SavedNode: Codable {
    var window: SavedWindow?     // present → leaf
    var layout: String?          // present → container: "splitH" | "splitV" | "tabbed"
    var ratios: [Double]?
    var selected: Int?
    var stacked: Bool?           // tabbed rendered as a vertical stacking list
    var children: [SavedNode]?
}

struct SavedSpace: Codable {
    var displayID: UInt32
    var mode: String
    var tree: SavedNode?
    /// Stable per-monitor identity (CGDisplay UUID). Unlike `displayID` and the macOS
    /// Space id, it survives dock/undock and reboot, so a layout can be re-matched to
    /// the same physical display at a different location. Optional = older saves.
    var displayUUID: String?
    /// This desktop's index among its display's Spaces (0-based). With `displayUUID`
    /// it identifies "the Nth desktop of this monitor" across sessions.
    var spaceOrdinal: Int?
}

struct SavedState: Codable {
    var spaces: [String: SavedSpace]            // key = String(spaceID)
    var assignments: [String: UInt64]?          // key = String(workspace number) → spaceID
    var assignmentApps: [String: String]?       // key = String(workspace number) → app bundle id
    var scratchpadBundle: String?               // scratchpad app bundle id
}

/// A per-app auto-placement rule from config. `app` is matched (case-insensitive
/// substring) against the app name or bundle id when a window opens.
struct AppRule: Codable {
    var app: String
    var float: Bool?
    var groupWith: String?       // app name to auto-tab this window with, if present
    var place: String?           // "column" | "tab" | (default: next to focused)
    var workspace: Int?          // send this app's new windows to workspace N (must be assigned)
}

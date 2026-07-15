import AppKit
import Carbon.HIToolbox

// Private SkyLight SPI (same approach as yabai): there is no public API to read or
// change the current macOS Space (desktop).
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSManagedDisplayGetCurrentSpace")
private func CGSManagedDisplayGetCurrentSpace(_ cid: Int32, _ displayUUID: CFString) -> UInt64

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray

@_silgen_name("CGSMoveWindowsToManagedSpace")
private func CGSMoveWindowsToManagedSpace(_ cid: Int32, _ windows: CFArray, _ space: UInt64)

@_silgen_name("CGSSetWindowAlpha")
private func CGSSetWindowAlpha(_ cid: Int32, _ wid: CGWindowID, _ alpha: Float) -> Int32

// Space type via CGSSpaceGetType: 0 = user desktop, 2 = system. Native-fullscreen is 1 on
// older macOS but 4 on macOS 26 (Tahoe) — treat both as fullscreen.
@_silgen_name("CGSSpaceGetType")
private func CGSSpaceGetType(_ cid: Int32, _ space: UInt64) -> Int32

enum Spaces {
    /// The id of the Space currently shown on `screen` (0 → nil on failure).
    static func currentSpaceID(for screen: NSScreen) -> UInt64? {
        guard let uuid = displayUUID(screen) else { return nil }
        let space = CGSManagedDisplayGetCurrentSpace(CGSMainConnectionID(), uuid as CFString)
        return space == 0 ? nil : space
    }

    /// Raw CGS type of a Space (0 = user desktop, 1 = native-fullscreen, 2 = system).
    static func spaceType(_ space: UInt64) -> Int32 {
        CGSSpaceGetType(CGSMainConnectionID(), space)
    }

    /// True if the Space is a native-fullscreen Space (an app occupying its own desktop).
    /// Fullscreen reports as 1 (pre-Tahoe) or 4 (macOS 26); user = 0, system = 2.
    static func isFullscreenSpace(_ space: UInt64) -> Bool {
        let t = CGSSpaceGetType(CGSMainConnectionID(), space)
        return t == 1 || t == 4
    }

    /// Space ids of `screen`'s display, in desktop order (left→right in Mission Control).
    static func orderedSpaceIDs(for screen: NSScreen) -> [UInt64] {
        guard let current = currentSpaceID(for: screen) else { return [] }
        let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
        for display in displays {
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).compactMap(spaceID)
            if spaces.contains(current) { return spaces }   // the block holding our display
        }
        return []
    }

    /// Every Space id that currently exists across all displays (Mission Control desktops).
    /// Empty only if the private API returned nothing — callers must treat empty as "unknown"
    /// and not act on it (never prune state on an empty result).
    static func allSpaceIDs() -> Set<UInt64> {
        let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
        var ids = Set<UInt64>()
        for display in displays {
            for s in (display["Spaces"] as? [[String: Any]] ?? []) {
                if let id = spaceID(s) { ids.insert(id) }
            }
        }
        return ids
    }

    /// Move a window to another Space (private API; best-effort).
    static func move(window: CGWindowID, toSpace space: UInt64) {
        let array = [NSNumber(value: window)] as CFArray
        CGSMoveWindowsToManagedSpace(CGSMainConnectionID(), array, space)
    }

    /// Set a window's opacity (private API; used to dim unfocused windows).
    static func setAlpha(_ window: CGWindowID, _ alpha: Float) {
        _ = CGSSetWindowAlpha(CGSMainConnectionID(), window, alpha)
    }

    /// Step `delta` desktops left/right by synthesizing the native ⌃←/⌃→ shortcut
    /// (fallback for switching to an empty desktop). Relies on Mission Control's
    /// keyboard shortcuts being enabled.
    static func step(by delta: Int) {
        guard delta != 0 else { return }
        let key = CGKeyCode(delta > 0 ? kVK_RightArrow : kVK_LeftArrow)
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<abs(delta) {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
                down.flags = .maskControl
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
                up.flags = .maskControl
                up.post(tap: .cghidEventTap)
            }
        }
    }

    private static func displayUUID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func spaceID(_ dict: [String: Any]) -> UInt64? {
        if let v = dict["ManagedSpaceID"] as? Int { return UInt64(v) }
        if let v = dict["id64"] as? Int { return UInt64(v) }
        if let v = dict["id"] as? Int { return UInt64(v) }
        return nil
    }
}

import AppKit
import ApplicationServices

/// Thin Swift wrappers over the C Accessibility API (`AXUIElement`).
/// This is the only sanctioned way on macOS to move/resize other apps' windows
/// without disabling SIP — the same foundation Amethyst is built on.
enum AX {

    /// Cap how long ANY Accessibility call may wait on another app.
    ///
    /// Every AX call is a synchronous round-trip into the target application. When that app stops
    /// answering — beachball, heavy swap, still launching — the call doesn't fail fast: it waits out
    /// the system default, which is measured in seconds, and Mosaic's main thread waits with it. A
    /// render makes dozens of these calls across every tiled app, so one unresponsive app freezes
    /// the whole window manager. (The 50ms frame cache only blunts ordinary slowness; it cannot help
    /// when an app answers nothing at all.)
    ///
    /// Passing the SYSTEM-WIDE element sets the default for every other element, so this one call at
    /// startup covers all of them. 1.5s is far above any healthy round-trip yet short enough that a
    /// stuck app costs a hitch instead of a hang. A call cut short reads as a failed AX write, which
    /// `setCocoaFrame` already handles by not advancing its cache — so the next render re-issues it.
    static func installMessagingTimeout(_ seconds: Float = 1.5) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }


    /// A window belonging to some application, identified by its AX element.
    struct WindowRef {
        let element: AXUIElement
        let pid: pid_t
    }

    // MARK: Attribute reads

    static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    static func title(_ element: AXUIElement) -> String {
        copy(element, kAXTitleAttribute as String) ?? ""
    }

    static func subrole(_ element: AXUIElement) -> String? {
        copy(element, kAXSubroleAttribute as String)
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard
            let posValue: AXValue = copy(element, kAXPositionAttribute as String),
            let sizeValue: AXValue = copy(element, kAXSizeAttribute as String)
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &point)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    // MARK: Attribute writes

    /// Returns whether the write was accepted (`.success`). An app can transiently reject a
    /// move (`kAXErrorCannotComplete`/`APIDisabled` right after wake or launch while its AX
    /// server is busy); the caller uses this to avoid caching a position the window never took
    /// — otherwise the `<1px` skip would suppress the retry and the tile stays mis-placed with
    /// no self-heal. Note `.success` means *accepted*, not *pixel-applied*: apps that clamp to
    /// a min/max size still return `.success`, so this neither fixes nor regresses clamping.
    @discardableResult
    /// `current` (the window's present frame, AX coords) picks the write order — see
    /// `Geometry.positionFirst`. Pass it whenever it's known for free; nil keeps position-first.
    static func setFrame(_ element: AXUIElement, _ rect: CGRect, current: CGRect? = nil) -> Bool {
        func writePosition() -> Bool {
            var origin = rect.origin
            guard let v = AXValueCreate(.cgPoint, &origin) else { return true }
            return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) == .success
        }
        func writeSize() -> Bool {
            var size = rect.size
            guard let v = AXValueCreate(.cgSize, &size) else { return true }
            return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) == .success
        }
        // Both writes must run, so bind each result before combining (no short-circuit).
        if Geometry.positionFirst(current: current, target: rect) {
            let p = writePosition(), s = writeSize()
            return p && s
        }
        let s = writeSize(), p = writePosition()
        return s && p
    }

    static func raise(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Mark a window as its app's main window (used to pull its Space forward).
    static func makeMain(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    static func setMinimized(_ element: AXUIElement, _ minimized: Bool) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                     minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        (copy(element, kAXMinimizedAttribute as String) as Bool?) ?? false
    }

    /// Whether the window exposes a native full-screen button. Real app windows have one;
    /// dialogs, palettes and settings panels usually don't — the AeroSpace heuristic for
    /// "this isn't a tileable window". A nil button element means absent.
    static func hasFullscreenButton(_ element: AXUIElement) -> Bool {
        (copy(element, "AXFullScreenButton") as AXUIElement?) != nil
    }

    // MARK: Window identity & visibility

    /// Private AX SPI used by every serious macOS WM (yabai, Amethyst): maps an AX window element
    /// to its CoreGraphics window id. Resolved at runtime (`PrivateAPI`): if the symbol is ever gone,
    /// this answers nil for every window and the launch alert says why, instead of dyld refusing
    /// to start the app.
    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        guard let get = PrivateAPI.axGetWindow else { return nil }
        Perf.count("ax.windowID")
        var wid = CGWindowID(0)
        return get(element, &wid) == .success ? wid : nil
    }

    /// A natively full-screened window lives on its own Space; managing it makes
    /// macOS jump desktops, so Mosaic leaves these alone.
    static func isFullscreen(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) ?? false
    }

    /// Enter/leave native full screen (a standard AX write — works with SIP enabled).
    /// Returns whether the write was accepted: a window still animating/initializing on open
    /// often rejects it, and the caller must not record the rule as applied on a rejected write
    /// (else the on-open rule is silently and permanently defeated for that window).
    @discardableResult
    static func setFullscreen(_ element: AXUIElement, _ on: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString,
                                     (on ? kCFBooleanTrue : kCFBooleanFalse)) == .success
    }

    /// Standard windows of an app by pid, INCLUDING full-screened ones — unlike
    /// `managedWindows`, this doesn't skip the app when hidden or filter by screen. Used to
    /// enforce per-app window-state rules on windows Mosaic otherwise wouldn't capture.
    static func standardWindows(ofPID pid: pid_t) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(pid)
        guard let windows: [AXUIElement] = copy(axApp, kAXWindowsAttribute as String) else { return [] }
        return windows.filter { subrole($0) == (kAXStandardWindowSubrole as String) }
    }

    /// Window ids currently visible on the *active* Space of each display.
    /// Windows sitting on other Spaces are not on-screen, so this is how we avoid
    /// sweeping in apps from adjacent desktops.
    static func onScreenWindowIDs() -> Set<CGWindowID> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var ids = Set<CGWindowID>()
        for entry in info {
            // Layer 0 = ordinary app windows; skip menus, shadows, the Dock, etc.
            guard (entry[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if let num = entry[kCGWindowNumber as String] as? CGWindowID {
                ids.insert(num)
            }
        }
        return ids
    }

    /// Every on-screen layer-0 window with its owner and bounds, in AX/CG coordinates (origin at
    /// the top-left of the main display). Layer 0 is ordinary app windows, so Mosaic's own overlays
    /// — all `.floating` or above — can never appear here.
    static func onScreenWindows() -> [(id: CGWindowID, pid: pid_t, bounds: CGRect)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [(id: CGWindowID, pid: pid_t, bounds: CGRect)] = []
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            out.append((id, pid, bounds))
        }
        return out
    }

    // MARK: Enumeration

    /// All standard, on-screen windows of regular (Dock-visible) applications.
    /// `limitedTo` skips whole applications. Each one costs a cross-process round trip for its
    /// window list plus one per window for the subrole, and an app with nothing in the caller's
    /// on-screen set cannot contribute a window that survives its filter — so enumerating it buys
    /// a result already known to be empty.
    static func managedWindows(limitedTo pids: Set<pid_t>? = nil) -> [WindowRef] {
        var result: [WindowRef] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if app.isHidden { continue }
            let pid = app.processIdentifier
            if let pids, !pids.contains(pid) { continue }
            let axApp = AXUIElementCreateApplication(pid)
            guard let windows: [AXUIElement] = copy(axApp, kAXWindowsAttribute as String) else { continue }
            for window in windows {
                // Only real, standard windows — skip sheets, popovers, panels.
                guard subrole(window) == (kAXStandardWindowSubrole as String) else { continue }
                result.append(WindowRef(element: window, pid: pid))
            }
        }
        return result
    }
}

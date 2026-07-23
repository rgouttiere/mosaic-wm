import AppKit
import ApplicationServices

/// Private AX SPI used by every serious macOS WM (yabai, Amethyst): maps an AX
/// window element to its CoreGraphics window id, so we can cross-reference the
/// on-screen window list and tell which Space a window lives on.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin Swift wrappers over the C Accessibility API (`AXUIElement`).
/// This is the only sanctioned way on macOS to move/resize other apps' windows
/// without disabling SIP — the same foundation Amethyst is built on.
enum AX {

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

    static func setFrame(_ element: AXUIElement, _ rect: CGRect) {
        var origin = rect.origin
        var size = rect.size
        if let posValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }
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

    // MARK: Window identity & visibility

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var wid = CGWindowID(0)
        return _AXUIElementGetWindow(element, &wid) == .success ? wid : nil
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
    static func setFullscreen(_ element: AXUIElement, _ on: Bool) {
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString,
                                     (on ? kCFBooleanTrue : kCFBooleanFalse))
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

    // MARK: Enumeration

    /// All standard, on-screen windows of regular (Dock-visible) applications.
    static func managedWindows() -> [WindowRef] {
        var result: [WindowRef] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if app.isHidden { continue }
            let pid = app.processIdentifier
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

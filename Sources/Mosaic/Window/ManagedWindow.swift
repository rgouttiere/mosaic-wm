import AppKit
import ApplicationServices

/// A single window Mosaic controls. Wraps an `AXUIElement` plus its owning app.
final class ManagedWindow {
    let element: AXUIElement
    let pid: pid_t
    let app: NSRunningApplication

    /// Last CGWindowID we resolved successfully. Lets reconcile distinguish "AX briefly
    /// glitched" (window still in the window-server list) from "really closed".
    var lastKnownID: CGWindowID?
    /// Consecutive reconciles where the window resolved to nothing. A window is only
    /// removed after a couple of misses, so a transient AX/wake/dock glitch can never
    /// destroy the layout on a single bad read.
    var missCount = 0

    init?(ref: AX.WindowRef) {
        guard let app = NSRunningApplication(processIdentifier: ref.pid) else { return nil }
        self.element = ref.element
        self.pid = ref.pid
        self.app = app
    }

    /// Current window id, caching it on success. nil only when AX genuinely can't
    /// resolve the element right now (which may just be a transient glitch).
    func resolvedID() -> CGWindowID? {
        if let id = AX.windowID(element) { lastKnownID = id; missCount = 0; return id }
        return nil
    }

    var title: String {
        let t = AX.title(element)
        return t.isEmpty ? (app.localizedName ?? "Untitled") : t
    }

    var appName: String { app.localizedName ?? "App" }

    var frame: CGRect? { AX.frame(element) }

    /// Last frame (AX coords) we asked this window to take. Lets `setCocoaFrame` skip a
    /// redundant AX write — the expensive op, since each write forces the app to re-layout
    /// its content — when the target is unchanged. Mosaic is the layout authority and does
    /// not track external moves, so comparing against our own last write is sufficient.
    private var lastSetFrame: CGRect?

    /// Position/size the window in Cocoa coordinates (converted to AX internally).
    func setCocoaFrame(_ cocoaRect: CGRect) {
        let axRect = Geometry.flip(cocoaRect)
        if let last = lastSetFrame,
           abs(last.origin.x - axRect.origin.x) < 1, abs(last.origin.y - axRect.origin.y) < 1,
           abs(last.size.width - axRect.size.width) < 1, abs(last.size.height - axRect.size.height) < 1 {
            return   // already where we put it → skip the costly AX write + app relayout
        }
        AX.setFrame(element, axRect)
        lastSetFrame = axRect
    }

    /// Last opacity we set (via CGS). `applyOpacity` runs over every window on each render,
    /// so skipping unchanged writes avoids a burst of redundant private-API calls. ALL
    /// alpha changes must go through here, else the cache would go stale.
    private var lastSetAlpha: Float?

    func setAlpha(_ alpha: Float, id: CGWindowID) {
        if lastSetAlpha == alpha { return }
        Spaces.setAlpha(id, alpha)
        lastSetAlpha = alpha
    }

    /// Bring this window (and its app) to the front of the window stack.
    func focus() {
        AX.raise(element)
        app.activate()
    }

    /// Raise the window above others without stealing keyboard focus to its app.
    /// Used to lift every tiled window above unmanaged windows at once.
    func raiseWindowOnly() {
        AX.raise(element)
    }

    /// Give the app keyboard focus (without itself reordering Mosaic's stacking —
    /// the manager re-asserts window order afterwards).
    func activateApp() {
        app.activate()
    }

    var isFullscreen: Bool { AX.isFullscreen(element) }
}

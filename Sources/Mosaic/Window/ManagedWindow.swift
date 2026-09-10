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

    /// Learned size floor (points): if a tiling write got clamped UP — the app refuses to shrink
    /// past its own minimum (e.g. an Electron `minWidth`/`minHeight`) — we remember the size it
    /// snapped to, so the split solver reserves that much next pass instead of letting the window
    /// overflow its tile forever (the "Deezer moves strangely in a narrow column" case).
    var learnedMin: CGSize = .zero

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
        // Advance the cache only when the write was accepted. A transiently-rejected move must
        // stay uncached so the next render re-issues it — otherwise the <1px skip above would
        // pin the window to a frame it never actually took, with no self-heal until a manual
        // re-tile. Otherwise the cache is only reset by `invalidateFrameCache` below.
        if AX.setFrame(element, axRect) {
            lastSetFrame = axRect
            // Detect a min-size clamp: if the window came out wider/taller than we asked, that size
            // is a floor it won't go under — record it so the split solver reserves the room.
            if let actual = AX.frame(element)?.size {
                if actual.width  > axRect.size.width  + 2 { learnedMin.width  = max(learnedMin.width,  actual.width) }
                if actual.height > axRect.size.height + 2 { learnedMin.height = max(learnedMin.height, actual.height) }
            }
        }
    }

    /// Forget the last frame we wrote so the next `setCocoaFrame` re-issues the AX write even when
    /// the target is unchanged. macOS relocates windows out from under us during sleep/wake and
    /// display reconfigures; since we don't track external moves, the <1px skip above would
    /// otherwise no-op the corrective write and leave the window where the system scattered it
    /// (the "I must revisit every workspace after wake for it to lay out" bug).
    func invalidateFrameCache() { lastSetFrame = nil }

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

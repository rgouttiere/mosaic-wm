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

    /// The window's AX frame, reused briefly.
    ///
    /// One render makes several passes over the same windows — the letterbox fill, the inactive
    /// borders and the focus halo each ask again — and every ask is a synchronous round trip to
    /// the owning app. Against a slow one that dominates: with IINA in the layout, decorating the
    /// tiles went from 6ms to 116ms, and the aspect-fit pass from 0.05ms to 30ms.
    ///
    /// Bounded by time rather than tied to a render, so reads from reconcile and the janitors are
    /// covered too and a missed invalidation can only ever be 50ms stale. Every write invalidates,
    /// so a read-back after `setCocoaFrame` still sees what the app actually accepted — which the
    /// monocle path and the min-size clamp both depend on.
    private var frameCache: CGRect?
    private var frameCacheTime = Date.distantPast
    private var frameCacheEpoch: UInt64 = 0
    private static let frameCacheTTL: TimeInterval = 0.05

    /// Bumped at both ends of a render, so an entry filled DURING one stays valid for the rest of
    /// it however long it takes, and no entry can match between renders. The plain 50ms window
    /// wasn't enough where it mattered most: a workspace switch moves every window first, so by
    /// the time the decorations read back, the frames seeded at the start of the arrange had
    /// expired — and each re-read blocked on an app that was still re-laying-out. `decorate` alone
    /// was 125ms of a 237ms switch.
    static var renderEpoch: UInt64 = 0

    var frame: CGRect? {
        if frameCache != nil,
           frameCacheEpoch == Self.renderEpoch || Date().timeIntervalSince(frameCacheTime) < Self.frameCacheTTL {
            Perf.count("ax.frameCacheHit")
            return frameCache
        }
        Perf.count("ax.frameRead")
        return cacheFrame(AX.frame(element))
    }

    /// Remember a frame we just read. A failed read isn't cached, so the next ask retries.
    @discardableResult
    private func cacheFrame(_ frame: CGRect?) -> CGRect? {
        frameCache = frame
        frameCacheTime = frame == nil ? .distantPast : Date()
        frameCacheEpoch = frame == nil ? 0 : Self.renderEpoch
        return frame
    }

    /// Learned size floor (points): if a tiling write got clamped UP — the app refuses to shrink
    /// past its own minimum (e.g. an Electron `minWidth`/`minHeight`) — we remember the size it
    /// snapped to, so the split solver reserves that much next pass instead of letting the window
    /// overflow its tile forever (the "Deezer moves strangely in a narrow column" case).
    var learnedMin: CGSize = .zero

    /// Learned width/height ratio of an aspect-locked window (IINA & co). 0 = unknown / not aspect-fit.
    /// Once known, arrange() sizes the window to the largest box of this ratio that fits its tile and
    /// centres it (letterbox around), so an aspect-locked window can't overshoot and freeze its column.
    var aspectRatio: CGFloat = 0

    /// This window's app is on the `aspectFitApps` list → treat it as aspect-locked (see aspectRatio).
    var isAspectFit: Bool {
        if Config.shared.aspectFitApps.contains(appName.lowercased()) { return true }
        if let b = app.bundleIdentifier?.lowercased(), Config.shared.aspectFitApps.contains(b) { return true }
        return false
    }

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
            Perf.count("ax.frameWriteSkipped")
            return   // already where we put it → skip the costly AX write + app relayout
        }
        // Advance the cache only when the write was accepted. A transiently-rejected move must
        // stay uncached so the next render re-issues it — otherwise the <1px skip above would
        // pin the window to a frame it never actually took, with no self-heal until a manual
        // re-tile. Otherwise the cache is only reset by `invalidateFrameCache` below.
        Perf.count("ax.frameWrite")
        if AX.setFrame(element, axRect) {
            lastSetFrame = axRect
            // Detect a min-size clamp: if the window came out wider/taller than we asked, that size
            // is a floor it won't go under — record it so the split solver reserves the room.
            if let actual = cacheFrame(AX.frame(element))?.size {   // seeds the cache with the truth
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
    func invalidateFrameCache() {
        lastSetFrame = nil
        frameCache = nil   // the system moved it behind our back: what we last read is suspect too
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
        // Asking for an app that is already frontmost is still a cross-process request, and render
        // asks on every focus change — measured at 1.5-9ms of one. Which app is front is a local
        // read, so check before asking. The window-level work (makeMain, raise) is separate and
        // still runs: this only skips the app-level switch that has already happened.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else { return }
        app.activate()
    }

    var isFullscreen: Bool { AX.isFullscreen(element) }
}

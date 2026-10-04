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
    /// The `followTitle` rule (its title pattern) last applied to this window: a re-route happens
    /// only when the matching rule CHANGES, so a manual move is not undone by the next title tick.
    var lastTitleRoute: String?

    init?(ref: AX.WindowRef) {
        guard let app = NSRunningApplication(processIdentifier: ref.pid) else { return nil }
        self.element = ref.element
        self.pid = ref.pid
        self.app = app
    }

    /// Current window id, caching it on success. nil only when AX genuinely can't
    /// resolve the element right now (which may just be a transient glitch).
    func resolvedID() -> CGWindowID? {
        Perf.count("ax.resolveID")
        if let id = Perf.span("ax.resolveID", { AX.windowID(element) }) { lastKnownID = id; missCount = 0; return id }
        return nil
    }

    /// Cached: a title changes when the app says so (kAXTitleChanged → `noteExternalChange`), yet a
    /// strip with six rows re-read all six on every render — one of them 560 ms while its web app
    /// was busy, measured. The TTL is only a net for an app that never notifies.
    var title: String {
        if let t = titleCache, Date().timeIntervalSince(titleCacheTime) < Self.titleTTL { return t }
        Perf.count("ax.titleRead")
        let raw = AX.title(element)
        let t = raw.isEmpty ? (app.localizedName ?? "Untitled") : raw
        titleCache = t; titleCacheTime = Date()
        return t
    }
    private var titleCache: String?
    private var titleCacheTime = Date.distantPast
    private static let titleTTL: TimeInterval = 60

    var appName: String { app.localizedName ?? "App" }

    /// Compact identity for event lines: app, a slice of the title, and the window id if known.
    var logLabel: String {
        let t = title
        let short = t.count > 28 ? String(t.prefix(27)) + "…" : t
        let id = lastKnownID.map { " #\($0)" } ?? ""
        return "\(appName) ‹\(short)›\(id)"
    }

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
    /// Was 50 ms, when nothing told us a window had moved. Now the per-window Moved/Resized
    /// notifications drop the cache the moment the app or macOS moves it (`noteExternalChange`),
    /// our own writes seed it with the readback, and the TTL is only a net for a silent app.
    /// Measured before: 616 full-screen reads and 121 frame reads for ten tab switches.
    private static let frameCacheTTL: TimeInterval = 10
    private static let fullscreenTTL: TimeInterval = 30

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
    /// Forget the frame-write audit counters. They are cumulative since launch on purpose — a
    /// conflict that only fires on a drop or a wake would be invisible in a snapshot of the last
    /// (idle, fully cached) render — but that also means a violation, once seen, would stay in every
    /// dump forever, and an alert that never clears is an alert that gets ignored. `recover` clears
    /// them AFTER healing, so the next verdict describes what happens from now on: if the violation
    /// comes back, it is live; if it doesn't, it was the one-off cost of settling.
    func resetFrameWriteAudit() {
        maxFrameWrites = 0
        doubleWriteRenders = 0
        writesThisEpoch = 0
        lastWriteEpoch = 0
    }

    /// `probe`: a write that exists only to make the app reveal a constraint we cannot compute (the
    /// monocle blowing a window up to read back its aspect-locked size). It is deliberately followed
    /// by a second, real placement write, so it must not read as two passes fighting.
    func setCocoaFrame(_ cocoaRect: CGRect, probe: Bool = false) {
        if Self.parkingWrites, !probe { setCocoaFrameAsync(cocoaRect); return }   // a workspace park: nobody is looking
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
        drainParkWrites()   // a park of THIS window still in flight must land before we move it again
        Perf.count("ax.frameWrite")
        if !probe { noteWriteForAudit() }
        // Our last accepted write is the best free estimate of where the window is now; fall back to
        // the (50ms-cached) live read when we have none, e.g. right after invalidateFrameCache.
        let before = lastSetFrame ?? frame
        let sizeChanges = before.map { abs($0.width - axRect.width) > 0.5 || abs($0.height - axRect.height) > 0.5 } ?? true
        if Perf.span("ax.setFrame", { AX.setFrame(element, axRect, current: before, onlyChanged: true) }) {   // blocks until the app has relaid out
            lastSetFrame = axRect
            lastWriteAt = Date()
            if !sizeChanges {
                // A move at constant size cannot hit a min-size clamp, so there is nothing to learn
                // from a readback — and that second round trip waited for the app's relayout (17 ms
                // on average, 150 ms worst, on every tab switch). Trust the write.
                _ = cacheFrame(axRect)
                return
            }
            if ManagedWindow.liveResize {
                // Mid-drag: trust the write. The readback is a second synchronous round trip into the
                // app — measured at 11 ms, the same as the write itself, so it doubled the cost of
                // every live frame for a truth nobody looks at until the drag ends. Seeding the cache
                // with the asked rect keeps the borders, shade and gap fill on the target geometry
                // (where they belong while the app catches up); the settle pass re-reads every
                // window for real (`learnResizeMins`) and the full render follows.
                _ = cacheFrame(axRect)
                return
            }
            // Detect a min-size clamp: if the window came out wider/taller than we asked, that size
            // is a floor it won't go under — record it so the split solver reserves the room.
            if let actual = cacheFrame(Perf.span("ax.frameReadback") { AX.frame(element) })?.size {   // seeds the cache with the truth
                if actual.width  > axRect.size.width  + 2 { learnedMin.width  = max(learnedMin.width,  actual.width) }
                if actual.height > axRect.size.height + 2 { learnedMin.height = max(learnedMin.height, actual.height) }
            }
        }
    }

    /// True while `renderLive` runs: frame writes skip their readback (see `setCocoaFrame`).
    static var liveResize = false
    /// Apps hidden by the park (see WindowManager+Park): their windows are not written at all.
    static var parkHiddenPids = Set<pid_t>()

    // MARK: - Park writes off the critical path

    /// Set around a workspace park: every `setCocoaFrame` then queues instead of blocking.
    static var parkingWrites = false
    /// One serial queue PER window: its writes keep their order, and waiting for them never waits
    /// for another app's. Created on first use — most windows are never parked asynchronously.
    private lazy var parkQueue = DispatchQueue(label: "mosaic.park.\(pid)", qos: .userInitiated)
    private var pendingParkWrites = 0   // main-thread only

    /// A park moves a window nobody is looking at — it is leaving under a raised one, or its whole
    /// workspace is — yet the app's relayout was paid synchronously on every tab switch and every
    /// workspace switch: 25–45 ms typical, 470 ms worst, measured on Chrome, Firefox and the Safari
    /// web apps. Queue it. The caches take the asked rect; the Moved echo drops them and the next
    /// read tells the truth. A later synchronous write to the same window drains the queue first.
    func setCocoaFrameAsync(_ cocoaRect: CGRect) {
        let axRect = Geometry.flip(cocoaRect)
        if let last = lastSetFrame,
           abs(last.origin.x - axRect.origin.x) < 1, abs(last.origin.y - axRect.origin.y) < 1,
           abs(last.size.width - axRect.size.width) < 1, abs(last.size.height - axRect.size.height) < 1 {
            Perf.count("ax.frameWriteSkipped")
            return
        }
        Perf.count("ax.frameWrite"); Perf.count("ax.parkWriteQueued")
        noteWriteForAudit()   // a queued park counts like any write: two passes fighting is still two passes
        let current = lastSetFrame ?? frameCache
        lastSetFrame = axRect
        lastWriteAt = Date()
        _ = cacheFrame(axRect)
        pendingParkWrites += 1
        let el = element
        parkQueue.async { [weak self] in
            _ = AX.setFrame(el, axRect, current: current, quiet: true, onlyChanged: true)
            DispatchQueue.main.async { self?.pendingParkWrites -= 1 }
        }
    }

    private func noteWriteForAudit() {
        if lastWriteEpoch == RenderEpoch.current {
            writesThisEpoch += 1
            if writesThisEpoch == 2 { doubleWriteRenders += 1 }
        } else {
            lastWriteEpoch = RenderEpoch.current
            writesThisEpoch = 1
        }
        maxFrameWrites = max(maxFrameWrites, writesThisEpoch)
    }

    private func drainParkWrites() {
        guard pendingParkWrites > 0 else { return }
        Perf.span("ax.parkDrain") { parkQueue.sync {} }
    }

    /// Which render pass we're in. Two frame writes to ONE window inside a single pass mean two
    /// passes are fighting over it: `arrange` placing a tile while a park pushed it away again was
    /// exactly that, and it kept `lastSetFrame` from ever settling (see the load-bearing invariant).
    /// Bumped by render/renderLive; windows compare against it to notice they were written twice.
    enum RenderEpoch {
        private(set) static var current: UInt64 = 0
        static func begin() { current &+= 1 }
    }

    private var lastWriteEpoch: UInt64 = 0
    private var writesThisEpoch = 0
    /// Worst number of placement writes this window ever took in one render, and how many renders
    /// did it. Kept since launch: a conflict that only fires on a drop or a wake would be invisible
    /// in a snapshot of the last (idle, fully cached) render.
    private(set) var maxFrameWrites = 0
    private(set) var doubleWriteRenders = 0

    /// Forget the last frame we wrote so the next `setCocoaFrame` re-issues the AX write even when
    /// the target is unchanged. macOS relocates windows out from under us during sleep/wake and
    /// display reconfigures; since we don't track external moves, the <1px skip above would
    /// otherwise no-op the corrective write and leave the window where the system scattered it
    /// (the "I must revisit every workspace after wake for it to lay out" bug).
    func invalidateFrameCache() {
        lastSetFrame = nil
        frameCache = nil   // the system moved it behind our back: what we last read is suspect too
        fullscreenCache = nil
    }

    /// The app (or macOS) reported something about this window: drop what we cached about it.
    /// Moved/Resized also arrive as the echo of our own writes — one extra read per write, cheap.
    /// `lastSetFrame` (the write-skip memory) is left alone: that is the drag path's business.
    func noteExternalChange(_ notification: String) {
        if notification == kAXTitleChangedNotification as String { titleCache = nil; return }
        // The Moved/Resized echo of our own write: the readback (or the asked rect) already holds
        // the truth, and dropping it made the very next read — aspect-fit, halo, borders — a round
        // trip into an app still busy with that relayout (200 ms, measured).
        if Date().timeIntervalSince(lastWriteAt) < 0.5 { return }
        frameCache = nil; fullscreenCache = nil
    }
    private var lastWriteAt = Date.distantPast

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

    /// Cached like `frame`, for the same reason: every pass asks it for every visible leaf — the
    /// decorations, the shade, the halo, the hidden-tab park — and each ask was a synchronous AX
    /// round trip into the app. During a live resize that app is busy relaying out the window we
    /// just wrote, so the read blocks until its main thread is free: 7–9 ms per overlay pass,
    /// measured, for a state that cannot change mid-drag — so while a live resize runs the cached
    /// answer is taken whatever its age (frames are further apart than the TTL). Outside a drag the
    /// 50 ms TTL keeps the load-bearing rule intact (never raise a window that just went full
    /// screen): a toggle is seen within a render, not within a frame.
    var isFullscreen: Bool {
        if let v = fullscreenCache,
           Self.liveResize || Date().timeIntervalSince(fullscreenCacheTime) < Self.fullscreenTTL {
            return v
        }
        Perf.count("ax.fullscreenRead")
        let v = AX.isFullscreen(element)
        fullscreenCache = v; fullscreenCacheTime = Date()
        return v
    }
    private var fullscreenCache: Bool?
    private var fullscreenCacheTime = Date.distantPast
}

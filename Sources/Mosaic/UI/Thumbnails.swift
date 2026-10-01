import AppKit
import ScreenCaptureKit

/// Live window previews for the exposé, captured via ScreenCaptureKit (CGWindowListCreateImage is
/// obsoleted on macOS 15+). Needs the Screen Recording permission — the first capture triggers the
/// system prompt for Mosaic, like Accessibility did. SCK captures PARKED (off-screen) windows with
/// real, current content on Tahoe, so the exposé re-grabs everything live on open.
/// Gated by `exposeThumbnails`; when off or ungranted, the exposé falls back to schematic tiles.

/// The exposé's image store. Shared and PERSISTENT across exposé sessions: a fresh store per open
/// meant every open started on schematic tiles and faded the previews in a few hundred ms later,
/// every time. Kept, the next open draws the last capture of every window at once and refreshes
/// behind it — and `WindowManager.warmThumbnails` re-captures the windows that are on a monitor a
/// few seconds after each quiet render, so what it shows is rarely older than the last pause.
final class ThumbnailStore {
    static let shared = ThumbnailStore()
    private(set) var images: [CGWindowID: NSImage] = [:]

    func set(_ cg: CGImage, for id: CGWindowID) {
        images[id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Drop the previews of windows that are no longer managed.
    func prune(keeping ids: Set<CGWindowID>) {
        images = images.filter { ids.contains($0.key) }
    }
}

@available(macOS 14.0, *)
enum Thumbnails {
    /// Capture many windows in one shot: fetch the shareable-window list ONCE, then grab each in
    /// parallel. Returns id → image for the windows that captured (missing/failed ones are omitted).
    static func captureAll(_ ids: [CGWindowID]) async -> [CGWindowID: CGImage] {
        guard !ids.isEmpty else { return [:] }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            NSLog("Mosaic: thumbnails shareable-content failed: \(error)")
            return [:]
        }
        var byID: [CGWindowID: SCWindow] = [:]
        for w in content.windows { byID[w.windowID] = w }

        return await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for id in Set(ids) {
                guard let win = byID[id] else { continue }
                group.addTask { (id, await capture(win)) }
            }
            var out: [CGWindowID: CGImage] = [:]
            for await (id, img) in group where img != nil { out[id] = img }
            return out
        }
    }

    /// Screenshot a single window, downscaled — exposé tiles are small, full-res is wasteful.
    private static func capture(_ win: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        let longEdge = max(win.frame.width, win.frame.height)
        let scale = longEdge > 1200 ? 1200 / longEdge : 1
        cfg.width = max(1, Int(win.frame.width * scale))
        cfg.height = max(1, Int(win.frame.height * scale))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            return nil
        }
    }
}

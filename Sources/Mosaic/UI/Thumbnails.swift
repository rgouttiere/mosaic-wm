import AppKit
import ScreenCaptureKit

/// Live window previews for the exposé, captured via ScreenCaptureKit (CGWindowListCreateImage is
/// obsoleted on macOS 15+). Needs the Screen Recording permission — the first capture triggers the
/// system prompt for Mosaic, like Accessibility did. SCK captures PARKED (off-screen) windows with
/// real, current content on Tahoe, so the exposé grabs everything live on open — no cache needed.
/// Gated by `exposeThumbnails`; when off or ungranted, the exposé falls back to schematic tiles.

/// Shared, by-reference image store the exposé views read from as async captures land.
final class ThumbnailStore {
    var images: [CGWindowID: NSImage] = [:]
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

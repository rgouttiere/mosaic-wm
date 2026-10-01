import AppKit
import ApplicationServices

/// Mosaic's private entry points, resolved at RUNTIME with `dlsym` instead of hard-linked.
///
/// They used to be `@_silgen_name` declarations. That binds at load time, so the day Apple removes
/// one — and a major macOS release is exactly when that happens — dyld refuses to start Mosaic at
/// all, with a linker error and no explanation the user could act on. Resolving at runtime turns
/// that into a lost CAPABILITY: trackpad gestures quietly switch off, the AX→window-id bridge (which
/// nothing can replace) produces a clear alert. Either way Mosaic launches, and `dump-layout`
/// says which symbol went missing. Probed once, at first use.
///
/// Presence is not function. There used to be a third entry point here, `CGSSetWindowAlpha` for
/// dimming unfocused tiles: on macOS 27 it still resolved and returned success while the window
/// server ignored it (readback stayed 1.0 — measured with a 0.99 nudge on a foreign window). A
/// symbol check reported a dead feature as healthy, so the probe had to perform the operation and
/// read the result back. The dimming now lives in `TileScrims` (plain AppKit) and the entry point
/// is gone; the lesson stays: a private symbol is only "ok" once its EFFECT has been observed.
enum PrivateAPI {
    typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// Maps an AX element to its CGWindowID — the bridge every reconcile/dedup/decorate pass
    /// stands on. ESSENTIAL: without it no window can be told apart, so nothing can be managed.
    static let axGetWindow: AXGetWindowFn? = resolve("_AXUIElementGetWindow",
        fallback: "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices")
    enum Status: String { case ok, missing }

    struct Capability {
        let symbol: String
        let purpose: String
        let essential: Bool
        let status: Status
        var available: Bool { status == .ok }
    }

    /// Everything Mosaic relies on beyond the public SDK, with whether it is there today.
    static var capabilities: [Capability] {
        [
            Capability(symbol: "_AXUIElementGetWindow", purpose: "AX element → window id (managing windows at all)",
                       essential: true, status: axGetWindow != nil ? .ok : .missing),
            Capability(symbol: "MultitouchSupport (dlopen)", purpose: "3-finger trackpad gestures (trackpadGestures)",
                       essential: false,
                       status: dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY) != nil ? .ok : .missing),
        ]
    }

    static var missingEssential: [Capability] { capabilities.filter { $0.essential && !$0.available } }

    /// One line per capability, for dump-layout and the event log.
    static func report() -> String {
        capabilities.map { c -> String in
            let tag = c.status == .ok ? "ok" : (c.essential ? "\(c.status.rawValue.uppercased()) — ESSENTIAL" : c.status.rawValue)
            return "  [\(tag)] \(c.symbol) — \(c.purpose)"
        }
            .joined(separator: "\n")
    }

    /// `RTLD_DEFAULT` searches every image already loaded (AppKit pulls in HIServices and SkyLight),
    /// so this normally hits first try; the explicit `dlopen` is the belt for the braces.
    private static func resolve<T>(_ symbol: String, fallback library: String) -> T? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        if let p = dlsym(rtldDefault, symbol) { return unsafeBitCast(p, to: T.self) }
        if let h = dlopen(library, RTLD_LAZY), let p = dlsym(h, symbol) { return unsafeBitCast(p, to: T.self) }
        NSLog("Mosaic: private symbol \(symbol) is not available on this macOS")
        return nil
    }
}

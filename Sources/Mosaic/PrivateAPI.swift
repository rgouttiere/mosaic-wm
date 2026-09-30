import AppKit
import ApplicationServices

/// Mosaic's private entry points, resolved at RUNTIME with `dlsym` instead of hard-linked.
///
/// They used to be `@_silgen_name` declarations. That binds at load time, so the day Apple removes
/// one — and a major macOS release is exactly when that happens — dyld refuses to start Mosaic at
/// all, with a linker error and no explanation the user could act on. Resolving at runtime turns
/// that into a lost CAPABILITY: window alpha quietly stops dimming, the AX→window-id bridge (which
/// nothing can replace) produces a clear alert. Either way Mosaic launches, and `dump-layout`
/// says which symbol went missing. Probed once, at first use.
enum PrivateAPI {
    typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
    typealias CGSSetWindowAlphaFn = @convention(c) (Int32, CGWindowID, Float) -> Int32

    /// Maps an AX element to its CGWindowID — the bridge every reconcile/dedup/decorate pass
    /// stands on. ESSENTIAL: without it no window can be told apart, so nothing can be managed.
    static let axGetWindow: AXGetWindowFn? = resolve("_AXUIElementGetWindow",
        fallback: "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices")
    /// Window alpha (dim unfocused tiles). Cosmetic: losing it costs a dimming effect, nothing else.
    static let cgsMainConnectionID: CGSMainConnectionIDFn? = resolve("CGSMainConnectionID",
        fallback: "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
    static let cgsSetWindowAlpha: CGSSetWindowAlphaFn? = resolve("CGSSetWindowAlpha",
        fallback: "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")

    enum Status: String { case ok, missing, ineffective = "no effect" }

    struct Capability {
        let symbol: String
        let purpose: String
        let essential: Bool
        let status: Status
        var available: Bool { status == .ok }
    }

    /// Does the window server still HONOUR CGSSetWindowAlpha for another app's window? A symbol
    /// that resolves proves nothing: on macOS 27 the call returns success and changes nothing
    /// (measured — readback stays 1.0), so a symbol check reported a dead feature as healthy.
    /// Probed like OmniWM does it: perform the operation on a real foreign window and read the
    /// result back through the public CGWindowList. The nudge is 0.99 → invisible, restored at once.
    /// nil = no foreign window to try on (inconclusive, treated as unknown rather than broken).
    static let alphaEffective: Bool? = {
        guard let cidFn = cgsMainConnectionID, let set = cgsSetWindowAlpha else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let w = list.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0
                                          && ($0[kCGWindowOwnerPID as String] as? Int32) != mine
                                          && ($0[kCGWindowAlpha as String] as? Double) == 1.0 }),
              let wid = w[kCGWindowNumber as String] as? CGWindowID else { return nil }
        func read() -> Double {
            (CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]])?.first?[kCGWindowAlpha as String] as? Double ?? -1
        }
        let cid = cidFn()
        _ = set(cid, wid, 0.99)
        let changed = abs(read() - 0.99) < 0.005
        _ = set(cid, wid, 1.0)
        return changed
    }()

    /// Everything Mosaic relies on beyond the public SDK, with whether it is there today.
    static var capabilities: [Capability] {
        [
            Capability(symbol: "_AXUIElementGetWindow", purpose: "AX element → window id (managing windows at all)",
                       essential: true, status: axGetWindow != nil ? .ok : .missing),
            Capability(symbol: "CGSSetWindowAlpha", purpose: "dim unfocused tiles (activeOpacity/inactiveOpacity)",
                       essential: false,
                       status: (cgsMainConnectionID == nil || cgsSetWindowAlpha == nil) ? .missing
                             : (alphaEffective == false ? .ineffective : .ok)),
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
            let note = c.status == .ineffective ? " (symbol present, but the window server ignores it on this macOS)" : ""
            return "  [\(tag)] \(c.symbol) — \(c.purpose)\(note)"
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

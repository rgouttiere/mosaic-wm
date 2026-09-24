import AppKit
import ApplicationServices

// MARK: - M0 spike (THROWAWAY)
//
// Goal: prove the emulated-workspace assumption on real hardware BEFORE investing.
// It parks every managed window off-screen (bottom-right corner, AeroSpace-style)
// and brings them back, measuring:
//   - switch latency (per window + batch),
//   - the ~1px sliver macOS refuses to hide,
//   - which apps stick / refuse the move (Electron, IINA, terminals, Docker…).
//
// This is NOT production code. It duplicates a minimal AX layer on purpose so it
// stays self-contained and easy to delete once M0 answers "will this feel nice?".

// MARK: Minimal AX layer (self-contained copy)

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
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

    /// Returns whether the write was accepted (`.success`), not whether the pixels landed.
    @discardableResult
    static func setFrame(_ element: AXUIElement, _ rect: CGRect) -> Bool {
        var origin = rect.origin
        var size = rect.size
        var ok = true
        if let posValue = AXValueCreate(.cgPoint, &origin) {
            ok = (AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue) == .success) && ok
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            ok = (AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue) == .success) && ok
        }
        return ok
    }

    /// Position-only write (what a real park/unpark would do — size is preserved).
    @discardableResult
    static func setPosition(_ element: AXUIElement, _ p: CGPoint) -> Bool {
        var origin = p
        guard let posValue = AXValueCreate(.cgPoint, &origin) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue) == .success
    }

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var wid = CGWindowID(0)
        return _AXUIElementGetWindow(element, &wid) == .success ? wid : nil
    }

    static func isFullscreen(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    static func managedWindows() -> [(element: AXUIElement, pid: pid_t, app: String)] {
        var result: [(AXUIElement, pid_t, String)] = []
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if app.isHidden || app.processIdentifier == selfPID { continue }
            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            guard let windows: [AXUIElement] = copy(axApp, kAXWindowsAttribute as String) else { continue }
            for window in windows {
                guard subrole(window) == (kAXStandardWindowSubrole as String) else { continue }
                result.append((window, pid, app.localizedName ?? "?"))
            }
        }
        return result
    }
}

// MARK: Geometry — global desktop bounds in AX (top-left origin) coordinates

/// Union of all active displays' bounds. CGDisplayBounds is already in the
/// top-left-origin global space AX writes use, so no Cocoa flip is needed.
func globalDesktopBounds() -> CGRect {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    var union = CGRect.null
    for id in ids { union = union.union(CGDisplayBounds(id)) }
    return union.isNull ? CGRect(x: 0, y: 0, width: 1440, height: 900) : union
}

/// Window ids currently on-screen (layer 0) — used to confirm a parked window
/// really left the visible set.
func onScreenWindowIDs() -> Set<CGWindowID> {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var ids = Set<CGWindowID>()
    for entry in info {
        guard (entry[kCGWindowLayer as String] as? Int) == 0 else { continue }
        if let num = entry[kCGWindowNumber as String] as? CGWindowID { ids.insert(num) }
    }
    return ids
}

// MARK: Spike state

struct Tracked {
    let element: AXUIElement
    let wid: CGWindowID
    let app: String
    let title: String
    let original: CGRect
    let fullscreen: Bool
}

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

var tracked: [Tracked] = []
var parked = false

func capture() {
    tracked.removeAll()
    for w in AX.managedWindows() {
        guard let wid = AX.windowID(w.element), let frame = AX.frame(w.element) else { continue }
        tracked.append(Tracked(element: w.element, wid: wid, app: w.app,
                               title: AX.title(w.element), original: frame,
                               fullscreen: AX.isFullscreen(w.element)))
    }
}

func printList() {
    let onScreen = onScreenWindowIDs()
    print("\n#   on  fs  app / title                                  frame")
    print(String(repeating: "-", count: 78))
    for (i, t) in tracked.enumerated() {
        let vis = onScreen.contains(t.wid) ? "●" : "·"
        let fs = t.fullscreen ? "F" : " "
        let label = "\(t.app) — \(t.title)".prefix(44).padding(toLength: 44, withPad: " ", startingAt: 0)
        let f = t.original
        print(String(format: "%-3d %@   %@  %@ (%.0f,%.0f %.0fx%.0f)",
                     i, vis, fs, String(label), f.origin.x, f.origin.y, f.width, f.height))
    }
    print("")
}

/// Park: push each tracked window to the global bottom-right corner (off-screen).
/// macOS clamps so a sliver stays; we read back to measure exactly how much.
func park(_ indices: [Int]) {
    let bounds = globalDesktopBounds()
    let target = CGPoint(x: bounds.maxX, y: bounds.maxY) // fully past bottom-right
    print("→ park \(indices.count) window(s) to \(Int(target.x)),\(Int(target.y)) (desktop \(Int(bounds.width))x\(Int(bounds.height)))")

    let batchStart = nowMs()
    var accepted = 0
    var perWindow: [(String, Double, Bool)] = []
    for i in indices where i >= 0 && i < tracked.count {
        let t = tracked[i]
        let s = nowMs()
        let ok = AX.setPosition(t.element, target)
        perWindow.append(("\(t.app.prefix(20))", nowMs() - s, ok))
        if ok { accepted += 1 }
    }
    let batchMs = nowMs() - batchStart

    // Let the window server settle before reading back where windows landed.
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))

    let onScreen = onScreenWindowIDs()
    print(String(format: "  batch: %.1f ms for %d windows (%d accepted), avg %.2f ms/win",
                 batchMs, indices.count, accepted, batchMs / Double(max(indices.count, 1))))
    print("  per-window: latency / accepted / landed-frame / sliver:")
    for i in indices where i >= 0 && i < tracked.count {
        let t = tracked[i]
        let pw = perWindow.first { $0.0 == "\(t.app.prefix(20))" }
        let landed = AX.frame(t.element) ?? .zero
        let movedFar = hypot(landed.origin.x - t.original.origin.x, landed.origin.y - t.original.origin.y) > 20
        // Sliver = how much of the window still intersects the visible desktop.
        let visible = landed.intersection(bounds)
        let stillOn = onScreen.contains(t.wid)
        let verdict: String
        if !movedFar { verdict = "⚠️  STUCK (refused to move)" }
        else if visible.isNull || visible.width < 1 || visible.height < 1 { verdict = "hidden (no sliver!)" }
        else { verdict = String(format: "sliver %.0fx%.0f%@", visible.width, visible.height, stillOn ? " STILL on-screen" : "") }
        print(String(format: "   %-22@ %6.2f ms  %@  @(%.0f,%.0f)  %@",
                     t.app.prefix(22).description, pw?.1 ?? -1, (pw?.2 ?? false) ? "ok " : "REJ",
                     landed.origin.x, landed.origin.y, verdict))
    }
    parked = true
    print("")
}

/// Unpark: restore original frames (position + size), timed.
func unpark(_ indices: [Int]) {
    let batchStart = nowMs()
    var accepted = 0
    for i in indices where i >= 0 && i < tracked.count {
        let t = tracked[i]
        if AX.setFrame(t.element, t.original) { accepted += 1 }
    }
    let batchMs = nowMs() - batchStart
    print(String(format: "← unpark %d window(s): %.1f ms (%d accepted), avg %.2f ms/win",
                 indices.count, batchMs, accepted, batchMs / Double(max(indices.count, 1))))
    parked = false
    print("")
}

// MARK: - REPL

guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
    print("""
    ✗ Accessibility permission required.
      Grant it to THIS binary (or the terminal running it) in:
      System Settings → Privacy & Security → Accessibility
      Then re-run.  (Path: \(CommandLine.arguments[0]))
    """)
    exit(1)
}

capture()
print("""
Mosaic M0 spike — emulated-workspace off-screen park test
Managed windows captured: \(tracked.count)
Commands:
  l            list managed windows (● = on-screen, F = native fullscreen)
  p            park ALL windows off-screen (measures latency + sliver)
  p N [M ...]  park only windows N, M, …  (test one app: IINA, Electron, term)
  u            unpark ALL (restore)
  u N [M ...]  unpark only N, M, …
  r            re-capture the window set
  q            quit (auto-unparks everything first)
""")
printList()

func parseIndices(_ tokens: ArraySlice<Substring>) -> [Int] {
    let parsed = tokens.compactMap { Int($0) }
    return parsed.isEmpty ? Array(tracked.indices) : parsed
}

while true {
    print("spike> ", terminator: "")
    guard let line = readLine() else { break }
    let tokens = line.split(separator: " ")
    guard let cmd = tokens.first else { continue }
    switch cmd {
    case "l", "list": printList()
    case "p", "park": park(parseIndices(tokens.dropFirst()))
    case "u", "unpark": unpark(parseIndices(tokens.dropFirst()))
    case "r", "recapture": capture(); print("re-captured \(tracked.count) windows"); printList()
    case "q", "quit", "exit":
        if parked { unpark(Array(tracked.indices)) }
        exit(0)
    default: print("? unknown command '\(cmd)' — try l / p / u / r / q")
    }
}
if parked { unpark(Array(tracked.indices)) }

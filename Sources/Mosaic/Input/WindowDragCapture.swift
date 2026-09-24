import AppKit

/// "Drag any window" (#1): while a chosen modifier chord is held, a left-mouse drag anywhere picks up
/// the tiled window under the cursor and moves it — center-drop tabs it, edge-drop splits beside/under
/// (identical to dragging a tab). This is what lets you move a window that has NO tab strip to grab.
///
/// Implemented as a session event tap (like the trackpad scroll tap) rather than an overlay window, so
/// there is never a transparent surface that could eat clicks if a modifier-release is missed: when the
/// chord isn't held at mouse-down we simply pass the event straight through. The callback runs on the
/// main run loop, so it can touch the WindowManager / AppKit directly.
final class WindowDragCapture {
    static let shared = WindowDragCapture()

    /// Grab the window under this Cocoa-global point; returns false if there's nothing tiled there
    /// (then the click passes through to the app as normal).
    var beginGrab: ((NSPoint) -> Bool)?
    var moveGrab: ((NSPoint) -> Void)?
    var endGrab: ((NSPoint) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate var chord: CGEventFlags = []   // required modifier chord; empty = disabled
    fileprivate var active = false             // a grab-drag is in flight

    /// (Re)configure from a modifier string like "ctrl alt cmd". Empty/none → tear the tap down.
    func configure(modifier: String) {
        let flags = WindowDragCapture.parseChord(modifier)
        chord = flags
        if flags.isEmpty { removeTap(); return }
        installTap()
    }

    fileprivate func chordHeld(_ event: CGEvent) -> Bool {
        guard !chord.isEmpty else { return false }
        let mods = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        return mods == chord   // exact chord (no extra/missing modifier) → no accidental grabs
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask((1 << CGEventType.leftMouseDown.rawValue)
                             | (1 << CGEventType.leftMouseDragged.rawValue)
                             | (1 << CGEventType.leftMouseUp.rawValue))
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: dragTapCallback, userInfo: nil) else {
            NSLog("Mosaic: window-drag tap could not be created (Accessibility not granted?)")
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        NSLog("Mosaic: drag-any-window active")
    }

    private func removeTap() {
        if active { endGrab?(NSEvent.mouseLocation); active = false }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }

    fileprivate func reEnable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }

    /// "ctrl alt cmd" → CGEventFlags. Unknown tokens are ignored; a bare/empty string → [].
    static func parseChord(_ s: String) -> CGEventFlags {
        var f: CGEventFlags = []
        for tok in s.lowercased().split(whereSeparator: { $0 == " " || $0 == "+" }) {
            switch tok {
            case "cmd", "command", "⌘": f.insert(.maskCommand)
            case "alt", "option", "opt", "⌥": f.insert(.maskAlternate)
            case "ctrl", "control", "⌃": f.insert(.maskControl)
            case "shift", "⇧": f.insert(.maskShift)
            default: break
            }
        }
        return f
    }
}

private let dragTapCallback: CGEventTapCallBack = { _, type, event, _ in
    let me = WindowDragCapture.shared
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reEnable()
        return Unmanaged.passUnretained(event)
    }
    switch type {
    case .leftMouseDown:
        // Start the grab but PASS the down: swallowing it breaks macOS's drag state machine, so the
        // motion would arrive as mouseMoved (no button) and our highlight would never follow. Letting
        // it through keeps normal leftMouseDragged/Up flowing. The app just sees a (harmless) click.
        if !me.active, me.chordHeld(event), me.beginGrab?(NSEvent.mouseLocation) == true {
            me.active = true
        }
    case .leftMouseDragged:
        // OBSERVE only — do NOT swallow: returning nil for a drag freezes the cursor (the position is
        // tied to event delivery), so the highlight never follows and every drop lands back on the
        // grabbed window itself. Passing it through keeps the cursor live; we just read the location.
        if me.active { me.moveGrab?(NSEvent.mouseLocation) }
    case .leftMouseUp:
        // Pass the up so the app sees a complete down…up (a click) rather than a stuck button.
        if me.active { me.endGrab?(NSEvent.mouseLocation); me.active = false }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

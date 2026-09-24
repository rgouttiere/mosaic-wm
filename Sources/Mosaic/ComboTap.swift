import AppKit
import Carbon.HIToolbox

/// Intercepts a set of key combos via a session `CGEventTap` inserted at the HEAD of the event
/// stream — so it sees each keypress BEFORE macOS' own shortcut handling and can swallow it. This
/// is the only way to bind combos macOS reserves as system shortcuts (e.g. Ctrl+←/→ = Mission
/// Control "move a space") WITHOUT the user disabling those shortcuts in System Settings. It's the
/// same trick `CmdTabTap` uses for ⌘Tab, generalised to a press-to-fire list.
///
/// Trade-off: a matched combo is swallowed from EVERY app, so route only combos meant to be global
/// (workspace navigation) through here — not ones an app might legitimately need. Modifier matching
/// is EXACT on ⌘⌃⌥⇧, so `ctrl left` never fires for `cmd ctrl left` (swap) or `ctrl alt left`
/// (resize).
final class ComboTap {
    struct Binding { let keyCode: Int64; let mods: CGEventFlags; let action: () -> Void }

    private var bindings: [Binding] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isEnabled: Bool { tap != nil }

    /// Replace the intercepted combos. An empty list tears the tap down (no interception at all).
    func setBindings(_ b: [Binding]) {
        bindings = b
        b.isEmpty ? disable() : enable()
    }

    private func enable() {
        guard tap == nil else { return }
        let mask = 1 << CGEventType.keyDown.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                        callback: comboTapCallback, userInfo: refcon) else {
            NSLog("Mosaic: combo tap could not be created (Accessibility not granted?)")
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func disable() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }

    fileprivate func reEnable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }

    /// Returns true to swallow the event. Ignores auto-repeat so holding the combo doesn't spin
    /// through workspaces — one switch per physical press.
    fileprivate func handle(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            // Still swallow the repeat if the base combo is one we own, so it doesn't leak through.
            return matches(event) != nil
        }
        guard let action = matches(event) else { return false }
        // Run the action (a full workspace switch — many AX calls) on the NEXT main-loop tick, not
        // synchronously inside the tap callback, so a slow switch can't trip tapDisabledByTimeout
        // (which would drop the triggering keypress). The event is still swallowed immediately.
        DispatchQueue.main.async(execute: action)
        return true
    }

    private func matches(_ event: CGEvent) -> (() -> Void)? {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let flags = event.flags.intersection(relevant)
        return bindings.first { $0.keyCode == code && $0.mods.intersection(relevant) == flags }?.action
    }
}

private let comboTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<ComboTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reEnable()
        return Unmanaged.passUnretained(event)
    }
    return me.handle(event) ? nil : Unmanaged.passUnretained(event)
}

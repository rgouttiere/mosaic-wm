import AppKit

/// Intercepts ⌘Tab (a reserved system shortcut) via a CGEventTap so it can drive the
/// exposé instead of macOS's app switcher. Method A: ⌘Tab opens/advances the overview
/// while ⌘ is held; releasing ⌘ commits the selection. Needs Accessibility (Mosaic has it).
/// Enable/disable via config — the tap is created only while enabled.
final class CmdTabTap {
    var onTrigger: ((Int) -> Void)?   // combo pressed — dir +1 / -1 (with shift)
    var onRelease: (() -> Void)?      // the hold modifier(s) released → commit

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var keyCode: Int64 = 0x30            // Tab
    private var modMask: CGEventFlags = .maskCommand

    var isEnabled: Bool { tap != nil }

    func enable(keyCode: Int64, modMask: CGEventFlags) {
        self.keyCode = keyCode
        self.modMask = modMask
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                        callback: cmdTabCallback, userInfo: refcon) else {
            NSLog("Mosaic: ⌘Tab tap could not be created (Accessibility not granted?)")
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

    /// Returns true to swallow the event.
    fileprivate func handle(_ event: CGEvent, type: CGEventType) -> Bool {
        if type == .flagsChanged {
            if !event.flags.isSuperset(of: modMask) { onRelease?() }   // hold modifier released
            return false
        }
        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == keyCode,
           event.flags.isSuperset(of: modMask) {
            // ⇧ reverses direction, unless ⇧ is itself part of the trigger.
            let reverse = event.flags.contains(.maskShift) && !modMask.contains(.maskShift)
            onTrigger?(reverse ? -1 : 1)
            return true   // swallow it so the system shortcut never fires
        }
        return false
    }
}

private let cmdTabCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<CmdTabTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reEnable()
        return Unmanaged.passUnretained(event)
    }
    return me.handle(event, type: type) ? nil : Unmanaged.passUnretained(event)
}

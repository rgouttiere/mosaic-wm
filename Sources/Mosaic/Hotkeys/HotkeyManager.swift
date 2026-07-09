import AppKit
import Carbon.HIToolbox

/// Registers system-wide hotkeys via the Carbon Hot Key API — the standard way to
/// get global shortcuts on macOS without polling. The C event handler can't capture
/// Swift context, so dispatch goes through a shared registry keyed by hotkey id.
final class HotkeyManager {
    static weak var shared: HotkeyManager?

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x4D4F5341 // 'MOSA'

    init() {
        HotkeyManager.shared = self
        installEventHandler()
    }

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            HotkeyManager.shared?.handlers[hkID.id]?()
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    /// `keyCode` is a Carbon virtual key code (kVK_*); `modifiers` is a Carbon
    /// modifier mask (cmdKey | optionKey | controlKey | shiftKey).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        handlers[id] = action

        let hkID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("Mosaic: failed to register hotkey \(keyCode) (status \(status))")
            handlers[id] = nil
            return false
        }
        if let ref { refs.append(ref) }
        return true
    }

    /// Unregister every hotkey (used before re-registering on a config reload).
    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
        nextID = 1
    }
}

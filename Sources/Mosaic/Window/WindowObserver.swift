import AppKit
import ApplicationServices

/// Watches the system for window lifecycle changes and fires `onChange` (debounced)
/// so the manager can re-tile a live layout.
///
/// Deliberately observes only events Mosaic does NOT itself cause:
/// created / destroyed / hidden / shown / app launch / app terminate. It never
/// observes moved/resized/focus — those fire from our own `setFrame`/`raise` and
/// would cause an infinite re-tile loop.
final class WindowObserver {
    private let onChange: () -> Void
    private var observers: [pid_t: AXObserver] = [:]
    private var pending: DispatchWorkItem?

    /// App-level notifications that signal the managed window set may have changed.
    private let appNotifications = [
        kAXWindowCreatedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
        kAXFocusedWindowChangedNotification,   // keyboard focus / cmd-tab / app switch
    ]

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        let workspace = NSWorkspace.shared
        for app in workspace.runningApplications where app.activationPolicy == .regular {
            observe(app)
        }
        workspace.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        // Catches windows dragged in from another Space: activating their app makes
        // them appear on the current Space, and reconcile() will absorb them.
        workspace.notificationCenter.addObserver(
            self, selector: #selector(somethingChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.notificationCenter.addObserver(
            self, selector: #selector(somethingChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc private func somethingChanged() { scheduleChange() }

    /// Called (debounced) when only a window TITLE changed — a light refresh (update the
    /// tab strips) without re-tiling windows.
    var onTitleChange: (() -> Void)?
    private var titlePending: DispatchWorkItem?

    /// Called (debounced) when the system's focused window changed (click, cmd-tab, app
    /// switch). A PASSIVE resync of Mosaic's focus — never re-tiles, so no loop with our
    /// own raises.
    var onFocusChange: (() -> Void)?
    private var focusPending: DispatchWorkItem?

    func scheduleFocusSync() {
        focusPending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onFocusChange?() }
        focusPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Register per-window notifications: "destroyed" (re-tile on close) and
    /// "title-changed" (live tab labels). Safe to call repeatedly.
    func watchForClose(_ windows: [ManagedWindow]) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for window in windows {
            guard let observer = observers[window.pid] else { continue }
            AXObserverAddNotification(observer, window.element,
                                      kAXUIElementDestroyedNotification as CFString, refcon)
            AXObserverAddNotification(observer, window.element,
                                      kAXTitleChangedNotification as CFString, refcon)
        }
    }

    func scheduleTitleRefresh() {
        titlePending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onTitleChange?() }
        titlePending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    // MARK: - App tracking

    @objc private func appLaunched(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            observe(app)
        }
        scheduleChange()
    }

    @objc private func appTerminated(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           let observer = observers.removeValue(forKey: app.processIdentifier) {
            // Detach its run-loop source, else it (and its source) leaks for every app quit.
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                  AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        scheduleChange()
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, app.activationPolicy == .regular, observers[pid] == nil else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success,
              let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in appNotifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }
}

/// C callback: AXObserver passes our `WindowObserver` back via the refcon pointer.
private let axObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let obs = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
    switch notification as String {
    case kAXTitleChangedNotification as String:
        obs.scheduleTitleRefresh()   // light: just refresh tab labels
    case kAXFocusedWindowChangedNotification as String:
        obs.scheduleFocusSync()      // light: adopt system focus, no re-tile
    default:
        obs.scheduleChange()         // structural: re-tile
    }
}

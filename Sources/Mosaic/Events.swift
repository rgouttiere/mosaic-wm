import Foundation

/// The event stream behind `mosaic subscribe`: one JSON object per line, pushed to every client
/// that asked for it on the command socket. For scripts that react (lights on the "Films"
/// workspace, a Slack status on "Code") and for bars that want to stop polling status.json.
///
/// Main-thread `emit`; delivery on a serial queue, non-blocking sockets. A client that cannot keep
/// up (full buffer) or has gone (EPIPE) is dropped — a slow listener never stalls the window manager.
enum Events {
    private static let queue = DispatchQueue(label: "mosaic.events")
    private static var subscribers: [(fd: Int32, filter: Set<String>)] = []   // queue-only

    /// Every event name, also what `subscribe` accepts as a filter.
    static let names: Set<String> = ["workspace_changed", "focus_changed", "window_created",
                                     "window_destroyed", "zoom_changed", "attention_changed", "badge_changed"]

    static func add(_ fd: Int32, filter: Set<String>) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        queue.async { subscribers.append((fd, filter)) }
    }

    static var hasSubscribers: Bool { queue.sync { !subscribers.isEmpty } }

    static func emit(_ name: String, _ fields: [String: Any] = [:]) {
        var obj = fields
        obj["event"] = name
        obj["ts_ms"] = Int((Date().timeIntervalSince1970 * 1000).rounded())   // integer: a JSON double prints 1791190243.1760001
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        let line = Array(data) + [0x0A]
        queue.async {
            guard !subscribers.isEmpty else { return }
            subscribers.removeAll { sub in
                guard sub.filter.isEmpty || sub.filter.contains(name) else { return false }
                let n = line.withUnsafeBufferPointer { write(sub.fd, $0.baseAddress, $0.count) }
                if n == line.count { return false }
                close(sub.fd)   // gone, or too slow to drain a few hundred bytes: drop it
                return true
            }
        }
    }
}

extension WindowManager {
    func emitWindowEvent(_ name: String, _ w: ManagedWindow) {
        Events.emit(name, ["app": w.appName, "bundle": w.app.bundleIdentifier ?? NSNull(),
                           "title": w.title, "window": w.lastKnownID.map { Int($0) as Any } ?? NSNull(),
                           "workspace": activeSpaceID.map { Int($0) as Any } ?? NSNull()])
    }

    /// Called from updateFocusIndicator, which every focus move goes through. One compare when
    /// nothing changed.
    func emitFocusIfChanged() {
        let w = focused?.window
        let id = w?.lastKnownID
        guard id != lastEmittedFocusID else { return }
        lastEmittedFocusID = id
        guard let w else { return }
        Events.emit("focus_changed", ["app": w.appName, "bundle": w.app.bundleIdentifier ?? NSNull(), "title": w.title,
                                      "window": id.map { Int($0) as Any } ?? NSNull(),
                                      "workspace": activeSpaceID.map { Int($0) as Any } ?? NSNull()])
    }
}

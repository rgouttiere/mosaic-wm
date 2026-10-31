import AppKit

/// Live windows that leave EVERY tree two or more at once are logged with the callers that let
/// them go. Each path that removes a leaf on purpose writes its own line (detach, ghost purge,
/// dedup, move, scratchpad); on 2026-10-30 ws1's seven-window stack vanished between two such lines
/// and the journal said nothing — the cause could only be guessed at. The hooks sit where a whole
/// tree can go at once: a workspace's root reassigned, a workspace replaced or removed. The verdict
/// waits for the next turn of the main loop, so a move has re-homed its leaves by then; and a closed
/// window no longer resolves. Neither is a loss.
enum TreeAudit {
    static weak var manager: WindowManager?

    /// `old` (a root of `state`, or of workspace `ws` when that workspace itself is going) is being
    /// replaced by `new`: note the windows `new` does not hold.
    static func note(_ old: Container?, replacedBy new: Container?,
                     in state: WindowManager.SpaceState, ws: UInt64? = nil) {
        guard let old, manager != nil else { return }
        var kept = Set<ObjectIdentifier>()
        new?.forEachLeaf { if let w = $0.window { kept.insert(ObjectIdentifier(w)) } }
        var dropped: [ManagedWindow] = []
        old.forEachLeaf { if let w = $0.window, !kept.contains(ObjectIdentifier(w)) { dropped.append(w) } }
        guard dropped.count >= 2 else { return }
        // Mangled, like the double-write line: `swift demangle --compact` on it.
        let callers = Thread.callStackSymbols.dropFirst(2).prefix(8)
            .map { $0.split(separator: " ").dropFirst(3).first.map(String.init) ?? "?" }
        DispatchQueue.main.async { verify(dropped, from: state, ws: ws, callers: callers) }
    }

    private static func verify(_ dropped: [ManagedWindow], from state: WindowManager.SpaceState,
                               ws: UInt64?, callers: [String]) {
        guard let wm = manager else { return }
        // By element, not by object: a rebuild wraps the same windows in new ManagedWindows.
        var held: [AXUIElement] = []
        for st in wm.spaces.values { st.root?.forEachLeaf { if let w = $0.window { held.append(w.element) } } }
        let lost = dropped.filter { w in
            !held.contains { CFEqual($0, w.element) } && AX.windowID(w.element) != nil
        }
        guard lost.count >= 2 else { return }
        let name = (ws ?? wm.spaces.first { $0.value === state }?.key).map { "ws\($0)" } ?? "a workspace"
        Log.event("tree loss: \(name) let go of \(lost.count) live window(s) — "
                  + lost.map(\.appName).joined(separator: ", ") + " — " + callers.joined(separator: " < "))
    }
}

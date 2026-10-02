import AppKit

/// One arrangement of a workspace, as it was just before a structural edit.
struct UndoSnapshot {
    let space: UInt64
    let tree: SavedNode
    let mode: String
    let focusedID: CGWindowID?
    let at: Date
}

/// Bounded history of snapshots. Pure, so the coalescing and the per-workspace pop are tested
/// without a tree or a window in sight.
struct UndoRing {
    private(set) var items: [UndoSnapshot] = []
    let capacity: Int
    let coalesce: TimeInterval

    init(capacity: Int = 10, coalesce: TimeInterval = 1.5) {
        self.capacity = max(1, capacity); self.coalesce = coalesce
    }

    /// Push — unless the newest snapshot of the same workspace is younger than `coalesce`: a burst
    /// of resize steps or arrow-key moves is one gesture, and one undo should take it back whole.
    mutating func push(_ s: UndoSnapshot) {
        if let last = items.last, last.space == s.space, s.at.timeIntervalSince(last.at) < coalesce { return }
        items.append(s)
        if items.count > capacity { items.removeFirst(items.count - capacity) }
    }

    /// The newest snapshot of `space`, removed from the history.
    mutating func pop(space: UInt64) -> UndoSnapshot? {
        guard let i = items.lastIndex(where: { $0.space == space }) else { return nil }
        return items.remove(at: i)
    }
}

/// `undo`: put the active workspace back the way it was before the last edit. A drop on the wrong
/// tile, a move too many, a reset — until now the only way back was to redo the layout by hand.
/// The tree already serialises for `state.json` and rebuilds by window id within a session, so a
/// snapshot before each structural edit is all the machinery it needs.
extension WindowManager {
    /// Remember the active workspace (or `state`'s) before a structural edit. Only USER edits call
    /// this: a window opening or closing is not something an undo could take back, and a snapshot
    /// taken on those would make `undo` jump to an unrelated moment.
    func snapshotForUndo(_ state: SpaceState? = nil) {
        guard let sid = state.flatMap(workspaceID(of:)) ?? activeSpaceID,
              let st = spaces[sid], let root = st.root else { return }
        undoRing.push(UndoSnapshot(space: sid, tree: serialize(root), mode: modeName(st.mode),
                                   focusedID: st.focused?.window?.lastKnownID, at: Date()))
    }

    /// Windows that arrived since the snapshot are tiled again (after the focused one, like any new
    /// window); windows that left are simply absent from the rebuilt tree. Active workspace only —
    /// a snapshot of another workspace waits there until you are on it.
    func undo() {
        checkSpaceChange()
        guard let sid = activeSpaceID, let st = spaces[sid] else { return }
        guard let snap = undoRing.pop(space: sid) else { Log.event("undo — nothing to undo on ws\(sid)"); return }
        var pool: [ManagedWindow] = []
        var parked = Set<ObjectIdentifier>()   // hidden cross-app tabs already pushed off-screen
        st.root?.forEachLeaf { leaf in
            guard let w = leaf.window else { return }
            pool.append(w)
            if leaf.parkedOffScreen { parked.insert(ObjectIdentifier(w)) }
        }
        guard let newRoot = rebuild(snap.tree, pool: &pool) else {
            Log.event("undo — ws\(sid): none of the snapshot's windows exists any more"); return
        }
        // The rebuilt leaves are new objects, but the windows' situation is not: a hidden cross-app
        // tab that was parked is still parked. Carrying the flag over spares the first render the
        // place-then-park double write the frame audit would otherwise count against the window.
        newRoot.forEachLeaf { leaf in
            if let w = leaf.window, parked.contains(ObjectIdentifier(w)) { leaf.parkedOffScreen = true }
        }
        st.root?.teardown()
        st.root = newRoot
        st.mode = mode(named: snap.mode)
        wireTabCallbacks(newRoot)
        var newFocus: Container?
        newRoot.forEachLeaf { if let id = $0.window?.lastKnownID, id == snap.focusedID { newFocus = $0 } }
        st.focused = newFocus ?? newRoot.firstLeaf()
        for w in pool { insert(w) }   // opened after the snapshot → tiled again, after the focused one
        Log.event("undo — ws\(sid) back to \(Int(Date().timeIntervalSince(snap.at))) s ago"
                  + (pool.isEmpty ? "" : ", \(pool.count) newer window(s) re-inserted"))
        render()
    }
}

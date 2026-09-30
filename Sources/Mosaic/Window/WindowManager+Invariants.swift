import AppKit

extension WindowManager {
    /// Flatten the live trees into plain values. This is the only impure half of the invariant
    /// check — reading the model and each window's frame — so that judging it (`violations()`)
    /// stays pure and testable. Read-only: a violation is a bug to fix at its source, never
    /// something to quietly repair on the way past.
    func layoutSnapshot() -> LayoutSnapshot {
        // Which leaves are actually on screen: the visible path of each workspace a present monitor
        // shows. Collected first so the per-workspace walk below can just look the answer up.
        var visible = Set<ObjectIdentifier>()
        for (did, sid) in shownOnDisplay {
            guard screen(forDisplayID: did) != nil, let root = spaces[sid]?.root else { continue }
            root.forEachVisibleLeaf { visible.insert(ObjectIdentifier($0)) }
        }

        var leaves: [LayoutSnapshot.Leaf] = []
        var workspaces: [LayoutSnapshot.Workspace] = []
        for (sid, ws) in spaces {
            var count = 0
            ws.root?.forEachLeaf { leaf in
                count += 1
                let w = leaf.window
                leaves.append(.init(
                    workspace: sid,
                    windowID: w.flatMap { $0.lastKnownID ?? $0.resolvedID() },
                    appName: w?.appName ?? "(dead)",
                    hasWindow: w != nil,
                    tile: leaf.lastFrame,
                    frame: w?.frame.map { Geometry.flip($0) },
                    visible: visible.contains(ObjectIdentifier(leaf)),
                    parkedOffScreen: leaf.parkedOffScreen,
                    isFullscreen: w?.isFullscreen ?? false,
                    isPiPSource: leaf === pipSourceLeaf
                ))
            }
            workspaces.append(.init(id: sid, displayID: ws.displayID, leafCount: count))
        }
        return LayoutSnapshot(workspaces: workspaces, leaves: leaves)
    }

    func checkInvariants() -> [LayoutSnapshot.Violation] { layoutSnapshot().violations() }
}

import AppKit

/// States the layout model must never be in. Each one here was a real bug that reached the user as
/// "my windows are a mess" with nothing in the logs — the model was wrong but nobody was asking.
/// Checking them turns a silent impossible state into a named one, and `dump-layout` reports it.
///
/// These are deliberately cheap and read-only: they walk the trees we already own and compare
/// against frames the 50ms cache usually already holds. Nothing here writes or repairs — a violation
/// is a bug to fix at its source, not something to paper over on the way past.
extension WindowManager {
    struct Violation {
        let code: String
        let detail: String
    }

    func checkInvariants() -> [Violation] {
        var out: [Violation] = []

        // 1. One window, one leaf. Three leaves pointing at one window make arrange write it three
        //    times — last write wins, so it lands on whichever tile came last, off its own monitor.
        var byID: [CGWindowID: [String]] = [:]
        for (sid, ws) in spaces {
            ws.root?.forEachLeaf { leaf in
                guard let w = leaf.window, let id = w.lastKnownID ?? w.resolvedID() else { return }
                byID[id, default: []].append("ws\(sid):\(w.appName)")
            }
        }
        for (id, owners) in byID.sorted(by: { $0.key < $1.key }) where owners.count > 1 {
            out.append(.init(code: "duplicate-leaf",
                             detail: "wid=\(id) is held by \(owners.count) leaves — \(owners.joined(separator: ", "))"))
        }

        // 2. A workspace holding windows must have a home display. `screen(forWorkspace:)` excludes
        //    displayID == 0 by construction, so such a workspace can never be shown on ANY monitor
        //    again: its windows are stranded off-screen with no way back.
        for (sid, ws) in spaces.sorted(by: { $0.key < $1.key }) where ws.displayID == 0 {
            var count = 0
            ws.root?.forEachLeaf { _ in count += 1 }
            if count > 0 {
                out.append(.init(code: "workspace-without-display",
                                 detail: "ws\(sid) has \(count) window(s) but displayID == 0 — unreachable"))
            }
        }

        for (did, sid) in shownOnDisplay.sorted(by: { $0.key < $1.key }) {
            guard screen(forDisplayID: did) != nil, let root = spaces[sid]?.root else { continue }
            root.forEachVisibleLeaf { leaf in
                guard let w = leaf.window else {
                    out.append(.init(code: "dead-leaf", detail: "ws\(sid) has a leaf with no window"))
                    return
                }
                // 3. A VISIBLE leaf must never be flagged parked: `arrange` skips placing a parked
                //    leaf, so the window stays wherever the park put it — ~40px on screen, forever.
                if leaf.parkedOffScreen {
                    out.append(.init(code: "parked-but-visible",
                                     detail: "ws\(sid) \(w.appName) is on the visible path yet parkedOffScreen"))
                }
                // 4. A window may be smaller than its tile (letterboxed), never outside it.
                guard !w.isFullscreen, leaf !== pipSourceLeaf,
                      let f = w.frame, leaf.lastFrame.width > 0 else { return }
                let win = Geometry.flip(f)
                if Geometry.escapesTile(window: win, tile: leaf.lastFrame) {
                    out.append(.init(code: "window-off-tile",
                                     detail: "ws\(sid) \(w.appName) at \(rectStr(win)) escapes its tile \(rectStr(leaf.lastFrame))"))
                }
            }
        }
        return out
    }
}

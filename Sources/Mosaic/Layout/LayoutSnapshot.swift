import AppKit

/// A flat, immutable copy of everything the invariants need to judge the layout. Plain values only:
/// no `Container`, no `ManagedWindow`, nothing that needs a live window to exist. That is the whole
/// point — `violations()` is pure, so an impossible state can be built by hand in a self-test instead
/// of having to be reproduced with real windows on a real desktop (which is why the checks this
/// replaces could only ever be read, never proven).
struct LayoutSnapshot {
    struct Leaf {
        let workspace: UInt64
        let windowID: CGWindowID?     // nil when AX can't resolve it right now — not proof of death
        let appName: String
        let hasWindow: Bool           // a leaf whose window is gone entirely
        let tile: CGRect              // the rect the layout assigned (Cocoa)
        let frame: CGRect?            // where the window actually is (Cocoa)
        let visible: Bool             // on the visible path of a workspace currently shown
        let parkedOffScreen: Bool
        let isFullscreen: Bool
        let isPiPSource: Bool
    }

    struct Workspace {
        let id: UInt64
        let displayID: CGDirectDisplayID
        let leafCount: Int
    }

    let workspaces: [Workspace]
    let leaves: [Leaf]

    struct Violation: Equatable {
        let code: String
        let detail: String
    }

    /// States the model must never be in. Every one of these was a real bug that reached the user as
    /// "my windows are a mess", with nothing in the logs — the model was wrong but nobody asked it.
    func violations() -> [Violation] {
        var out: [Violation] = []

        // One window, one leaf. Several leaves pointing at one window make arrange write it several
        // times — last write wins, so it lands on whichever tile came last, off its own monitor.
        var owners: [CGWindowID: [String]] = [:]
        for leaf in leaves {
            guard let id = leaf.windowID else { continue }
            owners[id, default: []].append("ws\(leaf.workspace):\(leaf.appName)")
        }
        for (id, who) in owners.sorted(by: { $0.key < $1.key }) where who.count > 1 {
            out.append(.init(code: "duplicate-leaf",
                             detail: "wid=\(id) is held by \(who.count) leaves — \(who.joined(separator: ", "))"))
        }

        // A workspace holding windows must have a home display: `screen(forWorkspace:)` excludes
        // displayID == 0 by construction, so it can never be shown on ANY monitor again and its
        // windows are stranded off-screen with no way back.
        for ws in workspaces.sorted(by: { $0.id < $1.id }) where ws.displayID == 0 && ws.leafCount > 0 {
            out.append(.init(code: "workspace-without-display",
                             detail: "ws\(ws.id) has \(ws.leafCount) window(s) but displayID == 0 — unreachable"))
        }

        for leaf in leaves {
            if !leaf.hasWindow {
                out.append(.init(code: "dead-leaf", detail: "ws\(leaf.workspace) has a leaf with no window"))
                continue
            }
            guard leaf.visible else { continue }
            // `arrange` skips placing a parked leaf, so a visible one carrying the flag is never
            // written again: it stays wherever the park left it, ~40px on screen, for good.
            if leaf.parkedOffScreen {
                out.append(.init(code: "parked-but-visible",
                                 detail: "ws\(leaf.workspace) \(leaf.appName) is on the visible path yet parkedOffScreen"))
            }
            // A window may sit SMALLER than its tile (an aspect-locked player letterboxes inside it),
            // never outside it. Full-screen windows own their Space, and the PiP source's tile is
            // deliberately covered, so neither is judged here.
            guard !leaf.isFullscreen, !leaf.isPiPSource,
                  let f = leaf.frame, leaf.tile.width > 0 else { continue }
            if Geometry.escapesTile(window: f, tile: leaf.tile) {
                out.append(.init(code: "window-off-tile",
                                 detail: "ws\(leaf.workspace) \(leaf.appName) escapes its tile"))
            }
        }
        return out
    }
}

import AppKit

extension WindowManager {
    /// Rules with `followTitle` re-apply their `workspace` when a window's TITLE comes to match.
    /// A kitty window is born as "zsh" and only reads "k8s · k9s" once tmux is attached, long after
    /// the insert-time rule check. Runs on every title-change notification: titles are cached, and
    /// a window is moved only when the rule that matches it CHANGES (`lastTitleRoute`), so the
    /// tmux title ticking from "k8s · zsh" to "k8s · k9s" never undoes a manual move.
    func rerouteByTitle() {
        guard !suspended, Date() >= wakeGraceUntil, !tabDragging else { return }
        var moves: [(leaf: Container, from: SpaceState, to: Int, window: ManagedWindow)] = []
        for (sid, ws) in spaces {
            ws.root?.forEachLeaf { leaf in
                guard let w = leaf.window, let rule = ruleFor(w), rule.followTitle == true else { return }
                let key = rule.title ?? rule.app
                guard key != w.lastTitleRoute else { return }
                w.lastTitleRoute = key
                guard let n = rule.workspace, n >= 1, n <= 9, UInt64(n) != sid else { return }
                moves.append((leaf, ws, n, w))
            }
        }
        guard !moves.isEmpty else { return }
        for m in moves {
            Log.event("re-route \(m.window.logLabel) → ws\(m.to) (title now matches rule)")
            moveLeaf(m.leaf, from: m.from, toWorkspace: m.to)
        }
        if focused == nil || !(focused.map(treeContainsLeaf) ?? false) { focused = root?.firstLeaf() }
        render()
        saveNow()
    }
}

#if DEBUG
import Foundation

/// In-module self-test for Mosaic's pure logic (layout tree + config parsing). Run it with
/// `.build/debug/Mosaic --self-test` or `make test`.
///
/// Why in-module and hand-rolled rather than XCTest / Swift Testing: the Command Line Tools
/// ship an incomplete copy of both frameworks (they compile and link but fail to load at
/// runtime without a full Xcode install), and a separate test target can't link against an
/// executable target's symbols anyway. Living inside the module — behind `#if DEBUG`, so it's
/// excluded from release/`make dist` — lets the suite reach internal types and run with just
/// `swift build`. Exits non-zero on any failure (CI-friendly).
enum SelfTest {

    final class Harness {
        var passed = 0, failed = 0
        func check(_ cond: Bool, _ what: String, _ f: StaticString = #fileID, _ l: UInt = #line) {
            if cond { passed += 1 }
            else { failed += 1; FileHandle.standardError.write(Data("  ✗ \(what)  [\(f):\(l)]\n".utf8)) }
        }
        func eq<T: Equatable>(_ got: T, _ want: T, _ what: String,
                              _ f: StaticString = #fileID, _ l: UInt = #line) {
            check(got == want, "\(what) — expected \(want), got \(got)", f, l)
        }
    }

    static func run() -> Int32 {
        let h = Harness()
        containerTests(h)
        configTests(h)
        windowManagerTests(h)
        print("MosaicSelfTest: \(h.passed) passed, \(h.failed) failed")
        return h.failed == 0 ? 0 : 1
    }

    // MARK: - WindowManager: drifted-window detection (wake/display re-home)

    private static func windowManagerTests(_ h: Harness) {
        let left = CGRect(x: -1512, y: 0, width: 1512, height: 982)   // screen to the left (negative x)
        let main = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let screens = [left, main]
        h.check(WindowManager.isDrifted(center: CGPoint(x: -700, y: 400), home: main, screens: screens),
                "isDrifted: window on left but home is main → drifted")
        h.check(!WindowManager.isDrifted(center: CGPoint(x: 1000, y: 400), home: main, screens: screens),
                "isDrifted: window on its home (main) → not drifted")
        h.check(!WindowManager.isDrifted(center: CGPoint(x: -700, y: 400), home: left, screens: screens),
                "isDrifted: window on left, home left → not drifted")
        h.check(!WindowManager.isDrifted(center: CGPoint(x: 99999, y: 0), home: main, screens: screens),
                "isDrifted: off all screens → not touched (false)")
    }

    // MARK: - Container: layout-tree invariants
    //
    // Leaves need a ManagedWindow (an AX element we can't fake here), so trees are built from
    // empty *group* containers — all that removeChild / ratios / selected care about.

    private static func tabbedParent(_ n: Int) -> (parent: Container, kids: [Container]) {
        let kids = (0..<n).map { _ in Container(layout: .splitH, children: []) }
        return (Container(layout: .tabbed, children: kids), kids)
    }

    private static func containerTests(_ h: Harness) {
        // removeChild — the selection-shift invariant (TAB-SELECTED-SHIFT)
        do {
            let (p, kids) = tabbedParent(4)          // [A,B,C,D]
            p.selected = 2                           // C
            p.removeChild(at: 0)                     // remove A → [B,C,D]
            h.eq(p.children.count, 3, "removeChild below selected: count")
            h.eq(p.selected, 1, "removeChild below selected: index shifts")
            h.check(p.children[p.selected] === kids[2], "removeChild below selected: still points at C")
        }
        do {
            let (p, kids) = tabbedParent(4)          // [A,B,C,D]
            p.selected = 1                           // B
            p.removeChild(at: 2)                     // remove C → [A,B,D]
            h.eq(p.selected, 1, "removeChild above selected: index unchanged")
            h.check(p.children[p.selected] === kids[1], "removeChild above selected: still points at B")
        }
        do {
            let (p, _) = tabbedParent(3)             // [A,B,C]
            p.selected = 2                           // C (last)
            p.removeChild(at: 2)                     // remove C → [A,B]
            h.eq(p.children.count, 2, "remove selected last: count")
            h.check(p.children.indices.contains(p.selected), "remove selected last: selected in range")
            h.eq(p.selected, 1, "remove selected last: clamps to new last")
        }
        do {
            let (p, _) = tabbedParent(1)
            p.selected = 0
            p.removeChild(at: 0)
            h.check(p.children.isEmpty, "remove last remaining: empty")
            h.eq(p.selected, 0, "remove last remaining: selected 0")
        }
        do {
            let (p, _) = tabbedParent(2)
            p.selected = 1
            p.removeChild(at: 5)                     // out of bounds
            h.eq(p.children.count, 2, "removeChild OOB: no-op count")
            h.eq(p.selected, 1, "removeChild OOB: no-op selected")
        }

        // selected didSet clamp
        do {
            let (p, _) = tabbedParent(3)
            p.selected = 99
            h.eq(p.selected, 2, "selected clamps high → count-1")
            p.selected = -5
            h.eq(p.selected, 0, "selected clamps low → 0")
        }

        // ratios stay consistent with child count
        do {
            let (p, _) = tabbedParent(4)
            p.removeChild(at: 0)
            h.eq(p.ratios.count, p.children.count, "removeChild: ratios count matches children")
            h.check(abs(p.ratios.reduce(0, +) - 1.0) < 1e-9, "removeChild: ratios still sum to 1")
        }
        do {
            let p = Container(layout: .splitH, children: [
                Container(layout: .splitH, children: []),
                Container(layout: .splitH, children: []),
            ])
            p.children.append(Container(layout: .splitH, children: []))
            p.addRatio(at: 2)
            h.eq(p.ratios.count, 3, "addRatio: count")
            h.check(abs(p.ratios.reduce(0, +) - 1.0) < 1e-9, "addRatio: ratios sum to 1")
        }
        do {
            let p = Container(layout: .splitH, children: [
                Container(layout: .splitH, children: []),
                Container(layout: .splitH, children: []),
            ])
            p.ratios = [0.9]                         // inconsistent with 2 children
            p.normalizeRatios()
            h.eq(p.ratios, [0.5, 0.5], "normalizeRatios: resets to equal on mismatch")
        }

        // identity
        do {
            let (p, kids) = tabbedParent(3)
            h.eq(p.index(of: kids[1]), 1, "index(of:) by identity")
            h.check(p.index(of: Container(layout: .splitH, children: [])) == nil, "index(of:) stranger is nil")
        }
    }

    // MARK: - Config: robustness (CFG-ALL-OR-NOTHING + CFG-KEY-CRASH)

    private static func decodeFile(_ json: String) -> Config.File? {
        try? JSONDecoder().decode(Config.File.self, from: Data(json.utf8))
    }

    private static func configTests(_ h: Harness) {
        // Lenient per-field decode: valid config, no issues.
        if let f = decodeFile(#"{"gap":10,"defaultMode":"tabbed","borderEnabled":true}"#) {
            h.eq(f.gap, 10, "valid: gap")
            h.eq(f.defaultMode, "tabbed", "valid: defaultMode")
            h.eq(f.borderEnabled, true, "valid: borderEnabled")
            h.check(f.decodeIssues.isEmpty, "valid: no issues")
        } else { h.check(false, "valid config failed to decode") }

        // One bad field must NOT sink the rest (the core CFG-ALL-OR-NOTHING fix).
        if let f = decodeFile(#"{"gap":"ten","defaultMode":"tabbed","borderEnabled":true}"#) {
            h.check(f.gap == nil, "one-bad: gap dropped")
            h.eq(f.defaultMode, "tabbed", "one-bad: defaultMode survives")
            h.eq(f.borderEnabled, true, "one-bad: borderEnabled survives")
            h.eq(f.decodeIssues, ["gap"], "one-bad: gap reported")
        } else { h.check(false, "one-bad config failed to decode") }

        // Missing field is not an issue.
        if let f = decodeFile(#"{"gap":10}"#) {
            h.eq(f.gap, 10, "missing: gap present")
            h.check(f.defaultMode == nil, "missing: defaultMode nil")
            h.check(f.decodeIssues.isEmpty, "missing ≠ malformed")
        } else { h.check(false, "missing-field config failed to decode") }

        // Several bad fields → all reported.
        if let f = decodeFile(#"{"gap":"x","borderWidth":true,"tabFontSize":"big"}"#) {
            h.check(f.gap == nil && f.borderWidth == nil && f.tabFontSize == nil, "multi-bad: all dropped")
            h.eq(Set(f.decodeIssues), ["gap", "borderWidth", "tabFontSize"], "multi-bad: all reported")
        } else { h.check(false, "multi-bad config failed to decode") }

        // Malformed structured field loses only that field.
        if let f = decodeFile(#"{"gap":10,"rules":[1,2,3]}"#) {
            h.eq(f.gap, 10, "bad-rules: gap survives")
            h.check(f.rules == nil, "bad-rules: rules dropped")
            h.eq(f.decodeIssues, ["rules"], "bad-rules: rules reported")
        } else { h.check(false, "bad-rules config failed to decode") }

        // workspaceNames parsing must never trap (CFG-KEY-CRASH).
        do {
            let (names, issues) = Config.parseWorkspaceNames(["1": "web", "2": "chat"])
            h.eq(names, [1: "web", 2: "chat"], "wsNames: valid")
            h.check(issues.isEmpty, "wsNames: valid → no issues")
        }
        do {
            let (names, issues) = Config.parseWorkspaceNames(["1": "a", "01": "b"])  // both → 1
            h.eq(names.count, 1, "wsNames: collision collapses to one")
            h.check(names[1] != nil, "wsNames: collision keeps a value")
            h.eq(issues.count, 1, "wsNames: collision reported")
        }
        do {
            let (names, issues) = Config.parseWorkspaceNames(["0": "x", "10": "y", "3": "ok"])
            h.eq(names, [3: "ok"], "wsNames: out-of-range dropped")
            h.eq(issues.count, 2, "wsNames: out-of-range reported")
        }
        do {
            let (names, issues) = Config.parseWorkspaceNames(["foo": "x", "2": "ok"])
            h.eq(names, [2: "ok"], "wsNames: non-numeric skipped")
            h.check(issues.isEmpty, "wsNames: non-numeric is not an issue")
        }
    }
}
#endif

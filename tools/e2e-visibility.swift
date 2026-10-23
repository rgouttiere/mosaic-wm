// End-to-end check on the RUNNING Mosaic that no window is lost: throwaway windows (Calculator,
// one instance each → one app per window, the cross-app case the tabs exist for) on two spare
// workspaces, then switches, tab cycles, groupings, moves, swaps, closes and opens at random, fast
// and slow. After each step, once Mosaic has settled, the shown workspace's windows must be on a
// display (nearly all of their area, not the 40 px sliver of a parked window), the selected tab
// of every group must be in front of its siblings (the window server's order, front to back), the
// hidden workspace's windows must be off screen, and `dump-layout` must end in `invariants (OK)`.
//
//   make e2e                                   # = swiftc + run on workspaces 8 and 9, 40 rounds
//   .build/e2e-visibility [ws-a] [ws-b] [rounds]
//
// It drives Mosaic through `mosaic <action>`, warps the mouse and takes the keyboard focus with
// it: use workspaces you do not need and keep your hands off for the minute it takes. The test
// windows are closed at the end and the workspace you were on is shown again. Exit code 1 when a
// window was lost, with the dump that shows it.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let wsA = args.count > 1 ? Int(args[1]) ?? 8 : 8
let wsB = args.count > 2 ? Int(args[2]) ?? 9 : 9
let rounds = args.count > 3 ? Int(args[3]) ?? 40 : 40
let windowsPerWorkspace = 2

// MARK: - Mosaic

@discardableResult
func mosaic(_ arguments: String...) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["mosaic"] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: out, as: UTF8.self)
}

struct DumpWindow { let wid: UInt32; let intersectsScreen: Bool; let cgOnScreen: Bool }
struct DumpGroup { let selected: UInt32?; let members: [UInt32] }   // a tabbed/stacked group: shown tab, every leaf
struct DumpWorkspace {
    let number: Int
    let shown: Bool
    let homeDisplay: Int
    var windows: [DumpWindow] = []
    var groups: [DumpGroup] = []
}
struct Dump {
    let text: String
    var workspaces: [Int: DumpWorkspace] = [:]
    /// `monitor n frame=(x,y w×h)`, in the window server's coordinates like CGWindowList's bounds.
    var monitors: [Int: CGRect] = [:]
    var invariantsOK = false
    /// The violation lines, without their counts (`— 4 renders`), so a run compares them with the
    /// ones that were already there: a `double-frame-write` from before the test is not its finding.
    var violations: [String] = []

    /// `mosaic dump-layout`: `WORKSPACE n [SHOWN|PARKED]`, one line per window (`wid=`,
    /// `intersectsScreen=`, `cgOnScreen=`), the tree (`▸ tabbed [k kids, selected=i]` with its
    /// `• leaf … wid=` children deeper indented), and `--- invariants (OK) ---` at the end.
    init(_ text: String) {
        self.text = text
        var current: Int? = nil
        var inInvariants = false
        var groupStack: [(indent: Int, selectedIndex: Int, index: Int, selected: UInt32?, members: [UInt32])] = []
        func closeGroups(downTo indent: Int) {
            while let g = groupStack.last, g.indent >= indent {
                groupStack.removeLast()
                // a split is on the stack only to carry its indent: its children are all shown
                if let ws = current, g.selectedIndex >= 0 {
                    workspaces[ws]?.groups.append(DumpGroup(selected: g.selected, members: g.members))
                }
            }
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let indent = line.prefix { $0 == " " }.count
            let body = line.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("WORKSPACE ") {
                closeGroups(downTo: 0)
                let parts = body.split(separator: " ")
                guard parts.count >= 3, let n = Int(parts[1]) else { continue }
                current = n
                workspaces[n] = DumpWorkspace(number: n, shown: parts[2] == "[SHOWN]",
                                              homeDisplay: value("homeDisplay=", in: body).flatMap { Int($0) } ?? 0)
            } else if body.hasPrefix("monitor "), let r = body.range(of: "frame=(") {
                let parts = body.split(separator: " ")
                let nums = body[r.upperBound...].prefix { $0 != ")" }
                    .replacingOccurrences(of: "×", with: ",").replacingOccurrences(of: " ", with: ",")
                    .split(separator: ",").compactMap { Double($0) }
                if parts.count >= 2, let n = Int(parts[1]), nums.count == 4 {
                    monitors[n] = CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
                }
            } else if body.hasPrefix("---") {
                closeGroups(downTo: 0)
                current = nil
                inInvariants = body.hasPrefix("--- invariants")
                if body.hasPrefix("--- invariants (OK)") { invariantsOK = true }
            } else if inInvariants {
                if body.hasPrefix("[") {
                    var v = body
                    for cut in [" took ", " — "] { if let r = v.range(of: cut) { v = String(v[..<r.lowerBound]) } }
                    violations.append(v)
                }
            } else if let ws = current, body.contains("wid="), body.contains("intersectsScreen=") {
                guard let wid = value("wid=", in: body).flatMap({ UInt32($0) }) else { continue }
                let window = DumpWindow(
                    wid: wid,
                    intersectsScreen: value("intersectsScreen=", in: body) == "true",
                    cgOnScreen: value("cgOnScreen=", in: body) == "true")
                workspaces[ws]?.windows.append(window)
            } else if current != nil, body.hasPrefix("▸") {
                closeGroups(downTo: indent)
                let grouped = body.contains("tabbed") || body.contains("stacked")
                let sel = value("selected=", in: body.replacingOccurrences(of: "]", with: " ")).flatMap { Int($0) } ?? -1
                groupStack.append((indent, grouped ? sel : -1, 0, nil, []))
            } else if current != nil, body.hasPrefix("•") {
                closeGroups(downTo: indent)
                guard let wid = value("wid=", in: body).flatMap({ UInt32($0) }) else { continue }
                // the leaf belongs to every enclosing group; it is the shown tab of the innermost
                // grouped one at its selected index
                for i in groupStack.indices {
                    groupStack[i].members.append(wid)
                    if i == groupStack.count - 1 || groupStack[i + 1].indent > groupStack[i].indent {
                        if groupStack[i].selectedIndex == groupStack[i].index { groupStack[i].selected = wid }
                    }
                }
                if !groupStack.isEmpty { groupStack[groupStack.count - 1].index += 1 }
            } else if current != nil, body.isEmpty {
                closeGroups(downTo: 0)
            }
        }
        closeGroups(downTo: 0)
    }
    private func value(_ key: String, in s: String) -> String? {
        guard let r = s.range(of: key) else { return nil }
        return String(s[r.upperBound...].prefix { $0 != " " && $0 != "\n" })
    }
}

func dump() -> Dump { Dump(mosaic("dump-layout")) }
func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

// MARK: - Window server

struct CGWin { let wid: UInt32; let pid: pid_t; let bounds: CGRect; let onScreen: Bool }

/// Every window of `pids` at layer 0, front to back.
func serverWindows(of pids: Set<pid_t>) -> [CGWin] {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
              (w[kCGWindowLayer as String] as? Int) == 0,
              let wid = w[kCGWindowNumber as String] as? UInt32,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        return CGWin(wid: wid, pid: pid, bounds: r, onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }
}

let displays: [CGRect] = {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.map { CGDisplayBounds($0) }
}()

/// Share of the window's area that lies on a display.
func visibleShare(_ r: CGRect) -> CGFloat {
    guard r.width > 0, r.height > 0 else { return 0 }
    let area = displays.reduce(CGFloat(0)) { $0 + r.intersection($1).standardized.size.area }
    return area / (r.width * r.height)
}
/// The largest piece of the window on a display. A parked window keeps a sliver of about 40 px on
/// its monitor's edge (the window server refuses to push it further), which the tiles cover: the
/// piece is a strip, thin in one direction. A hidden window showing more than a strip is a finding.
func visiblePiece(_ r: CGRect) -> CGSize {
    displays.map { r.intersection($0).standardized.size }.max { $0.area < $1.area } ?? .zero
}
let sliver: CGFloat = 44
extension CGSize { var area: CGFloat { width > 0 && height > 0 ? width * height : 0 } }

// MARK: - Test windows

func calculatorPids() -> Set<pid_t> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "Calculator"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return Set(out.split(separator: "\n").compactMap { pid_t($0) })
}

func osascript(_ source: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

/// A fresh Calculator instance (`open -n`): its pid, once it has a window Mosaic manages on `ws`.
/// Calculator opens where it last was, and Mosaic adopts a new window only on the ACTIVE monitor
/// (the one `ws` was just switched onto): a window that lands elsewhere is moved there, unmanaged
/// still, and its app activated again so the reconcile sees it.
func openCalculator(on ws: Int, known: Set<pid_t>) -> pid_t? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-n", "-a", "Calculator"]
    try? process.run()
    process.waitUntilExit()
    var pid: pid_t? = nil
    var wids = Set<UInt32>()
    var relocated = false
    for _ in 0..<40 {
        pause(0.25)
        pid = calculatorPids().subtracting(known).first
        guard let pid else { continue }
        let windows = serverWindows(of: [pid])
        wids = Set(windows.map(\.wid))
        let d = dump()
        // Either test workspace will do: a Calculator that vanished from the other one minutes ago
        // goes back there (Mosaic's return hint), and the checks do not care which one holds it.
        if [wsA, wsB].contains(where: { n in d.workspaces[n]?.windows.contains { wids.contains($0.wid) } ?? false }) { return pid }
        // Never move a window Mosaic already holds: parked (a hint sent it to the other test
        // workspace), its sliver sits just off the monitor and a move would drag it back on screen.
        let managedAnywhere = d.workspaces.values.contains { $0.windows.contains { wids.contains($0.wid) } }
        if !relocated, !managedAnywhere, let win = windows.first, let home = d.workspaces[ws]?.homeDisplay, let monitor = d.monitors[home],
           !monitor.contains(CGPoint(x: win.bounds.midX, y: win.bounds.midY)) {
            relocated = true
            let x = Int(monitor.midX - win.bounds.width / 2), y = Int(monitor.midY - win.bounds.height / 2)
            osascript("tell application \"System Events\" to tell (first application process whose unix id is \(pid)) to set position of window 1 to {\(x), \(y)}")
            pause(0.3)
            osascript("tell application \"System Events\" to set frontmost of (first application process whose unix id is \(pid)) to true")
        }
    }
    // say where it went instead: another workspace is a routing finding, nowhere is a discovery one
    let d = dump()
    let elsewhere = d.workspaces.values.filter { $0.windows.contains { wids.contains($0.wid) } }.map { "ws\($0.number)" }
    print("  Calculator pid \(pid.map(String.init) ?? "?") windows \(wids.sorted()): "
          + (elsewhere.isEmpty ? "not managed by Mosaic" : "managed on \(elsewhere.joined(separator: ", "))"))
    return nil
}

var testPids = Set<pid_t>()
let originalWorkspace = Int(mosaic("query", "focused").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
/// What every monitor showed before the test (`query active`), put back at the end: the test
/// parks whatever its monitor shows, and the probe may visit a workspace of each monitor.
let shownBefore = mosaic("query", "active").split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

func restoreDesk() {
    for n in shownBefore { mosaic("workspace-\(n)") }
    mosaic("workspace-\(originalWorkspace)")
}

func cleanup() {
    // Every Calculator the test started, managed or not — an instance Mosaic never adopted is still
    // ours. One at a time, on its own workspace, until its leaf is gone: only the active workspace
    // purges dead leaves, and three or more vanishing together read as a bulk (a sleep, a Space
    // switch) that Mosaic holds for 25 passes — the leaves would sit there for the next run.
    for pid in calculatorPids().subtracting(before) {
        let wids = Set(serverWindows(of: [pid]).map(\.wid))
        func holder() -> Int? { dump().workspaces.values.first { $0.windows.contains { wids.contains($0.wid) } }?.number }
        if let ws = holder() { mosaic("workspace-\(ws)"); pause(0.3) }
        kill(pid, SIGTERM)
        for _ in 0..<20 where holder() != nil { pause(0.4) }
    }
    restoreDesk()
}

func fail(_ why: String, _ d: Dump) -> Never {
    print("FAIL: \(why)\n")
    print(d.text)
    let wins = serverWindows(of: testPids.union(calculatorPids().subtracting(before)))   // adopted or not
    print("--- window server (front to back) ---")
    for w in wins { print("  wid=\(w.wid) pid=\(w.pid) bounds=\(w.bounds) onScreen=\(w.onScreen) visible=\(Int(visibleShare(w.bounds) * 100))%") }
    cleanup()
    exit(1)
}

// MARK: - The check

var baselineViolations = Set<String>()

/// One look at the desk, settled or not: the first problem, or nil. A problem that is gone a second
/// later was a slow app taking its time with a write Mosaic re-issues; one that stays is a finding.
func check(step: String) {
    guard let first = problem(step: step) else { return }
    pause(1.0)
    guard let again = problem(step: step) else { print("  \(step): transient — \(first)"); return }
    fail(again, dump())
}

func problem(step: String) -> String? {
    let d = dump()
    let fresh = Set(d.violations).subtracting(baselineViolations)
    if !fresh.isEmpty { return "\(step): new invariant violation(s): \(fresh.sorted().joined(separator: "; "))" }
    let wins = serverWindows(of: testPids)
    let byWid = Dictionary(wins.map { ($0.wid, $0) }, uniquingKeysWith: { a, _ in a })
    let order = Dictionary(wins.enumerated().map { ($1.wid, $0) }, uniquingKeysWith: { a, _ in a })
    for n in [wsA, wsB] {
        guard let ws = d.workspaces[n] else { continue }
        let hiddenTabs = Set(ws.groups.flatMap { g in g.members.filter { $0 != g.selected } })
        for w in ws.windows where byWid[w.wid] != nil {
            let share = visibleShare(byWid[w.wid]!.bounds)
            if ws.shown {
                if hiddenTabs.contains(w.wid) { continue }   // parked behind its group's shown tab, by design
                if !w.intersectsScreen || !w.cgOnScreen { return "\(step): ws\(n) is shown but wid=\(w.wid) is not on screen for Mosaic" }
                if share < 0.9 { return "\(step): ws\(n) is shown but wid=\(w.wid) has \(Int(share * 100))% of its area on a display" }
            } else {
                let piece = visiblePiece(byWid[w.wid]!.bounds)
                if min(piece.width, piece.height) > sliver {
                    return "\(step): ws\(n) is hidden but wid=\(w.wid) shows \(Int(piece.width))×\(Int(piece.height)) px on a display"
                }
            }
        }
        guard ws.shown else { continue }
        // The shown tab must be in front of any sibling that overlaps it. A cross-app sibling is
        // parked off screen (its order is moot); a same-app one stays on the tile, behind.
        for g in ws.groups {
            guard let sel = g.selected, let selOrder = order[sel], let selBounds = byWid[sel]?.bounds else { continue }
            for m in g.members where m != sel {
                guard let o = order[m], o < selOrder, let b = byWid[m]?.bounds else { continue }
                let overlap = b.intersection(selBounds).standardized.size
                if min(overlap.width, overlap.height) > sliver {
                    return "\(step): ws\(n) group shows wid=\(sel) but wid=\(m) is in front of it, overlapping \(Int(overlap.width))×\(Int(overlap.height)) px"
                }
            }
        }
    }
    return nil
}

// MARK: - Run

if ProcessInfo.processInfo.environment["MOSAIC_E2E_NO_RUNNING_CHECK"] == nil, mosaic("query", "focused").isEmpty {
    print("Mosaic is not answering on its socket"); exit(2)
}
print("e2e-visibility: \(rounds) rounds, from workspace \(originalWorkspace)" + (wsA > 0 && wsB > 0 ? ", workspaces \(wsA) and \(wsB)" : ""))
if ProcessInfo.processInfo.environment["MOSAIC_E2E_PARSE_ONLY"] != nil {   // how the dump reads, nothing touched
    let d = dump()
    for ws in d.workspaces.values.sorted(by: { $0.number < $1.number }) {
        let groups = ws.groups.map { "\($0.selected.map(String.init) ?? "-") shown of \($0.members)" }
        print("ws\(ws.number) \(ws.shown ? "shown" : "parked"): \(ws.windows.count) window(s), groups: \(groups)")
    }
    print("invariants ok: \(d.invariantsOK)" + (d.violations.isEmpty ? "" : " — \(d.violations.joined(separator: "; "))"))
    exit(0)
}
// The test workspaces must be empty. A previous run's Calculators, just killed, stay as leaves for a
// few seconds (Mosaic holds a bulk of vanished windows before it concludes they closed), and only
// the ACTIVE workspace purges its dead leaves: visit a busy one, then wait it out.
for n in [wsA, wsB] {
    var attempt = 0
    while !(dump().workspaces[n]?.windows.isEmpty ?? true) {
        attempt += 1
        if attempt > 30 { print("workspace \(n) has windows: pass two empty workspaces"); restoreDesk(); exit(2) }
        // a switch is a reconcile; nothing else happens on an idle desk, and the misses must add up
        mosaic("workspace-\(n == wsA ? wsB : wsA)"); pause(0.25)
        mosaic("workspace-\(n)"); pause(0.25)
    }
}
restoreDesk()
baselineViolations = Set(dump().violations)
if !baselineViolations.isEmpty {
    print("  \(baselineViolations.count) invariant violation(s) already there, not counted: \(baselineViolations.sorted().joined(separator: "; "))")
}
let before = calculatorPids()
signal(SIGINT) { _ in cleanup(); exit(130) }

for ws in [wsA, wsB] {
    mosaic("workspace-\(ws)")
    pause(0.6)
    for _ in 0..<windowsPerWorkspace {
        guard let pid = openCalculator(on: ws, known: before.union(testPids)) else {
            fail("setup: no Calculator window managed on ws\(ws) within 10 s", dump())
        }
        testPids.insert(pid)
    }
    pause(1)
    check(step: "setup ws\(ws)")
}
print("  \(testPids.count) test windows")

let actions: [(weight: Int, name: String, run: () -> Void)] = [
    (30, "switch", { mosaic("workspace-\(dump().workspaces[wsA]?.shown == true ? wsB : wsA)") }),
    (12, "next-tab", { mosaic("next-tab") }),
    (6, "prev-tab", { mosaic("prev-tab") }),
    (10, "toggle-tabbed", { mosaic("toggle-tabbed") }),
    (4, "toggle-stacked", { mosaic("toggle-stacked") }),
    (4, "toggle-split", { mosaic("toggle-split") }),
    (8, "focus", { mosaic(Bool.random() ? "focus-left" : "focus-right") }),
    (8, "move", { mosaic(Bool.random() ? "move-left" : "move-right") }),
    (4, "swap", { mosaic(Bool.random() ? "swap-left" : "swap-right") }),
    (8, "move-to-other", { mosaic("move-to-\(dump().workspaces[wsA]?.shown == true ? wsB : wsA)") }),
    (6, "close-and-open", {
        guard let pid = testPids.randomElement() else { return }
        kill(pid, SIGTERM); testPids.remove(pid)
        pause(1)
        let shown = dump().workspaces[wsA]?.shown == true ? wsA : wsB
        if let fresh = openCalculator(on: shown, known: before.union(testPids)) { testPids.insert(fresh) }
    }),
]
let total = actions.reduce(0) { $0 + $1.weight }

var counts: [String: Int] = [:]
for round in stride(from: 1, through: rounds, by: 1) {
    var pick = Int.random(in: 0..<total)
    let action = actions.first { pick -= $0.weight; return pick < 0 }!
    action.run()
    counts[action.name, default: 0] += 1
    print("  round \(round): \(action.name)")   // the sequence that led to a failure is the repro
    pause(round % 5 == 0 ? 1.5 : 0.7)   // the park writes are asynchronous and reconcile confirms at +0.3/+0.8 s
    check(step: "round \(round) \(action.name)")
}
print("OK: \(rounds) rounds — " + counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
cleanup()

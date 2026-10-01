import AppKit
import CMultitouch

/// `mosaic doctor` and the periodic self-check behind the menu-bar alert. Both answer one question
/// the dump never did: is Mosaic actually doing its job right now, and if not, which of the quiet
/// ways of failing is it in?
extension WindowManager {
    static let doctorPath = "/tmp/mosaic-doctor.txt"

    var managedWindowCount: Int {
        var n = 0
        for ws in spaces.values { ws.root?.forEachLeaf { if $0.window != nil { n += 1 } } }
        return n
    }

    /// The one failure a trusted-looking setup can still have: the grant does not APPLY to this
    /// binary (an ad-hoc build), so AX enumerates nothing while the desktop is full of windows.
    func accessibilityIssue() -> String? {
        if !Health.accessibilityTrusted() { return "Accessibility is not granted to this build" }
        let foreign = Health.foreignAppWindows(onScreenSnapshot(maxAge: 1))
        if managedWindowCount == 0, foreign >= 2 {
            return "Accessibility is not effective: \(foreign) app window(s) on screen, 0 managed — is the bundle signed with the stable identity?"
        }
        return nil
    }

    /// Run the self-check; publish a change of state to the menu bar, the log and status.json.
    func healthCheck() {
        let issue = accessibilityIssue()
        guard issue != healthIssue else { return }
        healthIssue = issue
        Log.event(issue.map { "health — \($0)" } ?? "health — recovered, \(managedWindowCount) window(s) managed")
        onHealthChanged?(issue)
        writeStatusFile(focused: activeSpaceID.map(Int.init))
    }

    func doctor() {
        let text = doctorReport()
        try? text.write(toFile: Self.doctorPath, atomically: true, encoding: .utf8)
        Log.event("doctor — \(text.components(separatedBy: "\n").last(where: { $0.hasPrefix("verdict") }) ?? "written")")
    }

    func doctorReport() -> String {
        var issues: [String] = []
        var out = ""
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        out += "=== Mosaic doctor — \(stamp.string(from: Date())) ===\n"

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let up = Int(ProcessInfo.processInfo.systemUptime - processStart)
        out += "bundle       \(Bundle.main.bundlePath)  v\(version)  pid \(ProcessInfo.processInfo.processIdentifier)  up \(up / 3600)h\(String(format: "%02d", up % 3600 / 60))\n"

        let authority = Health.signatureAuthority()
        out += "signature    \(authority)"
        if authority == "ad-hoc" || authority == "unsigned" {
            issues.append("signature is \(authority): the Accessibility grant does not apply — unlock the keychain and `make bundle`")
            out += "   ← the Accessibility grant does not apply to this build"
        }
        out += "\n"

        let trusted = Health.accessibilityTrusted()
        let foreign = Health.foreignAppWindows(onScreenSnapshot(maxAge: 1))
        let managed = managedWindowCount
        out += "accessibility  trusted: \(trusted ? "yes" : "NO") · managing \(managed) window(s), \(foreign) app window(s) on screen\n"
        if let issue = accessibilityIssue() { issues.append(issue) }

        let sr = Health.screenRecordingGranted()
        out += "screen rec.  \(sr ? "granted" : "not granted") (exposé previews\(Config.shared.exposeThumbnails ? "" : " — off in config"))\n"
        if !sr, Config.shared.exposeThumbnails { issues.append("Screen Recording not granted: exposé opens on schematic tiles") }

        out += "private API\n" + PrivateAPI.report() + "\n"
        for c in PrivateAPI.missingEssential { issues.append("missing essential symbol \(c.symbol)") }

        let live = spaces.keys.sorted().map { id -> String in
            var n = 0; spaces[id]?.root?.forEachLeaf { if $0.window != nil { n += 1 } }
            return "\(id):\(n)"
        }
        let shown = orderedDisplays().map { did in "mon\(did)→\(shownOnDisplay[did].map(String.init) ?? "-")" }
        let susp = suspendReasons.isEmpty ? "none" : suspendReasons.map { "\($0)" }.sorted().joined(separator: ",")
        out += "workspaces   \(spaces.count) live (\(live.joined(separator: " "))) · shown \(shown.joined(separator: " ")) · suspended: \(susp)\n"

        let violations = checkInvariants()
        out += "invariants   \(violations.isEmpty ? "OK" : "\(violations.count) violation(s)")\n"
        for v in violations { out += "  [\(v.code)] \(v.detail)\n"; issues.append("invariant \(v.code)") }

        let fm = FileManager.default
        let stateURL = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/mosaic/state.json")
        if let attrs = try? fm.attributesOfItem(atPath: stateURL.path), let mod = attrs[.modificationDate] as? Date {
            let age = Int(Date().timeIntervalSince(mod))
            out += "state.json   saved \(age / 60) min ago"
            let prev = stateURL.appendingPathExtension("prev")
            if let p = try? fm.attributesOfItem(atPath: prev.path), let pm = p[.modificationDate] as? Date {
                out += " · backup \(Int(Date().timeIntervalSince(pm)) / 3600) h ago"
            }
            out += "\n"
        } else {
            out += "state.json   none yet\n"
        }
        out += "log          ~/.config/mosaic/mosaic.log · timing \(Perf.enabled ? "ON (~/.config/mosaic/timings.log)" : "off")\n"
        if Config.shared.trackpadGestures { out += "multitouch   \(cmt_device_count()) device(s)\n" }
        if let crash = Health.lastCrash() { out += "last crash   \(crash)\n" }

        out += issues.isEmpty ? "verdict      HEALTHY\n"
                              : "verdict      \(issues.count) ISSUE(S)\n" + issues.map { "  • \($0)\n" }.joined()
        return out
    }
}

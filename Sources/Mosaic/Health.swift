import AppKit
import Security

/// The facts a health report is made of — each one something that failed SILENTLY once.
///
/// A signature that fell back to ad-hoc left Mosaic running with an Accessibility grant that no
/// longer applied: every AX enumeration came back empty and it managed zero windows for ten minutes
/// without a word (2026-10-01). A SIGSEGV at wake left the desktop without a window manager until
/// morning. Nothing here is new information to the system; it is just never put in one place.
enum Health {
    /// The common name of the certificate the running bundle is signed with, "ad-hoc" when the
    /// signature carries no certificate, "unsigned"/"unknown" otherwise. Presence of the stable
    /// identity is what keeps the Accessibility grant across rebuilds.
    static func signatureAuthority() -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return "unknown" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "unsigned" }
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certs.first,
           let name = SecCertificateCopySubjectSummary(first) as String? {
            return name
        }
        return "ad-hoc"
    }

    static func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    /// Screen Recording, which the exposé previews need. Preflight only — never prompts.
    static func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() }

    /// On-screen windows that belong to ordinary, un-hidden apps other than us and are big enough to
    /// be real windows. Compared with the managed count, this is the only test that tells an
    /// Accessibility grant that APPLIES from one that merely exists.
    static func foreignAppWindows(_ snapshot: [(id: CGWindowID, pid: pid_t, bounds: CGRect)]) -> Int {
        let mine = ProcessInfo.processInfo.processIdentifier
        var policy: [pid_t: Bool] = [:]
        func regular(_ pid: pid_t) -> Bool {
            if let known = policy[pid] { return known }
            let app = NSRunningApplication(processIdentifier: pid)
            let ok = app?.activationPolicy == .regular && app?.isHidden == false
            policy[pid] = ok
            return ok
        }
        return snapshot.filter { $0.pid != mine && $0.bounds.width >= 200 && $0.bounds.height >= 200 && regular($0.pid) }.count
    }

    /// Whether a launch agent exists for us and whether THIS process is the one it runs.
    /// "running under launchd (KeepAlive)" is the only answer that survives a crash.
    static func launchAgentStatus() -> String {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/fr.rgouttiere.mosaic.plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return "not installed (make agent)" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/fr.rgouttiere.mosaic"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return "installed, launchctl unavailable" }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { return "installed but NOT loaded (make agent)" }
        let me = ProcessInfo.processInfo.processIdentifier
        if out.contains("pid = \(me)\n") || out.contains("pid = \(me) ") { return "running under launchd (KeepAlive)" }
        return "loaded, but this instance was started by hand — a crash would not be recovered (make restart)"
    }

    /// The newest crash report of ours: when, what, which file. nil when there is none.
    static func lastCrash() -> String? { newestCrashReport()?.summary }

    /// At start: a crash report of ours newer than the previous start means the previous run ended
    /// in a crash — said once, in the log, where the next morning's question gets asked. The stamp
    /// file's mtime is the previous start; it is refreshed after the check.
    static func noteCrashSinceLastStart() {
        let fm = FileManager.default
        let stamp = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/mosaic/.last-start")
        let previous = (try? fm.attributesOfItem(atPath: stamp.path))?[.modificationDate] as? Date
        defer { try? Data().write(to: stamp) }
        guard let previous, let crash = newestCrashReport(), crash.date > previous else { return }
        Log.event("previous run ended in a crash: \(crash.summary)")
    }

    static func newestCrashReport() -> (date: Date, summary: String)? {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        func modified(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        let mine = files.filter { $0.lastPathComponent.hasPrefix("Mosaic-") && $0.pathExtension == "ips" }
        guard let newest = mine.max(by: { modified($0) < modified($1) }) else { return nil }
        var when = newest.lastPathComponent, what = ""
        if let text = try? String(contentsOf: newest, encoding: .utf8) {
            let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if let hdr = (try? JSONSerialization.jsonObject(with: Data(parts[0].utf8))) as? [String: Any],
               let ts = hdr["timestamp"] as? String { when = ts }
            if parts.count > 1, let body = (try? JSONSerialization.jsonObject(with: Data(parts[1].utf8))) as? [String: Any],
               let ex = body["exception"] as? [String: Any] {
                what = " \(ex["type"] ?? "") \(ex["signal"] ?? "")"
            }
        }
        return (modified(newest), "\(when)\(what) — \(newest.lastPathComponent)")
    }
}

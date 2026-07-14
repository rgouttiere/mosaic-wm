import Foundation

/// Lightweight, opt-in timing. Zero cost when disabled.
///
/// Enable with `MOSAIC_TIMING=1` in the environment, or by creating the file
/// `~/.config/mosaic/.timing`, then relaunch Mosaic. While enabled, a summary of the
/// hot paths (count / total / avg / max ms) is appended to `~/.config/mosaic/timings.log`
/// every few seconds of activity. Read it with `tail -f ~/.config/mosaic/timings.log`.
enum Perf {
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["MOSAIC_TIMING"] != nil { return true }
        let flag = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mosaic/.timing")
        return FileManager.default.fileExists(atPath: flag.path)
    }()

    private struct Stat { var count = 0; var total = 0.0; var maxMs = 0.0 }
    private static var stats: [String: Stat] = [:]
    private static var windowStart = DispatchTime.now()
    private static let dumpEvery = 5.0   // seconds between summaries

    /// Record the elapsed time of a labelled span. Call as:
    ///   let t = DispatchTime.now(); defer { Perf.record("label", since: t) }
    static func record(_ label: String, since t0: DispatchTime) {
        guard enabled else { return }
        if stats.isEmpty { windowStart = .now() }   // align the window with its first event
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000
        var s = stats[label] ?? Stat()
        s.count += 1; s.total += ms; s.maxMs = Swift.max(s.maxMs, ms)
        stats[label] = s
    }

    /// Count an event (e.g. number of AX calls) without timing it.
    static func count(_ label: String, _ n: Int = 1) {
        guard enabled else { return }
        if stats.isEmpty { windowStart = .now() }
        var s = stats[label] ?? Stat()
        s.count += n
        stats[label] = s
    }

    /// Flush a summary if the window elapsed; cheap to call often (e.g. from a timer).
    static func dumpIfDue() {
        guard enabled, !stats.isEmpty else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- windowStart.uptimeNanoseconds) / 1_000_000_000
        guard elapsed >= dumpEvery else { return }
        dump(window: elapsed)
        stats.removeAll()
        windowStart = .now()
    }

    private static func dump(window: Double) {
        let lines = stats.sorted { $0.value.total > $1.value.total }.map { label, s -> String in
            String(format: "  %-22@ n=%-4d total=%8.1fms avg=%6.2fms max=%7.1fms",
                   label as NSString, s.count, s.total,
                   s.total / Double(Swift.max(s.count, 1)), s.maxMs)
        }
        let text = ([String(format: "[timings — %.0fs window]", window)] + lines).joined(separator: "\n")
        NSLog("Mosaic %@", text)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mosaic/timings.log")
        guard let data = (text + "\n\n").data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}

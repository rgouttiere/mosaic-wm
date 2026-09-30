import Foundation

/// Always-on, bounded event log for the handful of structural decisions nobody can reconstruct
/// after the fact: a leaf removed from the tree, a wake sequence, a recover.
///
/// `NSLog` alone does not do this job. Measured on this machine: over a three-minute window the
/// bundle-launched app produced 710 lines in the unified log and not one of them was ours, and a
/// deliberately triggered config reload logged nothing either. Every diagnostic already in the
/// code is therefore invisible in the only situation it exists for — which is why each of these
/// incidents has had to be reconstructed from the layout that survived instead of from what
/// happened. This writes where we can actually read it.
///
/// Unlike `Perf` (opt-in, sampled, about cost), this is always on and about *causes*. It stays
/// cheap by only being called on real events — never per render, never per window.
///
/// The tail also lives in memory (`recent`) so `dump-layout` can print the decisions that led to
/// the layout it shows: a dump taken *after* something went wrong is only useful next to the
/// events that preceded it, and nobody thinks to open the log file at that moment.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mosaic/mosaic.log")
    private static let maxBytes = 512 * 1024   // one rotation kept; a week of events fits easily
    private static var ring = EventRing(capacity: 200)
    private static let ringLock = NSLock()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Record one event. Also goes to `NSLog` so a terminal-run build still shows it.
    static func event(_ message: String) {
        NSLog("Mosaic: %@", message)
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        ringLock.lock(); ring.append(String(line.dropLast())); ringLock.unlock()
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(data)
        } else {
            try? data.write(to: url)
        }
    }

    /// The last `n` events, oldest first, timestamps included.
    static func recent(_ n: Int) -> [String] {
        ringLock.lock(); defer { ringLock.unlock() }
        return ring.tail(n)
    }
}

/// Fixed-capacity FIFO of lines; pure so the trimming is testable without touching the log file.
struct EventRing {
    let capacity: Int
    private(set) var lines: [String] = []

    init(capacity: Int) { self.capacity = max(1, capacity) }

    mutating func append(_ line: String) {
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    func tail(_ n: Int) -> [String] { Array(lines.suffix(max(0, n))) }
}

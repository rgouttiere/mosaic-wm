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
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mosaic/mosaic.log")
    private static let maxBytes = 512 * 1024   // one rotation kept; a week of events fits easily

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Record one event. Also goes to `NSLog` so a terminal-run build still shows it.
    static func event(_ message: String) {
        NSLog("Mosaic: %@", message)
        let line = "\(stamp.string(from: Date()))  \(message)\n"
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
}

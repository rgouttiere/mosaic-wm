import Foundation
import Darwin

/// A flight recorder for the minute after a wake, written straight to disk with plain `write`
/// calls — the data sits in the kernel the moment the call returns, so it survives a SIGKILL.
/// Mosaic died at five wakes (2026-10-04…06) with no crash report and no signal our own handler
/// could catch, and the event log stopped at "wake step 1/3" each time. This file says where:
/// every accessibility call made during the window (before it starts — the last line is the one
/// that never returned), and a watchdog line whenever the main thread stops answering.
///
/// `~/.config/mosaic/wake-trace.log`, truncated at each wake. At the next start, if the previous
/// run did not exit cleanly, its last lines are copied into the event log.
enum WakeTrace {
    static let path = NSHomeDirectory() + "/.config/mosaic/wake-trace.log"
    private static var fd: Int32 = -1
    private static var until: UInt64 = 0          // mach-continuous deadline, 0 = off
    private static let lock = NSLock()
    private static var watchdog: DispatchSourceTimer?
    private static var lastMainTick: UInt64 = 0   // atomic enough for a heartbeat (word-sized)

    static var active: Bool { until != 0 && DispatchTime.now().uptimeNanoseconds < until }

    /// Start (or restart) recording for `seconds`.
    static func begin(_ why: String, seconds: Double = 60) {
        lock.lock()
        if fd >= 0 { close(fd) }
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o644)
        until = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1e9)
        lock.unlock()
        mark("begin — \(why)")
        startWatchdog()
    }

    static func mark(_ s: @autoclosure () -> String) {
        guard active else { return }
        let line = Self.stamp() + " " + s() + "\n"
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }

    private static func stamp() -> String {
        var tv = timeval(); gettimeofday(&tv, nil)
        var tmv = tm(); var t = time_t(tv.tv_sec); localtime_r(&t, &tmv)
        let thread = pthread_main_np() != 0 ? "main" : "bg"
        return String(format: "%02d:%02d:%02d.%03d %@", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, Int(tv.tv_usec / 1000), thread)
    }

    /// Off the main thread: every 250 ms ask main to tick; note it when main has not ticked for
    /// 400 ms or more (once per stall, with its length so far).
    private static func startWatchdog() {
        watchdog?.cancel()
        lastMainTick = DispatchTime.now().uptimeNanoseconds
        var reported = false
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler {
            guard active else { watchdog?.cancel(); watchdog = nil; return }
            let now = DispatchTime.now().uptimeNanoseconds
            let stalled = Double(now &- lastMainTick) / 1e6
            if stalled >= 400 {
                if !reported || Int(stalled) % 1000 < 250 { mark("watchdog — main thread silent for \(Int(stalled)) ms") }
                reported = true
            } else {
                reported = false
            }
            DispatchQueue.main.async { lastMainTick = DispatchTime.now().uptimeNanoseconds }
        }
        t.resume()
        watchdog = t
    }

    /// At launch, after an unclean exit: the tail of the previous run's trace, for the event log.
    static func previousTail(lines n: Int = 14) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else { return nil }
        let lines = text.split(separator: "\n")
        return lines.suffix(n).joined(separator: "\n")
    }
}

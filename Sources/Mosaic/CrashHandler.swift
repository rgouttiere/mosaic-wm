import Foundation
import Darwin

/// Our own crash report, because macOS stops writing them. ReportCrash throttles a process that
/// crashed repeatedly, and after the loop of 2026-10-03 not one of the wake-time deaths of 10/04
/// left a report — four deaths, zero stacks. So on a fatal signal we write the crashing thread's
/// backtrace ourselves, with the async-signal-safe primitives only (no allocation, no Swift
/// runtime calls beyond what `backtrace` needs), then re-raise so the default action still runs.
/// The next start logs the top frames (`Health.noteCrashSinceLastStart`).
enum CrashHandler {
    static let path = NSHomeDirectory() + "/.config/mosaic/crash-latest.txt"
    private static var cPath: UnsafeMutablePointer<CChar>?

    static func install() {
        cPath = strdup(path)
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE] {
            signal(sig, handler)
        }
    }

    private static let handler: @convention(c) (Int32) -> Void = { sig in
        if let p = CrashHandler.cPath {
            let fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 {
                var head: [CChar] = Array("signal \(sig)\n".utf8CString)
                _ = head.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
                let n = backtrace(&frames, 128)
                backtrace_symbols_fd(&frames, n, fd)
                close(fd)
            }
        }
        signal(sig, SIG_DFL)
        raise(sig)
    }
}

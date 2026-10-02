import Foundation

/// The CLI's channel to the running app: a Unix socket at `~/.config/mosaic/mosaic.sock`.
///
/// `mosaic <verb>` connects, writes one line, and reads the answer until EOF — first line the exit
/// status, then the body. Before this the CLI posted a distributed notification and heard nothing
/// back: `dump-layout` and `doctor` wrote files to go and read, `query` read a status file that was
/// only as fresh as the last emit, and an unknown action vanished without a word.
///
/// The listening socket is watched on the main queue; each client is served on a background queue
/// (reads and writes with timeouts), and only the handler itself hops to main — a slow or stuck
/// client can never stall the window manager.
final class CommandServer {
    static let shared = CommandServer()
    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mosaic/mosaic.sock").path
    }

    /// Runs on the main queue: the request line → (exit status, reply body).
    var handle: ((String) -> (status: Int32, text: String))?
    private(set) var isListening = false
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    func start() {
        let path = Self.socketPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { Log.event("command socket — socket() failed: \(errno)"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = Self.fill(&addr, with: path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = ok && withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        } == 0
        guard bound, listen(fd, 8) == 0 else {
            Log.event("command socket — bind/listen failed at \(path): \(errno)")
            close(fd); fd = -1; return
        }
        chmod(path, 0o600)   // yours alone; the same trust model as the config file
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptClient() }
        src.resume()
        source = src
        isListening = true
    }

    func stop() {
        source?.cancel(); source = nil
        if fd >= 0 { close(fd); fd = -1 }
        unlink(Self.socketPath)
        isListening = false
    }

    private func acceptClient() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        tv.tv_sec = 3
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { close(client) }
            var buf = [UInt8](repeating: 0, count: 4096)
            var request = ""
            while request.firstIndex(of: "\n") == nil {
                let n = read(client, &buf, buf.count)
                guard n > 0 else { break }
                request += String(decoding: buf[0..<n], as: UTF8.self)
                if request.utf8.count > 4096 { break }
            }
            let line = request.split(separator: "\n", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            var reply: (status: Int32, text: String) = (1, "no handler\n")
            DispatchQueue.main.sync { [weak self] in
                if let self, let handle = self.handle { reply = handle(line) }
            }
            let body = reply.text.hasSuffix("\n") || reply.text.isEmpty ? reply.text : reply.text + "\n"
            Self.writeAll(client, Array("\(reply.status)\n\(body)".utf8))
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return }
            offset += n
        }
    }

    /// Copy `path` into `sun_path`; false when it does not fit (104 bytes on Darwin).
    static func fill(_ addr: inout sockaddr_un, with path: String) -> Bool {
        let bytes = Array(path.utf8)
        return withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
            guard bytes.count < buf.count else { return false }
            buf.baseAddress!.copyMemory(from: bytes, byteCount: bytes.count)
            buf[bytes.count] = 0
            return true
        }
    }
}

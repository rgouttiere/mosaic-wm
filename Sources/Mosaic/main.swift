import AppKit

/// CLI mode: `mosaic <verb>` talks to the running app over its Unix socket (`CommandServer`): one
/// line out, the answer back — first line the exit status, then the body. `--list` prints the
/// actions; `query` falls back to the status file when no Mosaic is running to ask.
let cliArgs = Array(CommandLine.arguments.dropFirst())

/// Send `line` to the running app; nil when there is no app to talk to.
func askApp(_ line: String) -> (status: Int32, text: String)? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    guard CommandServer.fill(&addr, with: CommandServer.socketPath) else { return nil }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    } == 0
    guard connected else { return nil }
    var tv = timeval(tv_sec: 5, tv_usec: 0)   // doctor shells out to launchctl; a dump can be long
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let request = Array((line + "\n").utf8)
    guard request.withUnsafeBufferPointer({ write(fd, $0.baseAddress, $0.count) }) == request.count else { return nil }
    shutdown(fd, SHUT_WR)
    var reply = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { break }
        reply.append(contentsOf: buf[0..<n])
    }
    let text = String(decoding: reply, as: UTF8.self)
    guard let nl = text.firstIndex(of: "\n"), let status = Int32(text[..<nl]) else { return nil }
    return (status, String(text[text.index(after: nl)...]))
}

if let verb = cliArgs.first {
    #if DEBUG
    if verb == "--self-test" { exit(SelfTest.run()) }   // in-module unit tests (debug builds only)
    #endif
    if verb == "--dump-config" {   // every effective value (honours MOSAIC_CONFIG)
        Config.shared.load()
        print(Config.shared.dumpEffective())
        exit(0)
    }
    if ["--list", "list", "-h", "--help", "help"].contains(verb) {
        Config.shared.load()
        print("Mosaic — usage: mosaic <action> | mosaic query [focused|workspaces|active] | mosaic doctor | mosaic dump-layout\n\nActions:")
        for key in Config.shared.keybindings.keys.sorted() { print("  \(key)") }
        print("  reload-config\n  dump-layout\n  doctor")
        exit(0)
    }
    if let answer = askApp(cliArgs.joined(separator: " ")) {
        if answer.status == 0 { print(answer.text, terminator: "") }
        else { FileHandle.standardError.write(Data(("mosaic: " + answer.text).utf8)) }
        exit(answer.status)
    }
    // No app answering. `query` can still read the last published state; anything else cannot run.
    if verb == "query" {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mosaic/status.json")
        guard let data = try? Data(contentsOf: url) else { print("{}"); exit(0) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch cliArgs.dropFirst().first {
        case "focused", "workspace":
            print((obj?["focused"] as? Int).map(String.init) ?? "")
        case "workspaces":
            print(((obj?["workspaces"] as? [Int]) ?? []).map(String.init).joined(separator: " "))
        case "active":   // workspaces currently visible on any monitor
            let mons = (obj?["monitors"] as? [[String: Any]]) ?? []
            print(mons.compactMap { $0["workspace"] as? Int }.map(String.init).joined(separator: " "))
        default:
            FileHandle.standardOutput.write(data)   // full JSON
        }
        exit(0)
    }
    FileHandle.standardError.write(Data("mosaic: Mosaic is not running (no command socket at \(CommandServer.socketPath))\n".utf8))
    exit(1)
}

let agentLabel = "fr.rgouttiere.mosaic"
func otherInstance() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: agentLabel)
        .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
}

// Started by hand while a launch agent is installed for THIS bundle → hand over to launchd. A Quit
// from the menu followed by a manual relaunch (Spotlight, Finder) otherwise runs outside the agent:
// no KeepAlive, and the next `make restart` lands on an instance launchd does not own — deploys
// stopped landing for twenty minutes that way (2026-10-03). launchd names its child after the job
// (XPC_SERVICE_NAME = the label); LaunchServices names a manual launch "application.<bundle>.<n>".
// Debug builds run from the build tree are not the agent's program, so they are left alone.
let agentPlist = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist").path
if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != agentLabel,
   let plist = NSDictionary(contentsOfFile: agentPlist),
   let program = (plist["ProgramArguments"] as? [String])?.first, program == Bundle.main.executablePath,
   otherInstance() == nil {
    Log.event("started by hand while the launch agent is installed — handing over to launchd")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["kickstart", "gui/\(getuid())/\(agentLabel)"]
    try? p.run()
    exit(0)
}

// One Mosaic at a time. With the launch agent keeping one alive, a second instance (a second
// agent, a stray `open`) would fight the first over every window. The newcomer waits up to two
// seconds for the other to go — it may be the hand-over above, exiting as we start — then leaves
// with status 0, so launchd does not treat its exit as a crash to recover from.
if var other = otherInstance() {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, let still = otherInstance() { other = still; usleep(100_000) }
    if let still = otherInstance() {
        Log.event("another Mosaic is already running (pid \(still.processIdentifier)) — this one exits")
        exit(0)
    }
    _ = other
}

// Normal app mode. Our own crash report first (macOS has stopped writing them for us), then the
// user config (writes a default on first run).
CrashHandler.install()
Config.shared.load()

// Mosaic runs as a menu-bar "accessory" app: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()

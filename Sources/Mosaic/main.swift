import AppKit

/// Distributed-notification channel the CLI uses to talk to the running app.
let mosaicCommandNotification = "fr.rgouttiere.mosaic.command"

// CLI mode: `Mosaic <action>` (e.g. `mosaic focus-left`, `mosaic workspace-3`, `mosaic swap-up`)
// sends the command to the already-running Mosaic and exits. `--list` prints the actions.
let cliArgs = Array(CommandLine.arguments.dropFirst())
if let verb = cliArgs.first {
    if ["--list", "list", "-h", "--help", "help"].contains(verb) {
        Config.shared.load()
        print("Mosaic — usage: mosaic <action>\n\nActions:")
        for key in Config.shared.keybindings.keys.sorted() { print("  \(key)") }
        print("  reload-config\n  dump-layout")
        exit(0)
    }
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name(mosaicCommandNotification),
        object: nil, userInfo: ["command": verb], deliverImmediately: true)
    exit(0)
}

// Normal app mode: load user config first (writes a default on first run).
Config.shared.load()

// Mosaic runs as a menu-bar "accessory" app: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()

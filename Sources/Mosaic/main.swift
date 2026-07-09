import AppKit

// Load user config first (writes a default ~/.config/mosaic/config.json on first run).
Config.shared.load()

// Mosaic runs as a menu-bar "accessory" app: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()

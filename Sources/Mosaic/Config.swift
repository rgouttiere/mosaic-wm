import AppKit
import Carbon.HIToolbox

/// User configuration loaded from ~/.config/mosaic/config.json. A default file is
/// written on first launch. Edit it and restart Mosaic to apply changes.
final class Config {
    static let shared = Config()

    /// Problems found during the last `load()` (bad JSON, unknown keys, out-of-range
    /// values). Empty = clean. The app surfaces these to the user after loading.
    var loadIssues: [String] = []

    var gap: CGFloat = 0          // inner gap between tiles
    var outerGap: CGFloat = 0     // margin between the tiling area and the screen edges
    var tabBarHeight: CGFloat = 22
    var defaultMode: String = "columns"   // columns | grouped | tabbed
    /// Warp the mouse cursor to a workspace when switching to it by shortcut (keeps
    /// the mouse-follows model consistent → fewer stale-desktop refresh glitches).
    var warpMouseOnSwitch: Bool = true
    static let defaultFloatingApps: Set<String> = [
        "skitch", "shottr", "cleanshot", "cleanshot x", "monosnap", "snagit",
    ]
    var floatingApps: Set<String> = Config.defaultFloatingApps
    var rules: [AppRule] = []
    var showWorkspaceHUD: Bool = true
    /// center | top | bottom | top-left | top-right | bottom-left | bottom-right
    var hudPosition: String = "top-right"
    /// Shell command run on every workspace change (exec-and-forget), with the env var
    /// MOSAIC_WORKSPACE set to the focused number (empty if none). For sketchybar & co,
    /// e.g. "sketchybar --trigger mosaic_workspace_change". Empty = disabled.
    var onWorkspaceChange: String = ""

    // Window styling.
    var borderEnabled: Bool = true
    var borderColor: String = "accent"   // "accent" or hex like "#FF9500"
    var borderWidth: Double = 1
    var borderCornerRadius: Double = 18
    var activeOpacity: Double = 1.0       // 1.0 = opaque
    var inactiveOpacity: Double = 0.5     // < 1.0 dims unfocused windows

    // Tab bar styling.
    var tabCornerRadius: Double = 10
    var tabBarColor: String = "#1E1E1E"
    var tabActiveColor: String = "accent"
    var tabTextColor: String = "#B0B0B0"
    var tabActiveTextColor: String = "#FFFFFF"
    var tabFontSize: Double = 14
    var tabBarOpacity: Double = 0.97
    var tabActivePadding: Double = 0     // inset of the active-tab pill

    // Drop target highlight (during tab drag & drop).
    var dropHighlightEnabled: Bool = true
    var dropHighlightColor: String = "accent"

    var borderNSColor: NSColor { Config.color(from: borderColor) }

    static func color(from string: String) -> NSColor {
        if string.lowercased() == "accent" { return .controlAccentColor }
        let hex = string.hasPrefix("#") ? String(string.dropFirst()) : string
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return .controlAccentColor }
        return NSColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var keybindings: [String: String] = Config.defaultKeybindings

    static var defaultKeybindings: [String: String] {
        var b = baseKeybindings
        for n in 1...9 {
            b["workspace-\(n)"] = "cmd alt \(n)"          // switch to workspace N
            b["move-to-\(n)"] = "cmd alt shift \(n)"      // move focused window to workspace N
            b["assign-\(n)"] = "cmd alt ctrl \(n)"        // assign current desktop to number N
        }
        return b
    }

    private static let baseKeybindings: [String: String] = [
        "tile": "cmd alt t",
        "cycle-mode": "cmd alt w",
        "manage-all": "cmd alt a",
        "focus-left": "cmd alt left",
        "focus-right": "cmd alt right",
        "focus-up": "cmd alt up",
        "focus-down": "cmd alt down",
        "focus-group-left": "cmd alt ctrl left",
        "focus-group-right": "cmd alt ctrl right",
        "focus-group-up": "cmd alt ctrl up",
        "focus-group-down": "cmd alt ctrl down",
        "move-left": "cmd alt shift left",
        "move-right": "cmd alt shift right",
        "move-up": "cmd alt shift up",
        "move-down": "cmd alt shift down",
        "swap-left": "cmd ctrl left",
        "swap-right": "cmd ctrl right",
        "swap-up": "cmd ctrl up",
        "swap-down": "cmd ctrl down",
        "resize-left": "ctrl alt left",
        "resize-right": "ctrl alt right",
        "resize-up": "ctrl alt up",
        "resize-down": "ctrl alt down",
        "group": "cmd alt g",
        "group-stacked": "cmd alt shift g",
        "preselect-vertical": "cmd alt v",
        "preselect-horizontal": "cmd alt h",
        "toggle-split": "cmd alt e",
        "toggle-tabbed": "cmd alt s",
        "toggle-stacked": "cmd alt shift s",
        "equalize": "cmd alt equal",
        "rotate": "cmd alt r",
        "reset-desktop": "cmd alt shift r",
        "clear": "cmd alt shift c",
        "next-tab": "cmd alt period",
        "prev-tab": "cmd alt comma",
        "float": "cmd alt f",
        "zoom": "cmd alt return",
        "scratchpad-toggle": "cmd alt minus",
        "scratchpad-send": "cmd alt shift minus",
        "move-screen-next": "cmd alt ]",
        "move-screen-prev": "cmd alt [",
        "move-desktop-next": "cmd alt shift ]",
        "move-desktop-prev": "cmd alt shift [",
    ]

    private struct File: Decodable {
        var gap: Double?
        var outerGap: Double?
        var tabBarHeight: Double?
        var warpMouseOnSwitch: Bool?
        var defaultMode: String?
        var floatingApps: [String]?
        var rules: [AppRule]?
        var showWorkspaceHUD: Bool?
        var hudPosition: String?
        var onWorkspaceChange: String?
        var borderEnabled: Bool?
        var borderColor: String?
        var borderWidth: Double?
        var borderCornerRadius: Double?
        var activeOpacity: Double?
        var inactiveOpacity: Double?
        var tabCornerRadius: Double?
        var tabBarColor: String?
        var tabActiveColor: String?
        var tabTextColor: String?
        var tabActiveTextColor: String?
        var tabFontSize: Double?
        var tabBarOpacity: Double?
        var tabActivePadding: Double?
        var dropHighlightEnabled: Bool?
        var dropHighlightColor: String?
        var keybindings: [String: String]?
    }

    var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mosaic/config.json")
    }

    func load() {
        // Reset to defaults first so a reload also reflects keys/bindings removed from
        // the file (not just overrides).
        gap = 0
        outerGap = 0
        tabBarHeight = 22
        defaultMode = "columns"
        warpMouseOnSwitch = true
        floatingApps = Config.defaultFloatingApps
        rules = []
        showWorkspaceHUD = true
        hudPosition = "top-right"
        onWorkspaceChange = ""
        borderEnabled = true
        borderColor = "accent"
        borderWidth = 1
        borderCornerRadius = 18
        activeOpacity = 1.0
        inactiveOpacity = 0.5
        tabCornerRadius = 10
        tabBarColor = "#1E1E1E"
        tabActiveColor = "accent"
        tabTextColor = "#B0B0B0"
        tabActiveTextColor = "#FFFFFF"
        tabFontSize = 14
        tabBarOpacity = 0.97
        tabActivePadding = 0
        dropHighlightEnabled = true
        dropHighlightColor = "accent"
        keybindings = Config.defaultKeybindings

        loadIssues = []
        guard let data = try? Data(contentsOf: configURL) else {
            writeDefault()
            return
        }
        // 1) Well-formed JSON object?
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            loadIssues.append("JSON invalide (un objet { … } est attendu). Valeurs par défaut appliquées.")
            NSLog("Mosaic: config.json is invalid JSON — using defaults")
            return
        }
        // 2) Unknown top-level keys (typos). Keys starting with "_" are comment markers.
        let known: Set<String> = [
            "gap", "outerGap", "tabBarHeight", "warpMouseOnSwitch", "defaultMode",
            "floatingApps", "rules", "showWorkspaceHUD", "hudPosition", "onWorkspaceChange", "borderEnabled",
            "borderColor", "borderWidth", "borderCornerRadius", "activeOpacity",
            "inactiveOpacity", "tabCornerRadius", "tabBarColor", "tabActiveColor",
            "tabTextColor", "tabActiveTextColor", "tabFontSize", "tabBarOpacity",
            "tabActivePadding", "dropHighlightEnabled", "dropHighlightColor", "keybindings",
        ]
        for key in raw.keys.sorted() where !key.hasPrefix("_") && !known.contains(key) {
            loadIssues.append("clé inconnue « \(key) » ignorée (faute de frappe ?)")
        }
        // 3) Typed decode — on failure, report which field and keep defaults.
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            loadIssues.append("valeur invalide : \(describeDecodingError(error))")
            NSLog("Mosaic: config.json has an invalid value — using defaults (\(error))")
            return
        }
        if let g = file.gap { gap = CGFloat(g) }
        if let o = file.outerGap { outerGap = CGFloat(o) }
        if let t = file.tabBarHeight { tabBarHeight = CGFloat(t) }
        if let w = file.warpMouseOnSwitch { warpMouseOnSwitch = w }
        if let m = file.defaultMode { defaultMode = m }
        if let f = file.floatingApps { floatingApps = Set(f.map { $0.lowercased() }) }
        if let r = file.rules { rules = r }
        if let h = file.showWorkspaceHUD { showWorkspaceHUD = h }
        if let p = file.hudPosition { hudPosition = p }
        if let o = file.onWorkspaceChange { onWorkspaceChange = o }
        if let b = file.borderEnabled { borderEnabled = b }
        if let c = file.borderColor { borderColor = c }
        if let w = file.borderWidth { borderWidth = w }
        if let r = file.borderCornerRadius { borderCornerRadius = r }
        if let a = file.activeOpacity { activeOpacity = a }
        if let i = file.inactiveOpacity { inactiveOpacity = i }
        if let r = file.tabCornerRadius { tabCornerRadius = r }
        if let c = file.tabBarColor { tabBarColor = c }
        if let c = file.tabActiveColor { tabActiveColor = c }
        if let c = file.tabTextColor { tabTextColor = c }
        if let c = file.tabActiveTextColor { tabActiveTextColor = c }
        if let s = file.tabFontSize { tabFontSize = s }
        if let o = file.tabBarOpacity { tabBarOpacity = o }
        if let p = file.tabActivePadding { tabActivePadding = p }
        if let d = file.dropHighlightEnabled { dropHighlightEnabled = d }
        if let c = file.dropHighlightColor { dropHighlightColor = c }
        // Merge so a user can override only the bindings they care about.
        if let k = file.keybindings { keybindings.merge(k) { _, new in new } }

        // 4) Semantic checks (values parsed fine but are out of range / unknown).
        let validModes: Set<String> = ["columns", "grouped", "tabbed"]
        if !validModes.contains(defaultMode.lowercased()) {
            loadIssues.append("defaultMode « \(defaultMode) » inconnu (attendu : columns, grouped, tabbed)")
        }
        let validPos: Set<String> = ["center", "top", "bottom", "top-left", "top-right",
                                     "bottom-left", "bottom-right", "topleft", "topright",
                                     "bottomleft", "bottomright"]
        if !validPos.contains(hudPosition.lowercased()) {
            loadIssues.append("hudPosition « \(hudPosition) » inconnu")
        }
        for (name, value) in ["activeOpacity": activeOpacity, "inactiveOpacity": inactiveOpacity]
        where !(0...1).contains(value) {
            loadIssues.append("\(name) = \(value) hors plage (0.0 à 1.0)")
        }
        for rule in rules where rule.workspace != nil && !(1...9).contains(rule.workspace!) {
            loadIssues.append("rule « \(rule.app) » : workspace \(rule.workspace!) hors plage (1 à 9)")
        }

        // Duplicate keybindings: two actions on the same combo → only one wins (undefined).
        var comboOwner: [String: String] = [:]
        for (action, combo) in keybindings {
            let norm = combo.lowercased().split { " +-".contains($0) }.sorted().joined(separator: "+")
            if let other = comboOwner[norm] {
                loadIssues.append("raccourci en double « \(combo) » : « \(action) » et « \(other) »")
            } else {
                comboOwner[norm] = action
            }
        }

        NSLog("Mosaic: loaded config from \(configURL.path) — \(loadIssues.count) issue(s)")
    }

    /// Turn a Swift `DecodingError` into a short, user-readable field reference.
    private func describeDecodingError(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map(\.stringValue).joined(separator: ".")
            return p.isEmpty ? "(racine)" : p
        }
        switch e {
        case .typeMismatch(let t, let c): return "mauvais type pour « \(path(c)) » (attendu \(t))"
        case .valueNotFound(_, let c):    return "valeur nulle pour « \(path(c)) »"
        case .keyNotFound(let k, _):      return "clé requise absente « \(k.stringValue) »"
        case .dataCorrupted(let c):       return c.debugDescription
        @unknown default:                 return "\(e)"
        }
    }

    private func writeDefault() {
        let dict: [String: Any] = [
            "gap": Double(gap),
            "outerGap": Double(outerGap),
            "warpMouseOnSwitch": warpMouseOnSwitch,
            "tabBarHeight": Double(tabBarHeight),
            "defaultMode": defaultMode,
            "floatingApps": Array(floatingApps).sorted(),
            "rules": [["app": "skitch", "float": true]],   // example; see README for fields
            "showWorkspaceHUD": showWorkspaceHUD,
            "hudPosition": hudPosition,
            "borderEnabled": borderEnabled,
            "borderColor": borderColor,
            "borderWidth": borderWidth,
            "borderCornerRadius": borderCornerRadius,
            "activeOpacity": activeOpacity,
            "inactiveOpacity": inactiveOpacity,
            "tabCornerRadius": tabCornerRadius,
            "tabBarColor": tabBarColor,
            "tabActiveColor": tabActiveColor,
            "tabTextColor": tabTextColor,
            "tabActiveTextColor": tabActiveTextColor,
            "tabFontSize": tabFontSize,
            "tabBarOpacity": tabBarOpacity,
            "tabActivePadding": tabActivePadding,
            "dropHighlightEnabled": dropHighlightEnabled,
            "dropHighlightColor": dropHighlightColor,
            "keybindings": keybindings,
        ]
        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL)
            NSLog("Mosaic: wrote default config to \(configURL.path)")
        } catch {
            NSLog("Mosaic: could not write default config: \(error)")
        }
    }
}

/// Renders a config combo string ("cmd alt t") into menu symbols ("⌘⌥T").
enum MenuFormat {
    /// "  (⌘⌥T)" for a full combo, or "" if the binding is missing/keyless.
    static func combo(_ string: String?) -> String {
        guard let string, case let (mods, key) = parse(string), !key.isEmpty else { return "" }
        return "  (\(mods)\(key))"
    }

    /// Just the modifier symbols ("⌘⌥"), for directional "… + arrows" entries.
    static func modifiers(_ string: String?) -> String {
        guard let string else { return "" }
        return parse(string).mods
    }

    private static func parse(_ string: String) -> (mods: String, key: String) {
        let tokens = string.lowercased().split { "+- ".contains($0) }.map(String.init)
        var ctrl = false, opt = false, shift = false, cmd = false
        var key = ""
        for token in tokens {
            switch token {
            case "cmd", "command", "super", "meta": cmd = true
            case "alt", "opt", "option":            opt = true
            case "ctrl", "control":                 ctrl = true
            case "shift":                           shift = true
            default:                                key = keySymbol(token)
            }
        }
        var mods = ""
        if ctrl { mods += "⌃" }
        if opt { mods += "⌥" }
        if shift { mods += "⇧" }
        if cmd { mods += "⌘" }
        return (mods, key)
    }

    private static func keySymbol(_ key: String) -> String {
        switch key {
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "space": return "Space"
        case "return", "enter": return "↩"
        case "tab": return "⇥"
        case "escape", "esc": return "⎋"
        case "delete": return "⌫"
        case "minus": return "-"
        case "equal": return "="
        default: return key.uppercased()
        }
    }
}

/// Parses combos like "cmd alt t" / "ctrl+alt+left" into Carbon (keyCode, modifiers).
enum KeyCombo {
    static func parse(_ string: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let tokens = string.lowercased().split { "+- ".contains($0) }.map(String.init)
        var modifiers: UInt32 = 0
        var keyCode: UInt32?
        for token in tokens {
            switch token {
            case "cmd", "command", "super", "meta": modifiers |= UInt32(cmdKey)
            case "alt", "opt", "option":            modifiers |= UInt32(optionKey)
            case "ctrl", "control":                 modifiers |= UInt32(controlKey)
            case "shift":                           modifiers |= UInt32(shiftKey)
            default:
                if let code = keyCodes[token] { keyCode = UInt32(code) }
            }
        }
        guard let keyCode else { return nil }
        return (keyCode, modifiers)
    }

    private static let keyCodes: [String: Int] = {
        var map: [String: Int] = [
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "return": kVK_Return, "enter": kVK_Return, "space": kVK_Space, "tab": kVK_Tab,
            "escape": kVK_Escape, "esc": kVK_Escape, "delete": kVK_Delete,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            "leftbracket": kVK_ANSI_LeftBracket, "rightbracket": kVK_ANSI_RightBracket,
            "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period,
            "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal,
        ]
        let letters: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z,
        ]
        let digits: [String: Int] = [
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        map.merge(letters) { a, _ in a }
        map.merge(digits) { a, _ in a }
        return map
    }()
}

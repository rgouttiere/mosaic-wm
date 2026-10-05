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
    var externalBarTop: CGFloat = 0  // px reserved at the top for an external bar (e.g. sketchybar)
    var notchBarOffset: CGFloat = 40 // extra top reserve on a SOLE notched built-in display, where an external bar is shifted below the notch (must match sketchybar's y_offset there); 0 = off
    var workspaceNames: [Int: String] = [:]  // optional i3-style labels: workspace number → name
    var workspaceMonitors: [Int: Int] = [:]  // optional override: workspace number → monitor index (1-based, left→right)
    var focusPulseWidth: CGFloat = 5   // px added to the focus border at the peak of the switch pulse (0 = off)
    var focusPulseDuration: Double = 0.38   // seconds the focus pulse takes to fade out
    var focusGlowRadius: Double = 6    // px of soft accent halo around the focused window (0 = off, just the crisp border)
    var focusGlowFade: Bool = true     // fade the focus border in on focus change (respects the system Reduce Motion setting)
    var exposeDim: Double = 0.7   // exposé backdrop opacity (0 = transparent, 1 = opaque black)
    var exposeSwitch = ""   // hold-combo to drive the exposé (e.g. "cmd tab"); empty = disabled
    var exposeAllScreens = false   // mirror the exposé/cmd-tab on every screen at once
    var exposeThumbnails = true    // show live window previews in the exposé (needs Screen Recording); off = schematic tiles
    // Feature toggles (all on by default).
    var focusSync = true        // adopt keyboard/cmd-tab focus changes into the tabs
    var robustCrossAppTabs = false   // opt-in: after a workspace switch, re-assert the selected tab of
                                     // cross-app tabbed groups on OTHER shown monitors (macOS z-orders by
                                     // app globally, so activating one monitor's app can bury another's
                                     // selected tab). Costs a burst of app activations; can't satisfy two
                                     // shown groups needing different apps of the same pair on top at once.
    var tabScrollCycle = true   // scroll over a tab bar to cycle its tabs
    var switcherFadeIn = true   // fade the quick-switcher popup in
    var tabBarHeight: CGFloat = 22
    var hideConfinedApps: Bool = false   // opt-in: park an app confined to one workspace by HIDING it — no sliver, but apps redraw on unhide (switch measured 2× slower) instead of moving its windows
    var stackStyle: String = "rows"   // how a stacked group draws its strip: "rows" (full-width rows on top) or "rail" (an icon rail on the left)
    var railWidth: CGFloat = 44       // rail: width of the strip, in points; cells are square
    var railIconSize: Double = 24     // rail: icon size for a single-window row (pairs shrink to fit)
    var railHoverPreview: Bool = true   // rail: hovering an icon shows a card with the window's preview + title
    var railIconStyle: String = "color"   // rail icons: "color" as the app ships them, or "tinted" (accent monochrome, the active row in colour)
    var defaultMode: String = "columns"   // columns | grouped | tabbed
    /// Warp the mouse cursor to a workspace when switching to it by shortcut (keeps
    /// the mouse-follows model consistent → fewer stale-desktop refresh glitches).
    var warpMouseOnSwitch: Bool = true
    var workspaceWrap: Bool = true   // cycle workspaces circularly (Ctrl+h/l, 3-finger swipe); false = stop at the ends
    var trackpadGestures: Bool = false   // opt-in: 3-finger horizontal swipe → workspace prev/next (raw MultitouchSupport)
    var dragModifier: String = "ctrl alt cmd"   // hold this chord + left-drag anywhere to move ANY window (tab=center, split=edge); "" = off
    var ejectNativeFullscreen: Bool = false  // v2: send a managed window that enters native full screen back to windowed (strict emulated)
    /// A screen showing a single window gets no gaps at all — margins exist to separate tiles,
    /// and there is nothing to separate. See `WindowManager.layoutRect`.
    var smartGaps: Bool = false
    var autoFloatDialogs: Bool = false       // v2: auto-float standard windows with no full-screen button (dialogs/palettes), except terminals
    /// Stand down on a monitor a window we don't manage has taken over — a game in borderless
    /// full screen. Geometric, so it needs no per-app list; see `coveredDisplays`.
    var yieldToFullscreenWindows: Bool = true
    static let defaultFloatingApps: Set<String> = [
        "skitch", "shottr", "cleanshot", "cleanshot x", "monosnap", "snagit",
        // Control surfaces: a panel you poke at, never a window you work in.
        "elgato stream deck", "com.elgato.streamdeck", "elgato wave link", "com.elgato.wavelink",
    ]
    /// Apps that must tile even though they look dialog-like to `autoFloatDialogs` — no native
    /// full-screen button, yet a window you work in. Terminals are the known population (the
    /// AeroSpace exception); this is a config key rather than a hardcoded set so an app that
    /// mis-declares itself can be named for what it is, instead of through a `float:false` rule
    /// whose name says nothing about why. Matched on app name OR bundle id, like `floatingApps`.
    /// Compiled title patterns, keyed by their source. `ruleFor` runs for every window a
    /// reconcile captures, so compiling on each call would put a regex build in a hot loop.
    /// Cleared whenever the config is re-read.
    private static var titleRegexCache: [String: NSRegularExpression?] = [:]

    static func titleMatches(_ pattern: String, _ title: String) -> Bool {
        let regex: NSRegularExpression?
        if let cached = titleRegexCache[pattern] {
            regex = cached
        } else {
            regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            titleRegexCache[pattern] = regex
            if regex == nil { NSLog("Mosaic: rule title is not a valid regex — \(pattern)") }
        }
        guard let regex else { return false }
        return regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    static let defaultAlwaysTileApps: Set<String> = [
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "com.googlecode.iterm2",
        "com.apple.terminal", "net.kovidgoyal.kitty", "dev.warp.warp-stable", "com.mitchellh.ghostty",
    ]
    var alwaysTileApps: Set<String> = Config.defaultAlwaysTileApps
    var floatingApps: Set<String> = Config.defaultFloatingApps
    /// Apps whose windows lock to a fixed video aspect (IINA, mpv…). Rather than let such a window
    /// overshoot its tile (freezing the column, since it refuses to shrink one axis), Mosaic sizes it
    /// to the largest aspect-correct box that fits the tile, centres it, and letterboxes the rest.
    static let defaultAspectFitApps: Set<String> = ["iina", "mpv"]
    var aspectFitApps: Set<String> = Config.defaultAspectFitApps
    var rules: [AppRule] = []
    var showWorkspaceHUD: Bool = true
    var notchHud: Bool = false   // dynamic-island HUD under the notch on workspace switch (replaces the top-right HUD)
    /// center | top | bottom | top-left | top-right | bottom-left | bottom-right
    var hudPosition: String = "top-right"
    /// Shell command run on every workspace change (exec-and-forget), with the env var
    /// MOSAIC_WORKSPACE set to the focused number (empty if none). For sketchybar & co,
    /// e.g. "sketchybar --trigger mosaic_workspace_change". Empty = disabled.
    var onWorkspaceChange: String = ""

    // Window styling.
    var borderEnabled: Bool = true
    var borderInactive: Bool = false   // also draw a dim accent border on non-focused tiled windows
    var dimInactiveMonitors: Bool = false   // darken tile borders + tab strips on the monitor(s) without keyboard focus (a veil, never alpha)
    var inactiveBorderOpacity: Double = 0.42   // opacity of the permanent border on non-focused windows (dimmed further off the focused monitor)
    var inactiveMonitorDim: Double = 0.6   // dimInactiveMonitors: fraction of brightness the non-focused monitors keep (1 = none); strips get a black veil of 1-dim, borders a darker accent
    /// The single accent used across the whole UI. "accent"/"system" = the macOS system accent;
    /// or a hex like "#a6e3a1". Every field set to "accent" (border, tabs, drop) resolves through
    /// this, and the overlays read `Palette.accent`, so one value re-themes everything.
    var accentColor: String = "accent"
    var letterboxStyle: String = "black"   // fill for letterboxed-tile gaps: "none", "black" (plain) or "matrix" (static rune rain)
    var borderColor: String = "accent"   // "accent" or hex like "#FF9500"
    var borderWidth: Double = 1
    var borderCornerRadius: Double = 18
    var activeOpacity: Double = 1.0       // 1.0 = opaque
    var inactiveOpacity: Double = 1.0     // < 1.0 shades unfocused tiles (TileScrims); 1.0 = off

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
    /// The resolved accent (system or configured hex) — never recurses through the "accent" keyword.
    var accentNSColor: NSColor {
        let s = accentColor.lowercased()
        if s == "accent" || s == "system" { return .controlAccentColor }
        return Config.hexColor(accentColor) ?? .controlAccentColor
    }

    static func color(from string: String) -> NSColor {
        if string.lowercased() == "accent" { return Config.shared.accentNSColor }
        return hexColor(string) ?? .controlAccentColor
    }

    /// Parse "#RRGGBB" (or "RRGGBB"); nil if malformed.
    static func hexColor(_ string: String) -> NSColor? {
        let hex = string.hasPrefix("#") ? String(string.dropFirst()) : string
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
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
        "switcher": "cmd alt p",   // fuzzy quick-switcher (workspaces + windows)
        "hints": "cmd alt j",      // vimium-style window hints (type a letter to focus)
        "expose": "cmd alt o",     // schematic workspace overview
        "pip-here": "cmd alt shift p",   // bring the picture-in-picture under the mouse pointer
        "grab": "cmd alt m",       // keyboard grab: pick up focused window, hjkl to aim, ⏎ tab / ⇧hjkl split
        "unassign": "cmd alt ctrl 0",   // unset the current desktop's workspace number
        "workspace-back": "cmd alt b",   // bounce to the previous workspace (i3 back-and-forth)
        "workspace-next": "ctrl right",  // cycle this monitor's workspaces (needs macOS "Move a space" off)
        "workspace-prev": "ctrl left",   // ← see README: disable Mission Control's Ctrl+←/→ first
        "recover": "cmd alt shift return",   // panic heal: un-minimize + re-assert every workspace
        "undo": "cmd alt z",                 // put the workspace back the way it was before the last edit
        "scratchpad-toggle": "cmd alt minus",
        "scratchpad-send": "cmd alt shift minus",
        "move-screen-next": "cmd alt ]",
        "move-screen-prev": "cmd alt [",
        "move-desktop-next": "cmd alt shift ]",
        "move-desktop-prev": "cmd alt shift [",
    ]

    /// `MOSAIC_CONFIG=/path/to/file.json` points at another file — for testing a config without
    /// touching the real one, and for the equivalence checks that guard this parser.
    var configURL: URL {
        if let p = ProcessInfo.processInfo.environment["MOSAIC_CONFIG"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mosaic/config.json")
    }

    /// Every effective value, one `key: value` line per stored property, sorted and rendered
    /// deterministically (sets and dictionaries sorted, rules as sorted-key JSON). `mosaic
    /// --dump-config` prints it: "what config is actually in effect" without guessing, and a byte-
    /// for-byte way to prove a parser change kept every value.
    func dumpEffective() -> String {
        func render(_ v: Any) -> String {
            switch v {
            case let b as Bool: return b ? "true" : "false"
            case let i as Int: return String(i)
            case let d as Double: return String(d)
            case let f as CGFloat: return String(Double(f))
            case let s as String: return "\"" + s + "\""
            case let set as Set<String>: return "[" + set.sorted().joined(separator: ", ") + "]"
            case let arr as [String]: return "[" + arr.joined(separator: ", ") + "]"
            case let d as [String: String]: return "{" + d.keys.sorted().map { "\($0)=\(d[$0]!)" }.joined(separator: ", ") + "}"
            case let d as [Int: String]: return "{" + d.keys.sorted().map { "\($0)=\(d[$0]!)" }.joined(separator: ", ") + "}"
            case let d as [Int: Int]: return "{" + d.keys.sorted().map { "\($0)=\(d[$0]!)" }.joined(separator: ", ") + "}"
            case let rules as [AppRule]:
                let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
                return (try? enc.encode(rules)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
            default: return String(describing: v)
            }
        }
        var lines: [String] = []
        for child in Mirror(reflecting: self).children {
            guard let label = child.label else { continue }
            if label == "loadIssues" { continue }   // rendered last, sorted, so ordering can't mask an equal set
            lines.append("\(label): \(render(child.value))")
        }
        lines.sort()
        lines.append("loadIssues: " + loadIssues.sorted().map { "\n  - " + $0 }.joined())
        return lines.joined(separator: "\n")
    }

    /// Parse the `workspaceNames` map (string keys → labels) into number-keyed labels.
    /// `Int(_:)` is not injective ("1"/"01"/"+1" all → 1), so distinct JSON keys can collapse;
    /// a collision (or a key outside 1…9) is dropped and surfaced as an issue rather than
    /// trapping in `Dictionary(uniqueKeysWithValues:)`. Keys are walked in sorted order so
    /// "last write wins" names the SAME winner on every launch — a Dictionary's order is
    /// randomized per process, and the equivalence check that guards this parser caught the
    /// same file producing a different label from one run to the next. Pure + static → testable.
    static func parseWorkspaceNames(_ wn: [String: String]) -> (names: [Int: String], issues: [String]) {
        var names: [Int: String] = [:]
        var issues: [String] = []
        for key in wn.keys.sorted() { let value = wn[key]!
            guard let n = Int(key) else { continue }
            guard (1...9).contains(n) else {
                issues.append("workspaceNames: “\(key)” is outside 1…9 — ignored")
                continue
            }
            if names[n] != nil {
                issues.append("workspaceNames: duplicate key for workspace \(n) — keeping “\(value)”")
            }
            names[n] = value   // last write wins on a collision
        }
        return (names, issues)
    }

    /// Parse the `workspaceMonitors` map (workspace number → 1-based monitor index). Same
    /// lenient rules as `parseWorkspaceNames`: keys outside 1…9 or collisions are dropped and
    /// surfaced. A non-positive monitor index is dropped too. Pure + static → unit-testable.
    static func parseWorkspaceMonitors(_ wm: [String: Int]) -> (map: [Int: Int], issues: [String]) {
        var map: [Int: Int] = [:]
        var issues: [String] = []
        for key in wm.keys.sorted() { let value = wm[key]!   // sorted: same collision winner every launch
            guard let n = Int(key) else { continue }
            guard (1...9).contains(n) else {
                issues.append("workspaceMonitors: “\(key)” is outside 1…9 — ignored"); continue
            }
            guard value >= 1 else {
                issues.append("workspaceMonitors: monitor index \(value) for workspace \(n) must be ≥ 1 — ignored"); continue
            }
            if map[n] != nil {
                issues.append("workspaceMonitors: duplicate key for workspace \(n) — keeping \(value)")
            }
            map[n] = value
        }
        return (map, issues)
    }

    // MARK: - Options table

    /// One config option, complete: how to read it from the raw JSON object, how to reset it, and
    /// (optionally) how it appears in the default file written on first run. Adding a key used to
    /// take EIGHT edits — the property, a mirror struct, a coding key, a lenient decode line, a
    /// reset line, the known-key set, an apply line, the serializer — and forgetting any one of
    /// them failed silently: a key never reset survived a hot-reload that removed it, one never
    /// listed as known was reported to the user as a typo. Now it takes the property plus one
    /// entry below, and `known`/reset/apply/serialize are all derived from that entry.
    private struct Option {
        let key: String
        let reset: (Config) -> Void
        /// Apply a value that IS present in the file. Empty = applied; otherwise why it was
        /// refused — the default is kept, so one bad value never sinks the rest of the config.
        let apply: (Config, Any) -> [String]
        let dump: ((Config) -> Any)?
    }

    // JSONSerialization hands back an NSNumber for both `true` and `1`, and Swift happily bridges
    // either to Bool or Double. Telling them apart is what keeps `"gap": true` and `"focusSync": 1`
    // refused as wrong-typed, exactly as the strict Decodable path did: a JSON boolean is a
    // CFBoolean, a JSON number is not.
    private static func boolean(_ v: Any) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    private static func number(_ v: Any) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
    private static func wrongType(_ key: String) -> [String] { ["invalid value for “\(key)” — ignored, default kept"] }

    private static func bool(_ key: String, _ kp: ReferenceWritableKeyPath<Config, Bool>, _ def: Bool, dump: Bool = false) -> Option {
        Option(key: key, reset: { $0[keyPath: kp] = def },
               apply: { c, v in guard let b = boolean(v) else { return wrongType(key) }; c[keyPath: kp] = b; return [] },
               dump: dump ? { $0[keyPath: kp] } : nil)
    }
    private static func double(_ key: String, _ kp: ReferenceWritableKeyPath<Config, Double>, _ def: Double, dump: Bool = false) -> Option {
        Option(key: key, reset: { $0[keyPath: kp] = def },
               apply: { c, v in guard let d = number(v) else { return wrongType(key) }; c[keyPath: kp] = d; return [] },
               dump: dump ? { $0[keyPath: kp] } : nil)
    }
    private static func points(_ key: String, _ kp: ReferenceWritableKeyPath<Config, CGFloat>, _ def: CGFloat, dump: Bool = false) -> Option {
        Option(key: key, reset: { $0[keyPath: kp] = def },
               apply: { c, v in guard let d = number(v) else { return wrongType(key) }; c[keyPath: kp] = CGFloat(d); return [] },
               dump: dump ? { Double($0[keyPath: kp]) } : nil)
    }
    private static func string(_ key: String, _ kp: ReferenceWritableKeyPath<Config, String>, _ def: String, dump: Bool = false) -> Option {
        Option(key: key, reset: { $0[keyPath: kp] = def },
               apply: { c, v in guard let s = v as? String else { return wrongType(key) }; c[keyPath: kp] = s; return [] },
               dump: dump ? { $0[keyPath: kp] } : nil)
    }
    /// A list of app names / bundle ids, matched case-insensitively → stored lowercased.
    private static func apps(_ key: String, _ kp: ReferenceWritableKeyPath<Config, Set<String>>, _ def: Set<String>, dump: Bool = false) -> Option {
        Option(key: key, reset: { $0[keyPath: kp] = def },
               apply: { c, v in
                   guard let strs = v as? [String] else { return wrongType(key) }
                   c[keyPath: kp] = Set(strs.map { $0.lowercased() }); return [] },
               dump: dump ? { Array($0[keyPath: kp]).sorted() } : nil)
    }

    private static let options: [Option] = [
        points("gap", \.gap, 0, dump: true),
        points("outerGap", \.outerGap, 0, dump: true),
        points("externalBarTop", \.externalBarTop, 0, dump: true),
        points("notchBarOffset", \.notchBarOffset, 40),
        Option(key: "workspaceNames", reset: { $0.workspaceNames = [:] }, apply: { c, v in
            guard let d = v as? [String: String] else { return wrongType("workspaceNames") }
            let p = parseWorkspaceNames(d); c.workspaceNames = p.names; return p.issues
        }, dump: nil),
        Option(key: "workspaceMonitors", reset: { $0.workspaceMonitors = [:] }, apply: { c, v in
            // Strict integers: a boolean or a fraction is a wrong-typed field, not a monitor index.
            guard let raw = v as? [String: Any] else { return wrongType("workspaceMonitors") }
            var d: [String: Int] = [:]
            for (k, x) in raw {
                guard let n = number(x), n == n.rounded() else { return wrongType("workspaceMonitors") }
                d[k] = Int(n)
            }
            let p = parseWorkspaceMonitors(d); c.workspaceMonitors = p.map; return p.issues
        }, dump: nil),
        points("focusPulseWidth", \.focusPulseWidth, 5),
        double("focusPulseDuration", \.focusPulseDuration, 0.38),
        double("focusGlowRadius", \.focusGlowRadius, 6),
        bool("focusGlowFade", \.focusGlowFade, true),
        double("exposeDim", \.exposeDim, 0.7),
        string("exposeSwitch", \.exposeSwitch, ""),
        bool("exposeAllScreens", \.exposeAllScreens, false),
        bool("exposeThumbnails", \.exposeThumbnails, true),
        bool("focusSync", \.focusSync, true),
        bool("robustCrossAppTabs", \.robustCrossAppTabs, false),
        bool("tabScrollCycle", \.tabScrollCycle, true),
        bool("switcherFadeIn", \.switcherFadeIn, true),
        points("tabBarHeight", \.tabBarHeight, 22, dump: true),
        bool("hideConfinedApps", \.hideConfinedApps, false, dump: true),
        string("stackStyle", \.stackStyle, "rows", dump: true),
        points("railWidth", \.railWidth, 44, dump: true),
        double("railIconSize", \.railIconSize, 24, dump: true),
        string("railIconStyle", \.railIconStyle, "color", dump: true),
        bool("railHoverPreview", \.railHoverPreview, true, dump: true),
        bool("warpMouseOnSwitch", \.warpMouseOnSwitch, true, dump: true),
        bool("workspaceWrap", \.workspaceWrap, true, dump: true),
        bool("trackpadGestures", \.trackpadGestures, false, dump: true),
        string("dragModifier", \.dragModifier, "ctrl alt cmd", dump: true),
        bool("ejectNativeFullscreen", \.ejectNativeFullscreen, false),
        bool("smartGaps", \.smartGaps, false),
        bool("autoFloatDialogs", \.autoFloatDialogs, false),
        bool("yieldToFullscreenWindows", \.yieldToFullscreenWindows, true),
        string("defaultMode", \.defaultMode, "columns", dump: true),
        apps("floatingApps", \.floatingApps, Config.defaultFloatingApps, dump: true),
        apps("aspectFitApps", \.aspectFitApps, Config.defaultAspectFitApps, dump: true),
        apps("alwaysTileApps", \.alwaysTileApps, Config.defaultAlwaysTileApps, dump: true),
        Option(key: "rules", reset: { $0.rules = [] }, apply: { c, v in
            // Structured → the Codable struct decodes it as a unit; a malformed list loses only
            // this field, not the whole file.
            guard let arr = v as? [Any], let data = try? JSONSerialization.data(withJSONObject: arr),
                  let rules = try? JSONDecoder().decode([AppRule].self, from: data) else { return wrongType("rules") }
            c.rules = rules; return []
        }, dump: { _ in [["app": "skitch", "float": true]] }),   // example; see README for fields
        bool("showWorkspaceHUD", \.showWorkspaceHUD, true, dump: true),
        bool("notchHud", \.notchHud, false),
        string("hudPosition", \.hudPosition, "top-right", dump: true),
        string("onWorkspaceChange", \.onWorkspaceChange, ""),
        bool("borderEnabled", \.borderEnabled, true, dump: true),
        bool("borderInactive", \.borderInactive, false),
        bool("dimInactiveMonitors", \.dimInactiveMonitors, false),
        string("accentColor", \.accentColor, "accent", dump: true),
        string("letterboxStyle", \.letterboxStyle, "black"),
        string("borderColor", \.borderColor, "accent", dump: true),
        double("borderWidth", \.borderWidth, 1, dump: true),
        double("inactiveBorderOpacity", \.inactiveBorderOpacity, 0.42, dump: true),
        double("inactiveMonitorDim", \.inactiveMonitorDim, 0.6, dump: true),
        double("borderCornerRadius", \.borderCornerRadius, 18, dump: true),
        double("activeOpacity", \.activeOpacity, 1.0, dump: true),
        double("inactiveOpacity", \.inactiveOpacity, 1.0, dump: true),
        double("tabCornerRadius", \.tabCornerRadius, 10, dump: true),
        string("tabBarColor", \.tabBarColor, "#1E1E1E", dump: true),
        string("tabActiveColor", \.tabActiveColor, "accent", dump: true),
        string("tabTextColor", \.tabTextColor, "#B0B0B0", dump: true),
        string("tabActiveTextColor", \.tabActiveTextColor, "#FFFFFF", dump: true),
        double("tabFontSize", \.tabFontSize, 14, dump: true),
        double("tabBarOpacity", \.tabBarOpacity, 0.97, dump: true),
        double("tabActivePadding", \.tabActivePadding, 0, dump: true),
        bool("dropHighlightEnabled", \.dropHighlightEnabled, true, dump: true),
        string("dropHighlightColor", \.dropHighlightColor, "accent", dump: true),
        Option(key: "keybindings", reset: { $0.keybindings = Config.defaultKeybindings }, apply: { c, v in
            // Merge, so a user overrides only the bindings they care about.
            guard let k = v as? [String: String] else { return wrongType("keybindings") }
            c.keybindings.merge(k) { _, new in new }; return []
        }, dump: { $0.keybindings }),
    ]

    private func reset() {
        Config.titleRegexCache.removeAll()   // patterns may have been edited or dropped
        for o in Config.options { o.reset(self) }
    }

    func load() {
        guard let data = try? Data(contentsOf: configURL) else {
            reset(); loadIssues = []
            writeDefault()
            return
        }
        load(data: data)
        NSLog("Mosaic: loaded config from \(configURL.path) — \(loadIssues.count) issue(s)")
    }

    /// The whole parse, from bytes. Resets to defaults first so a reload also reflects keys and
    /// bindings REMOVED from the file, not just overrides. Internal so the self-tests can run it on
    /// a scratch instance without touching `shared`.
    func load(data: Data) {
        reset()
        loadIssues = []
        // 1) Well-formed JSON object?
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            loadIssues.append("Invalid JSON (expected an object { … }). Defaults applied.")
            NSLog("Mosaic: config.json is invalid JSON — using defaults")
            return
        }
        // 2) Unknown top-level keys (typos). Keys starting with "_" are comment markers.
        let known = Set(Config.options.map(\.key))
        for key in raw.keys.sorted() where !key.hasPrefix("_") && !known.contains(key) {
            loadIssues.append("unknown key “\(key)” ignored (typo?)")
        }
        // 3) Apply each option INDEPENDENTLY: one wrong-typed value loses only that field and keeps
        //    its default, never the whole config. A JSON null counts as absent.
        for o in Config.options {
            guard let v = raw[o.key], !(v is NSNull) else { continue }
            let issues = o.apply(self, v)
            loadIssues.append(contentsOf: issues)
            if !issues.isEmpty { NSLog("Mosaic: config.json field “\(o.key)” — \(issues.joined(separator: "; "))") }
        }

        // 4) Semantic checks (values parsed fine but are out of range / unknown).
        let validModes: Set<String> = ["columns", "grouped", "tabbed", "master-stack", "masterstack", "master"]
        if !validModes.contains(defaultMode.lowercased()) {
            loadIssues.append("unknown defaultMode “\(defaultMode)” (expected: columns, grouped, tabbed, master-stack)")
        }
        let validPos: Set<String> = ["center", "top", "bottom", "top-left", "top-right",
                                     "bottom-left", "bottom-right", "topleft", "topright",
                                     "bottomleft", "bottomright"]
        if !validPos.contains(hudPosition.lowercased()) {
            loadIssues.append("unknown hudPosition “\(hudPosition)”")
        }
        if !["rows", "rail"].contains(stackStyle.lowercased()) {
            loadIssues.append("unknown stackStyle “\(stackStyle)” (rows | rail) — using rows")
            stackStyle = "rows"
        }
        if !["color", "tinted"].contains(railIconStyle.lowercased()) {
            loadIssues.append("unknown railIconStyle “\(railIconStyle)” (color | tinted) — using color")
            railIconStyle = "color"
        }
        for (name, value) in ["activeOpacity": activeOpacity, "inactiveOpacity": inactiveOpacity]
        where !(0...1).contains(value) {
            loadIssues.append("\(name) = \(value) out of range (0.0 to 1.0)")
        }
        if !["none", "off", "black", "matrix"].contains(letterboxStyle.lowercased()) {
            loadIssues.append("unknown letterboxStyle “\(letterboxStyle)” (none | black | matrix) — using black")
            letterboxStyle = "black"
        }
        for rule in rules where rule.letterbox != nil && !["none", "off", "black", "matrix"].contains(rule.letterbox!.lowercased()) {
            loadIssues.append("rule “\(rule.app)”: letterbox “\(rule.letterbox!)” is not none | black | matrix — treated as black")
        }
        for rule in rules where rule.workspace != nil && !(1...9).contains(rule.workspace!) {
            loadIssues.append("rule “\(rule.app)”: workspace \(rule.workspace!) out of range (1 to 9)")
        }

        // Duplicate keybindings: two actions on the same combo → only one wins (undefined). Blank
        // combos are disabled bindings, not shortcuts, so several "" are fine — skip them. Walked
        // in key order so the pair reported is the same on every launch (a Dictionary's order isn't).
        var comboOwner: [String: String] = [:]
        for action in keybindings.keys.sorted() {
            // A value may list several combos (comma-separated) — check each on its own.
            for combo in keybindings[action]!.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !combo.isEmpty {
                let norm = combo.lowercased().split { " +-".contains($0) }.sorted().joined(separator: "+")
                if let other = comboOwner[norm], other != action {
                    loadIssues.append("duplicate shortcut “\(combo)”: “\(action)” and “\(other)”")
                } else {
                    comboOwner[norm] = action
                }
            }
        }
    }

    private func writeDefault() {
        var dict: [String: Any] = [:]
        for o in Config.options { if let d = o.dump { dict[o.key] = d(self) } }
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

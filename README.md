# Mosaic

A tiling **and tabbing** window manager for macOS, in the spirit of i3 — **no SIP disabling required**.

Its headline feature is the one thing most macOS tilers lack: **tab & stack containers that mix windows from different apps** in a single tile, with a real clickable tab/stack bar — and they nest with splits, i3-style.

> ⚠️ **Status: alpha, personal project, best-effort.** It works and I use it daily, but it's tuned to my setup, relies on private macOS APIs (see [Caveats](#caveats)), and comes with no support guarantees. Use at your own risk.

## Highlights

- **Tab & stack containers across apps** — merge any windows (Firefox + Terminal + Notes…) into one tile as tabs (horizontal bar) or a stack (vertical title list). Nest them inside splits.
- **i3-style layout tree** — split H/V, tabbed, stacked, arbitrarily nested; keyboard-driven focus / move / resize, plus mouse resize and tab drag & drop (including across groups and screens).
- **i3 preselect** — arm a split direction (`⌘⌥V`/`⌘⌥H`); the next window nests there.
- **Numbered workspaces** (1–9, assignable, unique across screens) — optionally **named** (i3-style); **per-app scratchpad**, **zoom/monocle**.
- **Quick-switcher** (`⌘⌥P`) — a ⌘-palette popup to fuzzy-jump to any workspace or window.
- **External-bar aware** — reserve a top strip for a bar like [sketchybar](https://github.com/FelixKratz/SketchyBar) (`externalBarTop`, notch-aware per screen) and publish workspace names + per-monitor placement for it to render.
- **Real macOS Spaces integration** (Mission Control & native gestures keep working).
- **Survives dock/undock & reboot** — layouts persist keyed by a stable per-monitor fingerprint.
- **Live JSON config** — modes, gaps, styling, per-app rules, keybindings; **auto-reloads on save** (no restart).
- **CLI** — every action is scriptable via `mosaic <action>` (e.g. `mosaic workspace-3`), sketchybar/automation-friendly.
- Keeps **SIP enabled**; runs as a menu-bar accessory app (**▦**).

## Why another one?

[yabai](https://github.com/koekeishiya/yabai) and [AeroSpace](https://github.com/nikitabobko/AeroSpace) are excellent — if you want a mature, maintained tiler, use those. Mosaic exists for one reason: **per-tile tab/stack containers mixing different apps**, the i3 "tabbed/stacked container" feel that neither really offers. If you miss that from Linux, this is for you.

## Requirements

- macOS 13 (Ventura) or later — developed on current macOS.
- Apple Silicon (arm64).
- Xcode command-line tools / Swift 6 toolchain to build.

## Install & run

```sh
make run      # build release, bundle Mosaic.app, launch it
```

Then grant **System Settings → Privacy & Security → Accessibility → Mosaic** and relaunch. A **▦** icon appears in the menu bar.

Quick debug build: `swift build && .build/debug/Mosaic`.

### Sharing a build (not notarized)

Mosaic isn't notarized (no Apple Developer ID), so Gatekeeper flags a downloaded build once:

```sh
make dist                                        # → Mosaic.zip (arm64, ad-hoc signed)
xattr -dr com.apple.quarantine /Applications/Mosaic.app   # clear the quarantine flag
```

(or right-click → Open → "Open Anyway"). Then grant Accessibility as above.

## Quick start

1. `⌘⌥T` — start tiling the current desktop.
2. `⌘⌥←/→/↑/↓` — move focus; `⌘⌥⇧+arrows` — move a window.
3. `⌘⌥G` — merge the focused window with its neighbor into **tabs**; `⌘⌥⇧G` — into a **stack**.
4. `⌘⌥E` toggle split H/V · `⌘⌥S` tabbed · `⌘⌥⇧S` stacked · `⌘⌥↩` zoom.
5. `⌘⌥V`/`⌘⌥H` — preselect a split for the next window.
6. `⌘⌥P` — quick-switcher: type to jump to a workspace or window.

**Full shortcut reference: [CHEATSHEET.md](CHEATSHEET.md).**

## Config

First launch writes `~/.config/mosaic/config.json`. Edit and save it — Mosaic **auto-reloads on save** (or **menu → "Reload config"**). Invalid config surfaces a warning instead of silently reverting.

Keys: `gap`, `outerGap`, `externalBarTop` (px reserved at the top for an external bar like sketchybar — per screen, notch-aware), `tabBarHeight`, `defaultMode` (`columns`/`grouped`/`tabbed`), `warpMouseOnSwitch`, `showWorkspaceHUD`, `hudPosition`; `workspaceNames` (i3-style labels, `{ "2": "web", "3": "code" }` — number stays the identity/keybinding key, the name is display-only); window styling (`borderEnabled`, `borderColor` `"accent"`|`"#RRGGBB"`, `borderWidth`, `borderCornerRadius`, `activeOpacity`/`inactiveOpacity`); tab styling (`tabBarColor`, `tabActiveColor`, `tabTextColor`, `tabActiveTextColor`, `tabCornerRadius`, `tabFontSize`, `tabBarOpacity`); `floatingApps` (names/bundle ids, lowercased); `keybindings` (action → combo, e.g. `"tile": "cmd alt t"`; only the ones you list override defaults).

Per-app auto-placement `rules`, applied as windows open:
```json
"rules": [
  { "app": "discord", "float": true },
  { "app": "slack",   "groupWith": "discord" },
  { "app": "spotify", "place": "column" },
  { "app": "mail",    "workspace": 4 }
]
```
`app` = case-insensitive substring of the app name or bundle id. `float` keeps it out of tiling; `groupWith` auto-tabs it with the named app; `place` = `column` | `tab` | (default: next to focus); `workspace` = send its windows to workspace N (must be assigned).

## Architecture

```
Sources/Mosaic/
  main.swift                 Accessory-app entry point
  AppDelegate.swift          Menu bar, hotkeys, Accessibility prompt, config-issue alerts
  Config.swift               JSON config load + validation + keybinding parsing
  Persistence.swift          On-disk layout model (state.json)
  Geometry.swift             Cocoa (bottom-left) <-> AX (top-left) coordinate flip
  Spaces.swift               Private SkyLight/CGS SPI: current Space, move window to Space
  Accessibility/AX.swift     Swift wrappers over the C AXUIElement API
  Hotkeys/HotkeyManager.swift  Global shortcuts via Carbon RegisterEventHotKey
  Window/
    ManagedWindow.swift      One controllable window (AX element + owning app)
    WindowManager.swift      The layout tree + all editing ops + reconcile/render
    WindowObserver.swift     AXObserver-driven live updates (create/close/title/launch)
  Layout/
    Container.swift          i3-style tree node: leaf | splitH | splitV | tabbed(+stacked)
  UI/
    TabBarWindow.swift / TabBarView.swift   Overlay tab/stack strip
    FocusIndicator / DropHighlight / WorkspaceHUD / ResizeHandle / TabDragGhost
```

The menu bar has a **"Debug: dump layout"** item that writes the live tree + visible bars to `/tmp/mosaic-dump.txt` — handy for bug reports.

## Caveats

- **Private APIs.** macOS exposes no public API to manage Spaces (desktops) or to map an AX element to a window id. Mosaic uses the same private SkyLight/CGS SPI every native-Spaces tiler relies on (`_AXUIElementGetWindow`, `CGS…` in `Spaces.swift`). These are historically stable but **can break on a major macOS release**. They're isolated in one file. (App Store distribution is therefore impossible; direct/notarized distribution is fine.)
- **Not notarized** — see the Gatekeeper note above.
- Apple's native Split View can't be extended — Mosaic recreates the experience on regions it owns.
- A window's own title bar still shows inside a tab/stack region.
- Apple Silicon only; alpha-quality; expect rough edges outside my own hardware/workflow.

## Contributing

Best-effort personal project — issues and PRs welcome but may go unanswered. If you report a layout bug, please attach the output of **menu → "Debug: dump layout"** and your macOS version.

## License

[MIT](LICENSE) © 2026 Raphael Gouttiere.

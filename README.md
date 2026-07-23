# Mosaic

A tiling **and tabbing** window manager for macOS, in the spirit of i3 — **no SIP disabling required**.

Its headline feature is the one thing most macOS tilers lack: **tab & stack containers that mix windows from different apps** in a single tile, with a real clickable tab/stack bar — and they nest with splits, i3-style.

> ⚠️ **Status: alpha, personal project, best-effort.** It works and I use it daily, but it's tuned to my setup, relies on private macOS APIs (see [Caveats](#caveats)), and comes with no support guarantees. Use at your own risk.

## Highlights

- **Tab & stack containers across apps** — merge any windows (Firefox + Terminal + Notes…) into one tile as tabs (horizontal bar) or a stack (vertical title list). Nest them inside splits.
- **i3-style layout tree** — split H/V, tabbed, stacked, arbitrarily nested; keyboard-driven focus / move / resize, plus mouse resize and drag & drop of tabs **and** stacked rows to reorder or detach them (including across groups and screens).
- **i3 preselect** — arm a split direction (`⌘⌥V`/`⌘⌥H`); the next window nests there.
- **Numbered workspaces** (1–9, assignable, unique across screens) — optionally **named** (i3-style); **per-app scratchpad**, **zoom/monocle**.
- **Quick-switcher / command palette** (`⌘⌥P`) — fuzzy-jump to any workspace or window (grouped, recency-ordered, with window counts + app icons), or flip with `←/→` to a **command palette** running any Mosaic action. `⌘⏎` moves the focused window to a workspace; `⌘⌥B` bounces to the previous workspace (i3 back-and-forth).
- **Window hints** (`⌘⌥J`) — Vimium-style: a letter appears on every visible window; type it to focus (works across screens). Keyboard-only, no arrows.
- **Schematic exposé** (`⌘⌥O`) — a Mission-Control-style overview drawn from the layout tree (no screenshots): every workspace of every screen at once, one column per screen, tiles laid out to scale with tab strips and app icons; fullscreen apps show by name. Navigate with arrows (2D) or `⇥`, `⏎` to jump. Optionally **rebind it onto `⌘Tab`** (`exposeSwitch`): hold the modifier to browse, `⇥` to cycle, release to commit — a schematic alt-tab. Remappable and off by default.
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

Every key is optional — omit one and its default applies. Sizes are in pixels, opacities are `0.0`–`1.0`, and colors are either `"accent"` (follows your macOS accent color) or a hex string like `"#1E1E1E"`.

**Layout & workspaces**

| Key | Default | What it does |
|---|---|---|
| `gap` | `0` | Space between tiles. |
| `outerGap` | `0` | Margin between the tiling area and the screen edges. |
| `defaultMode` | `"columns"` | How new windows are auto-placed: `columns`, `grouped` (by app), or `tabbed`. |
| `tabBarHeight` | `22` | Height of the tab/stack bar. |
| `warpMouseOnSwitch` | `true` | Move the mouse onto a workspace when you switch to it by shortcut (keeps the mouse-follows-focus model consistent). |
| `workspaceNames` | `{}` | i3-style labels, e.g. `{ "2": "web", "3": "code" }`. The number stays the identity/shortcut key; the name is display-only. |
| `externalBarTop` | `0` | Pixels reserved at the top for an external bar (e.g. sketchybar), per screen, notch-aware. `0` = none. |

**Window appearance**

| Key | Default | What it does |
|---|---|---|
| `borderEnabled` | `true` | Draw a border around the focused window. |
| `borderColor` | `"accent"` | Border color (`"accent"` or hex). |
| `borderWidth` | `1` | Border thickness. |
| `borderCornerRadius` | `18` | Border corner radius. |
| `activeOpacity` | `1.0` | Opacity of the focused window. |
| `inactiveOpacity` | `0.5` | Opacity of unfocused windows. `1.0` = no dimming. |

**Tab / stack bar appearance**

| Key | Default | What it does |
|---|---|---|
| `tabBarColor` | `"#1E1E1E"` | Bar background color. |
| `tabBarOpacity` | `0.97` | Bar opacity. |
| `tabCornerRadius` | `10` | Bar corner radius. |
| `tabFontSize` | `14` | Label font size. |
| `tabTextColor` | `"#B0B0B0"` | Inactive tab label color. |
| `tabActiveColor` | `"accent"` | Active tab pill color. |
| `tabActiveTextColor` | `"#FFFFFF"` | Active tab label color. |
| `tabActivePadding` | `0` | Inset of the active-tab pill. |

**Overlays & visual feedback**

| Key | Default | What it does |
|---|---|---|
| `showWorkspaceHUD` | `true` | Flash the workspace name when you switch. |
| `hudPosition` | `"top-right"` | Where the HUD appears: `center`, `top`, `bottom`, `top-left`, `top-right`, `bottom-left`, `bottom-right`. |
| `focusPulseWidth` | `5` | Pixels the focus border briefly swells on a workspace switch. `0` = off. |
| `focusPulseDuration` | `0.38` | Seconds the focus pulse takes to fade. |
| `dropHighlightEnabled` | `true` | Highlight the drop target while dragging a tab/row. |
| `dropHighlightColor` | `"accent"` | Drop-highlight color. |
| `exposeDim` | `0.7` | Exposé backdrop opacity. |

**Behavior & integration**

| Key | Default | What it does |
|---|---|---|
| `focusSync` | `true` | Adopt keyboard/⌘Tab focus changes back into the tabs, so the tab bar tracks whatever you focus. |
| `tabScrollCycle` | `true` | Scroll over a tab bar to cycle through its tabs. |
| `switcherFadeIn` | `true` | Fade the quick-switcher popup in. |
| `exposeSwitch` | `""` | Hold-combo that drives the exposé as a schematic alt-tab, e.g. `"cmd tab"`. `""` keeps the native ⌘Tab. |
| `onWorkspaceChange` | `""` | Shell command run on every workspace change (env `MOSAIC_WORKSPACE` = focused number). Point it at a sketchybar trigger; see [CHEATSHEET.md](CHEATSHEET.md#status-bar-sketchybar). `""` = off. |
| `floatingApps` | *(screenshot tools)* | App names or bundle ids (lowercased) that never tile — they always float. |
| `keybindings` | *(see below)* | Map an action to a shortcut, e.g. `"tile": "cmd alt t"`. Only the entries you list override the defaults. |

Per-app auto-placement `rules`, applied as windows open:
```json
"rules": [
  { "app": "discord", "float": true },
  { "app": "slack",   "groupWith": "discord" },
  { "app": "spotify", "place": "column" },
  { "app": "mail",    "workspace": 4 },
  { "app": "ferdium", "fullscreen": false }
]
```
`app` = case-insensitive substring of the app name or bundle id. `float` keeps it out of tiling; `groupWith` auto-tabs it with the named app; `place` = `column` | `tab` | (default: next to focus); `workspace` = send its windows to workspace N (must be assigned); `fullscreen` = force native full screen off (`false` → windowed, so it can tile) or on (`true`) — applied once when a window opens, or every time if you add `"fullscreenLock": true`.

### Turning features off

Every optional behavior can be switched off from the same config file — set the key and save:

| To turn off… | Set |
|---|---|
| Window border | `"borderEnabled": false` |
| Dimming of unfocused windows | `"inactiveOpacity": 1.0` |
| Focus pulse on workspace switch | `"focusPulseWidth": 0` |
| Workspace-name HUD | `"showWorkspaceHUD": false` |
| Drop-target highlight (while dragging tabs) | `"dropHighlightEnabled": false` |
| Focus sync into tabs | `"focusSync": false` |
| Scroll-to-cycle on tab bars | `"tabScrollCycle": false` |
| Quick-switcher fade-in | `"switcherFadeIn": false` |
| ⌘Tab exposé switcher | `"exposeSwitch": ""` (keeps native ⌘Tab) |
| External-bar top strip | `"externalBarTop": 0` |
| Status-bar hook (sketchybar) | `"onWorkspaceChange": ""` |

To free up a keyboard shortcut for another app, rebind that action to a combo you don't use (the action stays available via the menu and `mosaic <action>` CLI).

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

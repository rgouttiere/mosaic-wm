# Mosaic

A tiling + **tabbing** window manager for macOS, in the spirit of i3wm — built on the
Accessibility API, **no SIP disabling required**.

> Working name. The headline feature is the **tab system**: several windows, possibly
> from *different* applications, share one screen region; only one is shown at a time,
> switched via a Mosaic-drawn tab bar.

## Why this design

macOS exposes no public window-manager API. The only SIP-safe path is the
Accessibility API (`AXUIElement`), which can move/resize/raise other apps' windows.
Mosaic deliberately **does not** try to graft onto Apple's native Split View (a closed
system) nor re-parent foreign windows (forbidden by macOS). Instead it *recreates* the
i3 experience on regions it owns:

- **Tabbed container** = overlay tab bar (a borderless floating `NSWindow`) + a stack
  of equally-sized windows + `AX` raise of the active one. Robust, no private APIs.

## Build & run

```sh
make run      # build release, bundle Mosaic.app, launch it
```

Then grant **System Settings › Privacy & Security › Accessibility → Mosaic** and
relaunch. A `▦` icon appears in the menu bar.

## Sharing with a tester

Mosaic isn't notarized (no Apple Developer account), so a tester has to bypass
Gatekeeper once. Build a shareable zip:

```sh
make dist        # → Mosaic.zip (arm64, ad-hoc signed)
```

Send `Mosaic.zip`. The tester then:
1. Unzips it and moves `Mosaic.app` to `/Applications` (optional).
2. Clears the quarantine flag (it's not notarized):
   ```sh
   xattr -dr com.apple.quarantine /Applications/Mosaic.app
   ```
   (or right-click → Open, then System Settings › Privacy & Security → "Open Anyway").
3. Opens it, and grants **System Settings › Privacy & Security › Accessibility → Mosaic**,
   then relaunches. A `▦` icon appears in the menu bar.

Notes: arm64 (Apple Silicon) only; needs macOS 13+; uses the Accessibility API + private
SkyLight SPI (no SIP change required). For warning-free public distribution you'd need a
Developer ID cert + notarization (`notarytool`).

## Config

On first launch Mosaic writes `~/.config/mosaic/config.json`. Edit it, then apply with
the menu's **"Reload config"** (no restart needed — gaps, modes, floating apps, rules,
HUD and keybindings all reload live). "Open config file…" opens it. Keys: `gap`, `tabBarHeight`, `defaultMode`
(`columns`/`grouped`/`tabbed`), `floatingApps` (app names/bundle ids, lowercased),
and `keybindings` (action → combo, e.g. `"tile": "cmd alt t"`; tokens: `cmd`/`alt`/
`ctrl`/`shift` + a key like `t`, `left`, `space`). Only the bindings you list override
the defaults.

Window styling: `borderEnabled`, `borderColor` (`"accent"` or `"#RRGGBB"`),
`borderWidth`, `borderCornerRadius`, and `inactiveOpacity` (< 1.0 dims unfocused
windows, via private `CGSSetWindowAlpha`) / `activeOpacity`. Opacity is restored on quit.

Tab bar styling: `tabCornerRadius`, `tabBarColor`, `tabActiveColor`, `tabTextColor`,
`tabActiveTextColor` (hex or `"accent"`), `tabFontSize`.

`rules` is a list of per-app auto-placement rules applied when a window opens:
```json
"rules": [
  { "app": "discord", "float": true },
  { "app": "slack", "groupWith": "discord" },
  { "app": "spotify", "place": "column" }
]
```
`app` matches (case-insensitive substring) the app name or bundle id. `float` keeps it
out of tiling; `groupWith` auto-tabs it with the named app when present; `place` is
`column` (new column), `tab` (tab with the focused window), or omitted (next to focus).
Rules apply as windows open into an already-managed desktop.

For a quick debug build without bundling: `swift build && .build/debug/Mosaic`.

## Controls

| Action | Shortcut |
|---|---|
| Tile current desktop (build the tree) | ⌘⌥T |
| Cycle initial build: Columns → Grouped → Tabbed | ⌘⌥W |
| Manage all desktops (toggle) | ⌘⌥A |
| Focus group (skip tabs) | ⌘⌥⌃ + ← ↑ ↓ → |
| Move focus | ⌘⌥ + ← ↑ ↓ → |
| Move the focused window | ⌘⌥⇧ + ← ↑ ↓ → |
| Resize focused window | ⌃⌥ + ← ↑ ↓ → |
| Group focused window with neighbor as a tab | ⌘⌥G |
| Reorder tabs | drag a tab in its strip |
| Move a tab to another group | drag a tab onto another group/window |
| Resize tiles | drag a split border (mouse) |
| Toggle parent split H/V | ⌘⌥E |
| Toggle parent tabbed on/off | ⌘⌥S |
| Equalize container ratios | ⌘⌥= |
| Rotate windows in container | ⌘⌥R |
| Reset desktop layout | ⌘⌥⇧R |
| Float / unfloat the focused app | ⌘⌥F |
| Zoom focused tile (monocle, fills screen) | ⌘⌥↩ |
| Send focused window to scratchpad | ⌘⌥⇧- |
| Toggle scratchpad (show/hide floating) | ⌘⌥- |
| Move window to prev/next screen | ⌘⌥[ / ⌘⌥] |
| Move window to prev/next desktop | ⌘⌥⇧[ / ⌘⌥⇧] |
| Assign current desktop to workspace N | ⌘⌥⌃1‑9 |
| Switch to workspace N (i3-style) | ⌘⌥1‑9 |
| Send focused window to workspace N | ⌘⌥⇧1‑9 |
| Clear layout | menu |

**Workspaces:** assign a number to a desktop with ⌘⌥⌃N (or the menu's "Assign this
desktop to…"); ⌘⌥N then always switches to *that* desktop (falling back to Mission
Control order if a number is unassigned). A HUD shows the number on every switch and
the menu-bar icon shows `▦N`. Assignments persist in `state.json`. Numbers are global
and unique across all screens. The HUD is configurable: `showWorkspaceHUD` (true/false)
and `hudPosition` (`center`/`top`/`bottom`/`top-left`/`top-right`/`bottom-left`/
`bottom-right`).

**Zoom (monocle):** ⌘⌥↩ makes the focused tile fill the screen *inside Mosaic* (no
macOS fullscreen, never leaves the manager); toggle again to restore it to its place.
A video playing in the tile follows the size. Use this instead of a video's own
fullscreen button (which would trigger macOS fullscreen and leave Mosaic).

The default **Columns** build lays every window out as a flat row of siblings, so any
two visually-adjacent windows can be merged. Build **arbitrary tab groups across apps**
(e.g. 2/2/3) by focusing a window and pressing ⌘⌥G to merge it with its neighbor into a
tab stack — repeat to add a third. Drag a tab within its strip to reorder. The tree is
persistent and edited live.

**Floating windows**: transient/utility apps (screenshot tools like Skitch, etc.) are
kept out of the layout so taking a screenshot never reshuffles your panes. When a
window outside the managed set opens or closes, Mosaic does nothing. Float/unfloat any
app on the fly with ⌘⌥F; the default float list lives in `WindowManager.floatingApps`.

Click a tab in the strip to switch directly.

## Architecture

```
Sources/Mosaic/
  main.swift              Accessory app entry point
  AppDelegate.swift       Menu bar + hotkey wiring + AX permission prompt
  Accessibility/AX.swift  Swift wrappers over the C AXUIElement API
  Geometry.swift          Cocoa (bottom-left) <-> AX (top-left) coordinate flip
  Window/
    ManagedWindow.swift    One controllable window (AX element + owning app)
    WindowManager.swift    Owns the persistent tree + keyboard editing ops
    WindowObserver.swift   AXObserver-driven live updates (create/close/launch/quit)
  Layout/
    Container.swift        ★ i3-style tree node: leaf | splitH | splitV | tabbed
  UI/
    TabBarWindow.swift     Borderless floating overlay hosting the tab strip
    TabBarView.swift       Draws tabs, handles clicks
  Hotkeys/HotkeyManager.swift  Global shortcuts via Carbon RegisterEventHotKey
```

## Roadmap

This first cut is a **vertical slice**: it proves the tab system works end to end.
Tiling is scoped to the **current Space on the screen under the mouse** — windows on
other displays or desktops are left alone (active-Space filtering via
`CGWindowListCopyWindowInfo`, display filtering via the window's frame). Next layers:

1. ~~**BSP tiling**~~ — ✅ done.
2. ~~**AX observers**~~ — ✅ done. `WindowObserver` updates the managed screen live
   on window create/close, app hide/show, and app launch/quit (debounced; never
   observes move/resize/focus to avoid self-triggered loops).
3. ~~**Manual tree editing**~~ — ✅ done. Persistent i3-style `Container` tree:
   directional focus, move, resize, group-as-tab (⌘⌥G), split/tabbed toggles, and
   per-app floating (⌘⌥F) with a default float list. Floating/transient windows never
   reshuffle the layout.
4. ~~Tab reorder (drag & drop)~~ — ✅ done within a strip.
5. ~~Per-desktop management + global toggle~~ — ✅ done. One layout tree per macOS
   Space (`SpaceState`, keyed by the Space id read via private SkyLight SPI in
   `Spaces.swift`). Switching desktops loads that desktop's layout; ⌘⌥A auto-manages
   every desktop. Full-screen windows are left alone.
6. ~~Config file~~ — ✅ done. `~/.config/mosaic/config.json` (written on first run):
   `gap`, `tabBarHeight`, `defaultMode`, `floatingApps`, and `keybindings` (combos like
   `"cmd alt t"`). Edit and restart Mosaic; "Open config file…" is in the menu.
7. ~~Layout persistence~~ — ✅ done. Each desktop's tree is saved to
   `~/.config/mosaic/state.json` (debounced + on quit) and restored on launch by
   matching live windows (CGWindowID, else bundle id + title). Stable across a Mosaic
   relaunch while apps stay open; best-effort across reboots.
8. ~~Mouse drag-resize~~ — ✅ done. Invisible `ResizeHandle` overlays on every split
   border; drag to live-resize the adjacent tiles (ratios persisted).
9. ~~App auto-placement rules~~ — ✅ done. `rules` in config: per-app `float`,
   `groupWith` (auto-tab with another app), `place`. Applied as windows open.
10. ~~Move window to another desktop/screen~~ — ✅ done. ⌘⌥[ / ] moves to the prev/next
    display (tiled immediately); ⌘⌥⇧[ / ] moves to the prev/next desktop on the same
    display (private Space API; absorbed into that desktop's layout on visit).
11. ~~i3-style numbered workspaces~~ — ✅ done. ⌘⌥1‑9 switch desktop (activates a
    managed window there, else synthesizes ⌃-arrows), ⌘⌥⇧1‑9 send window to desktop N.
    Keyboard resize now has the same min-size butée as mouse resize.
12. ~~User-assigned workspace numbers + visual indicator~~ — ✅ done. ⌘⌥⌃N pins the
    current desktop to number N (persisted); ⌘⌥N/⌘⌥⇧N use it; a HUD + menu-bar `▦N`
    show the current workspace.
13. ~~Live config reload~~ — ✅ done (menu → "Reload config"; re-registers hotkeys,
    rebuilds menu, re-renders).
14. ~~Scratchpad~~ — ✅ done. ⌘⌥⇧- designates the focused window as a hidden scratchpad
    (out of tiling); ⌘⌥- shows/hides it floating, centered, on the current desktop.
15. ~~Window styling~~ — ✅ done. Configurable focus border (color/width/on-off) and
    inactive-window dimming (`inactiveOpacity` via `CGSSetWindowAlpha`); live-reloadable.
16. ~~Tab bar / corner styling~~ — ✅ done. Rounded tab bars + focus border, colors,
    text & font size, all in config and live-reloadable.
17. ~~Cross-group tab drag & drop~~ — ✅ done. Drag a tab out of its bar onto another
    group/window to move it there (or wrap two windows into a new tab group).
18. ~~Layout QoL~~ — ✅ done. Equalize (⌘⌥=), rotate (⌘⌥R), reset desktop (⌘⌥⇧R),
    and `outerGap` config (screen-edge margin). Ratios now preserved across add/remove.
19. **Next**: sessions/startup layouts, multiple scratchpads, per-window floating.
3. **Per-space management** — persist which Space each container belongs to, "managed"
   vs "untouched" spaces, plus a global "manage everything" toggle.
4. **Drag & drop** between containers, resize handles, gaps config.
5. **Spotlight-launched apps** auto-placed via `NSWorkspace` launch notifications.
6. **Config file** (keybindings, gaps, default layout).

### Known constraints (by design, not bugs)
- Apple's native Split View cannot be extended — Mosaic recreates it instead.
- A window's own title bar still shows inside a tabbed region (could be trimmed later).
- Creating/destroying macOS Spaces programmatically requires SIP-off; Mosaic targets
  the SIP-on subset for minimal system impact.
```

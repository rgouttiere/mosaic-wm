# Mosaic — cheat sheet

Menu-bar icon **▦** (with the current workspace number). Default shortcuts below — all overridable in `~/.config/mosaic/config.json`.

## Concepts

- **Tiling modes** (auto-placement): `columns` · `grouped` (by app) · `tabbed` · `master-stack` (one master + a tabbed stack). Cycle with **⌘⌥W**. **⌘⌥T** (re)starts managing the current desktop.
- **Containers** (i3-style, nestable):
  - **Split** horizontal / vertical — toggle H↔V with **⌘⌥E**.
  - **Tabbed** — **⌘⌥S**: one window shown, a horizontal tab strip.
  - **Stacked** — **⌘⌥⇧S**: one window shown, a vertical title list. Can hold tab groups / splits (drawn inline). Drag a row to reorder it, or out of the bar to detach/move it (like horizontal tabs).
  - **Drag & drop**: drag a tab and drop it on another tile — the **centre** tabs into it, an **edge** (top/bottom/left/right) splits beside/under it. A frosted highlight previews the exact landing slice.
- **Moving a window anywhere** (three ways, all landing it identically):
  - **Drag its tab** (above) — needs the window to be in a tab strip.
  - **Drag any window**: hold **`dragModifier`** (default **⌃⌥⌘**) and left-drag *anywhere* on a window — works for a lone column with no tab strip. Same centre/edge rule. Set `dragModifier: ""` to disable.
  - **Keyboard grab** (**⌘⌥M**): picks up the focused window, then **hjkl**/arrows aim a target tile · **⏎** tabs it into the target · **⇧+h/j/k/l** splits it on that side (**⇧J** = below) · **Esc** or a click cancels. This is how you put a tabbed window *under* another one without the mouse.
- **Preselect** (i3-style): **⌘⌥V** / **⌘⌥H** arm a split (below / right); the **next** window opened nests there. A tint on the focused window's edge shows where. Moving focus cancels it.
- **Workspaces** numbered 1–9 (unique, across screens). Assign a desktop to a number, then jump to it. Optionally **name** them via `workspaceNames` in config (the number stays the key; the name is just a label). **`workspaceWrap`** (default `true`): cycling (Ctrl+←/→ or the 3-finger swipe) wraps around; set `false` to stop at the first/last workspace.
- **Quick-switcher / command palette** (**⌘⌥P**): a fuzzy popup. **"Go"** mode jumps to a workspace (by name/number) or window (by title) — grouped under section headers, most-recent first, with per-workspace window counts and app icons. **←/→** flips to **"Actions"** mode to run any Mosaic action. **↑/↓** move (skipping headers) · **⏎** go/run · **⌘⏎** move the focused window to the highlighted workspace · **Esc** dismiss.
- **Window hints** (**⌘⌥J**): overlays a letter on every visible window (across all screens); type it to focus that window (the mouse follows for cross-screen jumps). **⌘⌥J** again or **Esc** cancels.
- **Exposé** (**⌘⌥O**): a Mission-Control-style overview drawn from the layout tree — every workspace of every screen at once, one column per screen, tiles to scale with tab strips + app icons (fullscreen apps shown by name). Tiles show **live window previews** (captured on open via ScreenCaptureKit, parked workspaces included); the active tab of a tabbed group reads by a faint accent tint + underline. **← → ↑ ↓** navigate (2D) · **⇥** cycle · **⏎** jump · **Esc** cancel. Set `exposeSwitch` (e.g. `"cmd tab"`) to also drive it as an alt-tab: **hold** the modifier to browse, **⇥** to cycle, **release** to commit. It opens on the workspace you're on; set `exposeAllScreens: true` to show it on every screen at once. Off (native ⌘Tab) by default.
  - Previews need the **Screen Recording** permission (macOS prompts for Mosaic on first exposé; if it doesn't, add Mosaic under *System Settings → Privacy & Security → Screen Recording* — macOS relaunches the app after). Set **`exposeThumbnails: false`** to disable previews entirely (no capture, no permission prompt) and fall back to schematic tiles. Default `true`.
- **Focus halo** (`config.json`): the focused window gets a soft accent glow — **`focusGlowRadius`** px (default 6; 0 = just the crisp border). **`focusGlowFade`** (default true) fades the border in when focus jumps to another window (in place, never travelling; honours the system *Reduce Motion*).
- **Letterbox** (`config.json`): a window that doesn't fill its tile (e.g. IINA keeping video aspect) gets its gap filled so a parked sibling's residual strip can't peek through. **`letterboxStyle`**: `"black"` (default, plain bars) or `"matrix"` (a static green rune-rain with a neon  logo, tinted by the accent).
- **Aspect-fit apps** (`config.json`): **`aspectFitApps`** (default `["iina", "mpv"]`) lists apps whose windows lock to a fixed video aspect. Rather than let such a window overshoot its tile (which freezes the column, since it won't shrink one axis), Mosaic sizes it to the largest box of its own ratio that fits the tile, centres it, and letterboxes the rest — so the column stays resizable even while the video is the visible tab. Match by app name or bundle id.
- **Accent** (`config.json`): **`accentColor`** is the single accent for the whole UI — `"accent"`/`"system"` follows the macOS system accent, or a hex like `"#a6e3a1"` pins it. Everything set to `"accent"` (`borderColor`, `tabActiveColor`, `dropHighlightColor`) and all overlays (exposé, switcher, HUD, hints, drag ghost) resolve through it, so one value re-themes the lot.
- **Window borders** (`config.json`): the focused window keeps its bright halo; **`borderInactive: true`** also draws a permanent dim accent border on every other tile. **`inactiveBorderOpacity`** (default `0.42`) tunes how present those inactive borders are. **`dimInactiveMonitors: true`** fades the borders + tab strips on the monitor(s) without keyboard focus, by **`inactiveMonitorDim`** (default `0.6`, the fraction of brightness they keep; `1` = no dim).
- **Trackpad gestures** (`config.json`): **`trackpadGestures: true`** enables native 3-finger swipes (raw MultitouchSupport) — ←/→ switch workspace, ↑ opens the exposé, ↓ commits, and in the exposé 3-finger moves the selection while 2-finger navigates the grid. Disable macOS's own 3/4-finger gestures first so they don't fight. Off by default.
- **Picture-in-picture** (`pip` action): a live, floating, draggable mirror of the focused window (even one parked on another workspace) via ScreenCaptureKit — the source keeps playing, so audio continues. Right-click / Space = play-pause, scroll = the player's volume, ⤢ = return to the window. Needs Screen Recording. No default key for `pip` — bind it in `keybindings`. **⌘⌥⇧P** (`pip-here`) brings the PiP **centred under the mouse pointer** on whatever screen you're on (clamped so it can't hang off an edge) — so you never have to drag it across monitors.
- **Notch HUD** (`config.json`): **`notchHud: true`** shows the workspace indicator as a dynamic-island pill under the notch on switch (instead of the corner HUD).
- **Scratchpad**: a dedicated app shown/hidden as a floating panel (survives relaunch).
- **Rules** (`config.json`): `float`, `groupWith`, `place` (`column`/`tab`), `workspace: N`, `fullscreen` (`false` = force windowed/tileable, `true` = force native full screen; add `fullscreenLock: true` to keep enforcing it).

## Shortcuts

### Manage / modes
| Action | Shortcut |
|---|---|
| Tile the current desktop | ⌘⌥T |
| Manage all windows | ⌘⌥A |
| Cycle mode (columns/grouped/tabbed) | ⌘⌥W |
| Reset desktop | ⌘⌥⇧R |
| Clear (stop managing) | ⌘⌥⇧C |

### Focus
| Action | Shortcut |
|---|---|
| Focus left / right / up / down | ⌘⌥← → ↑ ↓ |
| Focus by group (skip the whole group) | ⌘⌥⌃← → ↑ ↓ |

### Move / resize
| Action | Shortcut |
|---|---|
| Move window (restructures) | ⌘⌥⇧← → ↑ ↓ |
| Swap window with neighbor (keeps layout) | ⌘⌃← → ↑ ↓ |
| Resize | ⌃⌥← → ↑ ↓ |
| Equalize ratios | ⌘⌥= |
| Rotate windows in the group | ⌘⌥R |

### Layout (containers)
| Action | Shortcut |
|---|---|
| Group with neighbor (tabs) | ⌘⌥G |
| Group with neighbor (stack) | ⌘⌥⇧G |
| Toggle split H ↔ V | ⌘⌥E |
| Toggle tabbed | ⌘⌥S |
| Toggle stacked | ⌘⌥⇧S |
| Preselect vertical split (next window below) | ⌘⌥V |
| Preselect horizontal split (next window right) | ⌘⌥H |
| Next / previous tab | ⌘⌥. / ⌘⌥, |
| Toggle floating | ⌘⌥F |
| Zoom / monocle | ⌘⌥↩ |
| Grab (move window: hjkl aim, ⏎ tab, ⇧hjkl split) | ⌘⌥M |
| Bring picture-in-picture under the mouse | ⌘⌥⇧P |

### Workspaces & screens
| Action | Shortcut |
|---|---|
| Quick-switcher / command palette (again = close) | ⌘⌥P |
| Window hints (type a letter to focus; again = close) | ⌘⌥J |
| Schematic exposé (arrows/⇥ to navigate, ⏎ to jump) | ⌘⌥O |
| Previous workspace (back-and-forth) | ⌘⌥B |
| Go to workspace N | ⌘⌥1…9 |
| Send window to workspace N | ⌘⌥⇧1…9 |
| Assign current desktop to number N | ⌘⌥⌃1…9 |
| Unassign workspace N (or the current one) | ⌘⌥⌃0 |
| Send window to next / previous screen | ⌘⌥] / ⌘⌥[ |
| Send window to next / previous desktop | ⌘⌥⇧] / ⌘⌥⇧[ |

### Scratchpad
| Action | Shortcut |
|---|---|
| Show / hide the scratchpad | ⌘⌥- |
| Set the focused app as the scratchpad | ⌘⌥⇧- |

## CLI

Every action is also scriptable from the command line — `mosaic <action>` sends it to the running app (great for scripts, sketchybar, etc.). Install the command with `make install-cli`.

```sh
mosaic --list            # list all actions
mosaic focus-left        # same as the ⌘⌥← binding
mosaic workspace-3       # jump to workspace 3
mosaic swap-up           # swap with the window above
mosaic toggle-stacked
mosaic dump-layout       # write /tmp/mosaic-dump.txt
```

Action names match the `keybindings` keys in `config.json` (`focus-left`, `move-right`, `swap-up`, `group`, `group-stacked`, `preselect-vertical`, `toggle-tabbed`, `workspace-N`, `move-to-N`, `assign-N`, `unassign-N`, `unassign`, `switcher`, `hints`, `expose`, `pip`, `pip-here`, `grab`, `workspace-back`, …) plus `reload-config` and `dump-layout`.

A binding value may list **several combos**, comma-separated — e.g. `"resize-up": "ctrl alt k, ctrl alt up"` binds an action to both. An empty value (`""`) disables the binding.

**Query state** (for status bars / scripts):
```sh
mosaic query               # full JSON: focused, monitors[], workspaces[],
                           #   workspaceNames{n:name}, workspaceDisplays{n:displayID}
mosaic query focused       # focused workspace number
mosaic query workspaces    # assigned workspace numbers, space-separated
```
`workspaceNames` / `workspaceDisplays` let a bar label each workspace and show it only on the monitor it lives on.

## Status bar (sketchybar)

Mosaic runs a shell command on every workspace change — config key **`onWorkspaceChange`** (env `MOSAIC_WORKSPACE` = focused number). Point it at a sketchybar trigger:

```json
"onWorkspaceChange": "sketchybar --trigger mosaic_workspace_change"
```

Then, in sketchybar, subscribe an item to `mosaic_workspace_change` and render from `mosaic query`:
```sh
# sketchybar plugin
FOCUSED=$(mosaic query focused)
sketchybar --set "$NAME" label="$FOCUSED"        # or loop over `mosaic query workspaces`
```
(`make install-cli` puts `mosaic` on your PATH; the hook's PATH already includes `/opt/homebrew/bin`.)

## Menu bar (▦)

The menu-bar icon opens a menu with clickable entries for most actions (each showing its current shortcut), plus:

- **Navigation & overlays** — Overview (Exposé), Picture-in-picture, Quick-switcher / palette, Window hints, Back to previous workspace.
- **Assign this desktop to…** (submenu, workspaces 1–9) · **Unassign this desktop**.
- **Open config file…** · **Reload config** · **Clear layout**.
- **Debug: dump layout → /tmp/mosaic-dump.txt** (attach this to bug reports).
- **Quit Mosaic**.

# Mosaic — cheat sheet

Menu-bar icon **▦** (with the current workspace number). Default shortcuts below — all overridable in `~/.config/mosaic/config.json`.

## Concepts

- **Tiling modes** (auto-placement): `columns` · `grouped` (by app) · `tabbed`. Cycle with **⌘⌥W**. **⌘⌥T** (re)starts managing the current desktop.
- **Containers** (i3-style, nestable):
  - **Split** horizontal / vertical — toggle H↔V with **⌘⌥E**.
  - **Tabbed** — **⌘⌥S**: one window shown, a horizontal tab strip.
  - **Stacked** — **⌘⌥⇧S**: one window shown, a vertical title list. Can hold tab groups / splits (drawn inline).
- **Preselect** (i3-style): **⌘⌥V** / **⌘⌥H** arm a split (below / right); the **next** window opened nests there. A tint on the focused window's edge shows where. Moving focus cancels it.
- **Workspaces** numbered 1–9 (unique, across screens). Assign a desktop to a number, then jump to it.
- **Scratchpad**: a dedicated app shown/hidden as a floating panel (survives relaunch).
- **Rules** (`config.json`): `float`, `groupWith`, `place` (`column`/`tab`), `workspace: N`.

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

### Workspaces & screens
| Action | Shortcut |
|---|---|
| Go to workspace N | ⌘⌥1…9 |
| Send window to workspace N | ⌘⌥⇧1…9 |
| Assign current desktop to number N | ⌘⌥⌃1…9 |
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

Action names match the `keybindings` keys in `config.json` (`focus-left`, `move-right`, `swap-up`, `group`, `group-stacked`, `preselect-vertical`, `toggle-tabbed`, `workspace-N`, `move-to-N`, `assign-N`, …) plus `reload-config` and `dump-layout`.

**Query state** (for status bars / scripts):
```sh
mosaic query               # full JSON: focused, per-monitor workspace, workspaces[]
mosaic query focused       # focused workspace number
mosaic query workspaces    # assigned workspace numbers, space-separated
```

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
Reload config · Open config file · Clear layout · **Debug: dump layout → /tmp/mosaic-dump.txt** (diagnostics).

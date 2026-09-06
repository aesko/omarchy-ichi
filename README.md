<p align="center">
  <img src="logo.svg" alt="Ichi" width="160">
</p>

<h1 align="center">Ichi</h1>

<p align="center"><em>One window, room to breathe.</em></p>

An Omarchy plugin that keeps a lone window from sprawling across a big screen.

When an opted-in workspace holds exactly one tiled window, the workspace's
outer gaps widen so that window occupies a chosen share of the screen — a
percentage of width and height, or an aspect ratio — centred. Open a second
window and the gaps snap back, so the space is never wasted. Each workspace
decides for itself, the size is adjustable live from the keyboard, and the
window stays tiled the whole time.

That last part is the reason this is gaps rather than a floating rule: a
tiled window is re-laid-out for free after a monitor teardown (hibernate,
unplug, resolution change), where a floating one comes back at stale
coordinates, half off-screen.

Hyprland has a global version of this, `layout.single_window_aspect_ratio`,
which Omarchy exposes as **1-Window Ratio** in the Toggle menu. It picks a
shape and always maximises it, so it cannot make a window *smaller* than the
screen's own ratio, and it applies to every workspace or none. Ichi's aspect
mode covers what it does; size mode and per-workspace control are the parts
it cannot.

## Requirements

| Needs | Why |
| --- | --- |
| Omarchy 4.x (Quattro plugin runtime) | the service is Quickshell QML loaded by `omarchy-shell` |
| Hyprland 0.55 or newer | the Lua config API: `hl.workspace_rule`, `hl.on`, `hl.get_workspace_windows` |
| `hyprctl` on `PATH` | how the shell hands Lua to the compositor |

No compiled component, no daemon, no network access. Built and tested against
Hyprland 0.56.2 on Omarchy 4.0.2.

## Install

```bash
omarchy plugin add https://github.com/aesko/omarchy-ichi --enable
```

On first run the service appends one guarded line to `~/.config/hypr/hyprland.lua`
that loads `ichi.lua`. Nothing is enabled on any workspace until you toggle
one, so installing changes nothing about how your desktop tiles.

## Keybindings

Plugins cannot install bindings, so add these to `~/.config/hypr/bindings.lua`.
They are guarded, so the config stays valid if the plugin is removed. The
suggested set uses one modifier family throughout; `SUPER+CTRL+ALT+Z` is
avoided because Omarchy binds it to zoom reset, and `SUPER+ALT+arrows` because
Omarchy uses those to move windows between groups.

```lua
-- Ichi (aesko.ichi)
o.bind("SUPER + CTRL + ALT + I", "Ichi: toggle", function()
  if ichi then ichi.toggle() end
end)
o.bind("SUPER + CTRL + ALT + A", "Ichi: reset size", function()
  if ichi then ichi.reset() end
end)
o.bind("SUPER + CTRL + ALT + LEFT", "Ichi: narrower", function()
  if ichi then ichi.adjust(-ichi.config.defaults.step, 0) end
end)
o.bind("SUPER + CTRL + ALT + RIGHT", "Ichi: wider", function()
  if ichi then ichi.adjust(ichi.config.defaults.step, 0) end
end)
o.bind("SUPER + CTRL + ALT + UP", "Ichi: taller", function()
  if ichi then ichi.adjust(0, ichi.config.defaults.step) end
end)
o.bind("SUPER + CTRL + ALT + DOWN", "Ichi: shorter", function()
  if ichi then ichi.adjust(0, -ichi.config.defaults.step) end
end)
```

Every binding acts on the workspace you are currently on. Nudging the size of a
workspace that is off turns it on.

## Omarchy menu

Add to `~/.config/omarchy/extensions/omarchy-menu.jsonc` to get an entry under
**Toggle** with a checkmark when the current workspace is on:

```jsonc
"trigger.toggle.ichi": {
  "icon": "",
  "label": "Ichi",
  "description": "Inset the lone window on this workspace",
  "checked": "[ \"$(omarchy-shell aesko.ichi enabled)\" = true ]",
  "action": "omarchy-shell aesko.ichi toggle"
},
```

## Command line

```bash
omarchy-shell aesko.ichi status          # JSON for the focused workspace, plus defaults
omarchy-shell aesko.ichi enabled         # true | false
omarchy-shell aesko.ichi toggle
omarchy-shell aesko.ichi reset
omarchy-shell aesko.ichi adjust 5 0      # width +5 points, height unchanged
omarchy-shell aesko.ichi aspect 4 3      # switch this workspace to 4:3
omarchy-shell aesko.ichi defaults 65 85  # what a workspace gets when toggled on or reset
omarchy-shell aesko.ichi step 10         # arrow-key increment, in percentage points
omarchy-shell aesko.ichi adopt           # make this workspace's size the default
omarchy-shell aesko.ichi refresh         # re-read the config and re-apply
```

The same functions are reachable from Lua as `ichi.toggle()`,
`ichi.adjust(dw, dh)`, `ichi.reset()`, `ichi.set_aspect(w, h)`,
`ichi.set_defaults(w, h, step)`, `ichi.adopt_defaults()`,
`ichi.enable(id, entry)` and `ichi.disable(id)`, or from a shell with
`hyprctl eval 'ichi.toggle()'`.

The quickest way to a default you like: turn a workspace on, tune it with the
arrows, then `adopt`.

## Configuration

State lives in `~/.config/omarchy/ichi.json`, plain JSON you can read, edit
and keep in your dotfiles. Edits apply within a second. A malformed entry is
dropped; a malformed file keeps the last good document.

```json
{
  "defaults": { "width": 70, "height": 80, "step": 5 },
  "workspaces": {
    "2": { "mode": "size", "width": 70, "height": 80 },
    "5": { "mode": "aspect", "ratio": [4, 3] }
  }
}
```

- `defaults` is what a workspace gets when toggled on or reset; `step` is the
  arrow-key increment in percentage points.
- `size` mode is a percentage of the *usable* area — the monitor minus the bar
  — so the proportion holds on any display and the window sits centred.
  Values are clamped to 30–100; at 100 the inset is exactly your normal gaps.
- `aspect` mode is the largest box of that ratio, centred, which is what
  Hyprland's built-in setting does.

Workspaces are identified by number. Named workspaces are not supported yet.

## Behaviour

- Applies only when the workspace holds exactly **one tiled** window. Floating
  windows are neither counted nor touched, so Omarchy's floating dialogs,
  pickers and TUIs are unaffected.
- A second tiled window restores the normal gaps immediately; closing it
  restores the inset.
- Special workspaces are ignored.
- Sizes are recomputed whenever the monitor arrangement changes.

### Custom layouts

Plugins such as [workspace-layout](https://github.com/bjarneo/omarchy-workspace-layout)
register their own Hyprland layouts and assign them per workspace. On a
workspace running one of those, Ichi **yields**: it leaves the gaps at their
normal value and tells you once. The two can be active side by side, each on
its own workspaces. Hyprland merges workspace rules field by field, so neither
plugin ever wipes the other's settings.

### Hyprland's 1-Window Ratio

If `layout.single_window_aspect_ratio` is set — Omarchy's **Toggle → 1-Window
Ratio** — the compositor pads the window inside the area Ichi has already
inset, and the two compound. Ichi warns once per session when it sees both
active. Turn the built-in off and give the workspace an aspect mode entry
instead; the result is the same shape, per workspace.

## Uninstall

```bash
omarchy plugin remove aesko.ichi
```

The loader line in `hyprland.lua` checks that `ichi.lua` exists before loading
it, so it is harmless to leave; delete it if you like. Remove
`~/.config/omarchy/ichi.json` to forget the per-workspace settings.

## Development

```bash
git clone https://github.com/aesko/omarchy-ichi
ln -s "$PWD/omarchy-ichi" ~/.config/omarchy/plugins/aesko.ichi
omarchy plugin enable aesko.ichi
tests/run.sh
```

`ichi.lua` is the behaviour and runs inside Hyprland. `Model.js` is the pure
shell-side logic. `Service.qml` is glue. Both pure parts have tests that run
without a compositor. `hyprctl reload` reloads `ichi.lua`. A running service
keeps Quickshell's cached component even across `omarchy plugin disable` /
`enable`, so after editing `Service.qml` or `Model.js` use `omarchy restart shell`.

## License

MIT

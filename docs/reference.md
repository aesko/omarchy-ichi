# Reference

Every command Ichi answers to, every key its config file takes, and the
Omarchy menu entries. The [README](../README.md) covers installing it and the
parts you use daily.

## Commands

Ichi answers to two IPC names: `ichi`, and `io.github.aesko.ichi`, the plugin
id. They are the same surface. Use the id in anything that outlives the
session, such as the menu entries below, where a short name could collide.

```bash
omarchy-shell ichi status                         # this workspace and the settings, as text
omarchy-shell ichi status_json                    # the same, as JSON
omarchy-shell ichi enabled                        # true | false
omarchy-shell ichi toggle
omarchy-shell ichi reset
omarchy-shell ichi nudge -1 0                     # one step narrower
omarchy-shell ichi nudge_fine 0 1                 # one fine step taller
omarchy-shell ichi size 65 85                     # an absolute size for this workspace
omarchy-shell ichi aspect 4 3                     # switch this workspace to 4:3
omarchy-shell ichi preset reading                 # give this workspace a preset
omarchy-shell ichi cycle                          # next preset
omarchy-shell ichi cycle_back                     # the previous one
omarchy-shell ichi save_preset wide               # keep this workspace's size as a preset
omarchy-shell ichi remove_preset wide
omarchy-shell ichi set defaults.width 65          # any setting, by its place in the file
omarchy-shell ichi pause on                       # suspend every inset; pause off to resume
omarchy-shell ichi pause_toggle                   # the same, as one command
omarchy-shell ichi paused                         # true | false
omarchy-shell ichi adopt                          # make this workspace's size the default, and follow it
omarchy-shell ichi adopt_monitor                  # the same, but only for this workspace's monitor
omarchy-shell ichi refresh                        # re-read the config and re-apply
omarchy-shell ichi sync                           # re-check the loader line in hyprland.lua
omarchy-shell ichi.panel toggle                   # open or close the panel
```

### set

`set` takes a key from the `settings` or `defaults` block below, written as
its place in the file. An unknown key is refused with the list of keys; a
value that does not fit is refused with what the setting takes. Numbers out
of range are clamped, as they are when the file is read.

| Key | Takes |
|---|---|
| `settings.step`, `settings.fine_step` | points, 1 to 25 |
| `settings.notify` | `never`, `changes` or `always` |
| `settings.all_workspaces`, `settings.paused` | `on` or `off` |
| `settings.max_windows` | windows, 1 to 10 |
| `defaults.width`, `defaults.height` | percent, 10 to 100 |
| `defaults.max_width`, `defaults.max_height` | pixels, `0` for no cap |
| `defaults.align_x`, `defaults.align_y` | 0 to 100, `50` the centre |

### Deprecated

These still work in 0.7 and print what replaces them. They go in 1.0.

| Command | Instead |
|---|---|
| `adjust 5 0` | `nudge 1 0`, or `size` |
| `defaults 65 85` | `set defaults.width 65`, `set defaults.height 85` |
| `max 1800 0` | `set defaults.max_width 1800`, `set defaults.max_height 0` |
| `align 50 40` | `set defaults.align_x 50`, `set defaults.align_y 40` |
| `step 10` | `set settings.step 10` |
| `fine_step 2` | `set settings.fine_step 2` |
| `windows 2` | `set settings.max_windows 2` |
| `all on` | `set settings.all_workspaces on` |
| `notify never` | `set settings.notify never` |
| `min 10` | nothing: the smallest size is fixed at 10%, and `min` does nothing |

## From Lua

The same functions, which is how the keybindings reach them and the only way
in on a session without Omarchy:

```lua
ichi.toggle()                  ichi.reset()
ichi.nudge(dx, dy, fine)       ichi.set_size(w, h)
ichi.set_aspect(w, h)          ichi.adopt_defaults(id, scope)
ichi.preset(name)              ichi.cycle(delta)
ichi.save_preset(name)         ichi.remove_preset(name)
ichi.set(key, value)           ichi.set_paused(on)
ichi.toggle_pause()            ichi.entry_for(id)
ichi.enable(id, entry)         ichi.disable(id)
ichi.load()                    ichi.refresh()
```

`ichi.set` returns true when the setting took the value. `ichi.adjust`, and
the functions `set` replaces — `set_defaults`, `set_max`, `set_align`,
`set_step`, `set_notify`, `set_max_windows`, `set_all_workspaces` and
`set_min_percent` — are deprecated with their commands and go in 1.0.

From a shell: `hyprctl eval 'ichi.toggle()'`.

### Building on it

Ichi has no rules of its own beyond one entry per workspace, but your
Hyprland config can decide when to write one. This turns Ichi on for a
workspace whose name starts with `notes` the first time it appears, and
leaves it alone after that, so turning one off sticks:

```lua
-- ~/.config/hypr/hyprland.lua, after the line that loads Ichi
local seen = {}
hl.on("workspace.created", function()
  if not ichi then return end
  for _, ws in ipairs(hl.get_workspaces()) do
    local name = tostring(ws.name)
    if not seen[name] and not ws.special and name:match("^notes") then
      seen[name] = true
      if ichi.entry_for(name) == nil then ichi.enable(name) end
    end
  end
end)
```

`ichi.enable` writes the entry to the config file like the toggle does, so
the workspace stays on after that.

## Configuration

State lives in `~/.config/ichi/ichi.json` (under `$XDG_CONFIG_HOME` when it
is set), plain JSON you can read, edit and keep in your dotfiles. Edits apply
within a second. A malformed entry is
dropped. A file that does not parse at all, say one missing a brace, or that
cannot be read, is left as it is: Ichi keeps the last good settings, tells you
whatever `settings.notify` says, shows it in `ichi status`, and saves nothing
until the file is fixed. A save that fails leaves the file as it was and says
so the same way. Saving replaces the file, so it takes your default
permissions rather than any you set on it.

Before 0.7 the file was `~/.config/omarchy/ichi.json`. One there is still
read and written where it is, never moved, for as long as nothing exists at
the new path. To move it, move the file (or your link to it) to the new path,
then run `hyprctl reload` and `omarchy restart shell`.

```json
{
  "settings": { "step": 5, "fine_step": 1, "notify": "changes", "all_workspaces": false, "max_windows": 1 },
  "defaults": { "width": 70, "height": 80, "max_width": 1800, "align_y": 45 },
  "monitors": {
    "desc:ULTRAGEAR": { "width": 55 },
    "eDP-1": { "width": 95, "height": 95, "max_width": 0 }
  },
  "presets": {
    "reading": { "mode": "size", "width": 55, "height": 85 },
    "wide": { "mode": "size", "width": 90, "height": 90 },
    "home": true
  },
  "workspaces": {
    "1": true,
    "code": { "mode": "aspect", "ratio": [4, 3] },
    "2": { "mode": "size", "width": 70, "height": 80 },
    "5": { "mode": "aspect", "ratio": [4, 3] }
  }
}
```

### settings

- `step` and `fine_step` are the arrow-key increments in percentage points,
  for the plain and the shifted arrows.
- `notify` is how much Ichi says: `never` is silent; `changes`, the default,
  reports everything except resizing step by step (arrow-key nudges and
  `size`); `always` reports those too. The panel labels them *Never*, *All but
  resizing* and *All*.
- `paused` suspends Ichi everywhere. Every workspace goes back to normal gaps
  and keeps its entry, so resuming restores the lot. Meant for screen sharing.
- `all_workspaces` turns every workspace on. A workspace with no entry then
  follows the defaults, and toggling one off writes `false` for it.
- `max_windows` is how many tiled windows may share the box before the inset
  gives way, from 1 to 10.

### defaults

The size of every workspace whose entry is `true`. Change it and they all
follow within a second. Toggling a workspace on writes `true`; the first
arrow-key nudge replaces that with a fixed `size` entry, and `reset` puts
`true` back.

- `max_width` and `max_height` cap the window in pixels, whatever the
  percentage works out to. Omit or set to `0` for no cap.
- `align_x` and `align_y` say where the box sits in the space around it: `0`
  is the left or top edge, `50` the centre, `100` the right or bottom. Normal
  gaps are always kept.

### monitors

Overrides the defaults per display, field by field, for every workspace that
follows them. A key is a connector name such as `eDP-1`, or `desc:` followed
by any part of the description Hyprland reports, which is the form that
survives a dock being replugged. `hyprctl monitors` shows both, and the first
matching block wins. Fixed `size` and `aspect` entries keep their own size but
take the monitor's caps and alignment. `adopt_monitor` writes a block for the
current display from the workspace you have tuned.

### presets

Named entries in any of the three forms below. `cycle` steps a workspace
through them in file order, starting from the first when the workspace is on
none of them, and `preset <name>` jumps to one. Tune a workspace, then
`save_preset <name>` to keep it. There are none until you add some.

### entries

A workspace entry is one of three things:

- `true` follows the defaults.
- `size` is a percentage of the *usable* area — the monitor minus the bar — so
  the proportion holds on any display. Width and height
  are each clamped to 10–100; at 100 the inset is exactly your normal gaps.
- `aspect` is the largest box of that ratio, centred.

`false` opts a workspace out, which only matters when `all_workspaces` is on.

Workspaces are keyed by name. Hyprland names a numeric workspace by its
number, so `"2"` means workspace 2 and a config written before 0.4 keeps
working untouched. A named workspace uses its name, `"code"` or `"mail"`.
Its numeric id is a negative placeholder that says nothing about which
workspace it is, so the name is the only stable way to refer to one.
Renaming a workspace therefore leaves its entry under the old name, where it
applies again if a workspace of that name comes back.

## Stability

From 1.0, Ichi follows semantic versioning, and a breaking change to any of
these waits for a major release:

- the commands on this page, their arguments, and what they print, except
  `status`
- the Lua functions listed under [From Lua](#from-lua)
- the keys of the config file and what they mean
- the document `status_json` prints

`status` is written for a person to read and may change in any release.
Anything else on the `ichi` table is internal. Before 1.0 a minor release may
still change the list above, and says so in the changelog.

## Omarchy menu

Add to `~/.config/omarchy/extensions/omarchy-menu.jsonc` for an entry under
**Toggle** with a checkmark when the current workspace is on:

```jsonc
"trigger.toggle.ichi": {
  "icon": "",
  "label": "Ichi",
  "description": "Inset the lone window on this workspace",
  "checked": "[ \"$(omarchy-shell io.github.aesko.ichi enabled)\" = true ]",
  "action": "omarchy-shell io.github.aesko.ichi toggle"
},
```

For the rest, a submenu of its own on the root menu. The rows that act on a
workspace only appear while that workspace is on:

```jsonc
"ichi": {
  "icon": "",
  "label": "Ichi",
  "description": "Size the lone window on this workspace"
},
"ichi.cycle": {
  "icon": "",
  "label": "Next preset",
  "description": "Step through your saved sizes",
  "when": "[ \"$(omarchy-shell io.github.aesko.ichi enabled)\" = true ]",
  "action": "omarchy-shell io.github.aesko.ichi cycle"
},
"ichi.adopt": {
  "icon": "",
  "label": "Adopt as default",
  "description": "Make this workspace's size the default everywhere",
  "when": "[ \"$(omarchy-shell io.github.aesko.ichi enabled)\" = true ]",
  "action": "omarchy-shell io.github.aesko.ichi adopt"
},
"ichi.adopt-monitor": {
  "icon": "",
  "label": "Adopt on monitor",
  "description": "Make this workspace's size the default on this display only",
  "when": "[ \"$(omarchy-shell io.github.aesko.ichi enabled)\" = true ]",
  "action": "omarchy-shell io.github.aesko.ichi adopt_monitor"
},
"ichi.reset": {
  "icon": "",
  "label": "Reset to default",
  "description": "Follow the defaults again",
  "when": "[ \"$(omarchy-shell io.github.aesko.ichi enabled)\" = true ]",
  "action": "omarchy-shell io.github.aesko.ichi reset"
},
"ichi.pause": {
  "icon": "",
  "label": "Pause everywhere",
  "description": "Suspend every inset without changing a single workspace",
  "checked": "[ \"$(omarchy-shell io.github.aesko.ichi paused)\" = true ]",
  "action": "omarchy-shell io.github.aesko.ichi pause_toggle"
},
```

The icons are Nerd Font glyphs; change them to taste.

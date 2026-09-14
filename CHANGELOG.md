# Changelog

## 0.7.0 — unreleased

The release before 1.0. Nothing new to do; fewer ways to do it, one place
for settings, and a state file that cannot be left half-written.

### Added

- **`ichi set <key> <value>`**, one command for every setting, named by its
  place in the file: `ichi set settings.step 10`, `ichi set defaults.width
  65`. An unknown key is refused with the list of keys, and a value that does
  not fit says what the setting takes. From Lua, `ichi.set(key, value)`.
- **What 1.0 will keep stable**, written down in `docs/reference.md`: the
  commands, the Lua functions, the config keys and `status_json`, but not
  `status`.
- An example in the reference of building on Ichi from your own config with
  `hl.on`.
- CI runs the test suites on every push.

### Changed

- **The state file moves to `~/.config/ichi/ichi.json`.** An existing
  `~/.config/omarchy/ichi.json` is read and written where it is, never moved,
  for as long as nothing exists at the new path.
- **The smallest size is fixed at 10%**, for width and height alike, instead
  of the `min_percent` setting's 20.
- **Saves replace the file whole**: a sibling is written and renamed over it,
  so a crash mid-save leaves the previous file, and a save that fails leaves
  it as it was and says so, whatever `settings.notify` says. Through a link,
  the file it points to is replaced and the link kept. The file takes your
  default permissions. Saving no longer starts a shell inside Hyprland each
  time.

### Deprecated

- The commands `adjust`, `defaults`, `max`, `align`, `step`, `fine_step`,
  `windows`, `all`, `notify` and `min`, and the Lua `adjust` and `set_*`
  functions `set` replaces. They keep working through 0.7, print what replaces
  them, and go in 1.0. `min` already does nothing.

### Removed

- `settings.min_percent`.
- Importing the plugin's state files from before its rename.
- Reading `step` from the `defaults` block, where it lived before 0.2, and
  keeping `defaults.step` as a copy of `settings.step`. A binding that reads
  `ichi.config.defaults.step` should read `ichi.config.settings.step`.

### Fixed

- `adopt` on a named workspace that is off, already follows the defaults or
  holds an aspect ratio explained nothing and failed instead.
- A state file that does not parse, or cannot be read, is never saved over.
  Ichi keeps the last good settings, says so whatever `settings.notify` says,
  shows it in `ichi status`, and saves nothing until the file is fixed. A file
  cut short had lost every workspace the missing half held on the next change.
- **`hyprland.lua` is replaced, not rewritten in place.** The loader install
  wrote into the file directly: it opened with `O_TRUNC` and only then wrote,
  so anything that went wrong in between — a full disk, a killed process, a
  short write whose return value was never checked — left an empty or
  half-written config behind, and the plugin still reported success. The new
  text now goes to a temporary file in the same directory and is renamed over
  the target, so a failure anywhere leaves the file exactly as it was. A
  dotfiles symlink still survives the edit, because the rename lands on the
  file the symlink resolves to, not on the link. A hard link to the same file
  does not, which is the one behaviour this changes.
- **The no-`python3` fallback is gone, along with the race it carried.** It
  re-tested `-L` and then wrote through `>`, which follows a symlink swapped
  in after the test — the same check-then-follow gap the rest of the script
  exists to close. `rename(2)` does not follow a symlink at its destination,
  so the ownership checks no longer hand off to a weaker write at the last
  step, and the install no longer behaves differently depending on whether
  `python3` happens to be installed.
- **A workspace name can no longer break `ichi.json`.** Preset names and
  monitor descriptions had the two characters that end a JSON string taken out
  of them, but a workspace key is the live workspace's name and was written
  raw. A workspace called `say "hi"` — or one with a backslash or a newline in
  its name — produced a document that is not valid JSON, at which point the
  shell side keeps the last good file and the widget stops following along,
  which does not look like a naming problem at all. Every string the state file
  writes is now escaped. An escaped key still will not match its workspace
  again after a reload, because the Lua reader matches keys with a plain
  pattern, so Ichi now says that once instead of letting the setting quietly
  fail to return.

### Security

- **The config no longer travels through `argv`.** The whole of
  `hyprland.lua` was passed to the install script as a command-line argument,
  and `/proc/<pid>/cmdline` is readable by every local account — including the
  one the script's ownership checks are written to defend against. It now
  arrives in `ICHI_LOADER_CONTENT`, and `/proc/<pid>/environ` is readable only
  by its owner.

### Migration

- Nothing to do for a 0.6 config, which stays where it is.
- If you had set `min_percent` below 10, a size under 10% is shown at 10% at
  once and written that way on the next change.
- Scripts and menu entries calling a deprecated command keep working; switch
  them to `set` before 1.0.
- After `omarchy plugin update`, run `omarchy restart shell` and
  `hyprctl reload`.

## 0.6.0 — 2026-09-12

The panel gains the one shape it could never set, and a back side holding the
widget's own settings and your keybindings.

### Added

- **Aspect ratios in the panel.** A row of chips under the sizes — 16:9,
  16:10, 3:2, 4:3 and 1:1. Picking one switches the workspace to that shape,
  which is why the sliders stand down for it; `default` or a preset brings
  them back. Any other ratio is still `ichi aspect 21 9`. This was the last
  thing the panel could read and not write.
- **A settings page behind the cog.** The card turns over to two short
  sections. *Bar widget* holds what it shows in the bar and what left click
  does; these write the same `shell.json`
  entry Omarchy's bar settings writes, leaving out any key at its manifest
  default. **Hidden** is deliberately not offered there — choosing it would
  take away the panel it was chosen from. *Behaviour* holds notifications and the
  resize step and fine step, which are Ichi's own settings in `ichi.json` and
  work with or without the widget.
- **Your Ichi keybindings, on the same page**, read from `hyprctl binds`. A
  bind is Ichi's when its description starts with `Ichi:`, which is how the
  README's suggested set is written. That prefix is the only link there is: a
  Lua bind reports an opaque `__lua` dispatcher, so a bind described any other
  way works perfectly well and simply is not listed. Four arrows under the
  same modifiers, described alike but for the direction, are one *resize* row
  rather than four.

### Changed

- Picking an aspect ratio from the panel raises no notification, matching
  every other panel action.
- **The README's arrow bindings are described by what they do** — *narrower*,
  *wider*, *taller*, *shorter* — rather than *nudge left* and so on, which
  named the key. Existing descriptions keep working, and fold into the same
  *resize* rows.

### Removed

- The *Scroll wheel* bar setting, tried out and judged not worth keeping; Ichi
  is meant to be driven from the keyboard.

### Security

- **The `hyprland.lua` loader line is now installed through an ownership
  check, not an unconditional in-place write.** `hyprland.lua` is often a
  symlink into a dotfiles repo, which Ichi has always followed on purpose —
  but nothing previously checked *who* that symlink, or the directories
  above it, belonged to. Installation now resolves the whole chain up to
  your home directory and refuses to write unless every step of it is
  yours, the same ancestor check sshd applies to `~/.ssh`. A setup this
  rules out (a Nix or home-manager–managed `hyprland.lua`, most commonly,
  since it resolves outside your home directory) gets a notification
  instead of a silent write; see the README's Install section for the
  manual line and `ichi sync`.

## 0.5.0 — 2026-09-12

Ichi runs on plain Hyprland, `status` is written for a person to read, and the
README is a front door rather than a manual.

### Added

- **`ichi.lua` runs without Omarchy.** It was already the whole behaviour and
  needed nothing but Hyprland's Lua config API, except for one call:
  notifications went to `omarchy-notification-send` unconditionally, which is
  silence on a plain Hyprland session. It falls back to `notify-send`. The
  README carries the `dofile` line to add yourself, the `hl.bind` form of the
  suggested keybindings, and what stays behind on Omarchy — the bar widget,
  the menu entries and the `omarchy-shell ichi` commands.
- **`status_json`**, the JSON document `status` used to print.
- `ichi.config_path` is documented as the way to move the state file off
  `~/.config/omarchy/`, for a session that has no such directory.
- A prior art section in the README, crediting Hyprland's own
  `single_window_aspect_ratio`, hyprNStack and pyprland.
- `docs/reference.md`: every command, the Lua functions, every config key and
  the Omarchy menu entries.

### Changed

- **`status` prints plain text rather than JSON.** A short labelled block —
  the workspace, its inset, the defaults and any setting not at its stock
  value — with rows left out when they carry nothing. This breaks anything
  parsing the old output; use `status_json`, which is the same document
  unchanged. Nothing in Ichi itself read it: the menu rows use `enabled` and
  `paused`, and the panel reads the service directly.
- **Ichi is described as a Hyprland plugin with an Omarchy half**, not an
  Omarchy plugin, in the README's opening and its requirements. The core runs
  anywhere Hyprland 0.55 does.
- The README is about 60% less prose. Design rationale is gone rather than
  moved — it lives in the commits that made each decision — and the reference
  material moved to `docs/reference.md`.

## 0.4.0 — 2026-09-11

A bar widget, workspaces by name, and a way to stand Ichi down for a while.

### Added

- **An optional bar widget.** One glyph, dimmed where Ichi is off. Left click
  opens a panel, right click toggles this workspace, matching Omarchy's own
  audio, bluetooth and power widgets. The panel holds the on/off switch, a row
  of sizes with the defaults first and your presets after, width and height as
  both a typed field and a slider, adopt, and the global pause. `+` saves the
  current size as a preset; right-clicking one removes it. Scrolling does
  nothing unless you turn it on. Nothing done from the panel raises a
  notification, since it shows its own result in the corner the notifications
  would cover. The controls stay live on a workspace where Ichi is off,
  showing what it would get; touching one turns it on, the same way nudging
  with the arrow keys always has.
- **Named workspaces.** Keys are workspace names now, so `"code"` works
  alongside `"2"`. Hyprland gives a named workspace a negative placeholder id
  that identifies nothing, so the name was always the only stable handle.
- **`settings.paused`**, suspending Ichi everywhere without touching a single
  workspace entry, for screen sharing or a presentation. `pause on|off`,
  `pause_toggle`, `paused`, and a menu row with a checkmark.
- `ichi.set_size(w, h)` and the `size` command, an absolute size rather than a
  delta, which is what a slider needs.
- `status.resolved`, the size a workspace has or would have if switched on.
- `omarchy-shell ichi.panel toggle`, so the panel can be opened from a key.

### Changed

- **`settings.notify` defaults to `changes` rather than `always`.** Arrow-key
  nudges no longer announce themselves. Existing config files keep whatever
  they already say.
- Menu and panel labels name their effect: **Adopt as default** and **Reset to
  default**. "Adopt everywhere" suggested it applied the size to every
  workspace, when it changes the defaults, which only reach workspaces that
  follow them.

### Fixed

- A warning 0.3.0 shipped on every shell start: Quickshell exposes every
  property declared on an `IpcHandler` over IPC and could not serialise ours.

### Breaking

- **`ichi status` reports `workspace` and `workspaces` as strings, not
  numbers**, because workspace keys are names and a numeric workspace's name is
  its number. Anything parsing that JSON needs updating; `"2"` where `2` used
  to be.

### Migration

- **Your config file needs nothing.** A 0.3 file loads with every workspace,
  monitor block and preset intact, numeric keys included.
- **The bar widget will not appear on an existing install.** Ichi was
  service-only before, so your config already lists it as enabled and Omarchy
  sees nothing to place. Disable and enable it once:

  ```bash
  omarchy plugin disable io.github.aesko.ichi
  omarchy plugin enable io.github.aesko.ichi --section right
  ```

  A fresh install is asked which section to use and needs none of this. If you
  would rather not have the widget at all, set its **Show in the bar** setting
  to *Hidden*.
- After `omarchy plugin update`, run `omarchy restart shell` and
  `hyprctl reload` so both halves pick up the new code. For about a second
  after a shell restart the compositor has not told Quickshell which
  workspace is focused, so `ichi status` reports `"workspace": null` and the
  widget sits dimmed. It corrects itself; Omarchy's own workspace indicator
  is blank for the same moment.

## 0.3.0 — 2026-09-08

Shorter to drive, and a group counts as one window.

### Added

- **A short `ichi` IPC target** beside the plugin id, so
  `omarchy-shell ichi cycle` works. Both names are the same surface; scripts
  written against either keep working. Config that outlives a session, like
  the menu entries, still uses the id, which cannot collide.
- **Menu entries.** The snippet in the README grows an Ichi submenu with Next
  preset, Adopt this size, Adopt for this monitor and Reset, each hidden while
  the workspace is off.
- **An adopt keybinding**, `SUPER+CTRL+ALT+A` in the suggested set, which pairs
  with the arrows: tune a workspace, then press once.

### Changed

- `adopt` and `adopt_monitor` say why they cannot act instead of doing nothing
  silently, which mattered once they had a key and a menu row. A workspace that
  is off, follows the defaults, or holds an aspect ratio each get their own
  message.

### Fixed

- **A tabbed group now counts as one window** ([#1](https://github.com/aesko/omarchy-ichi/issues/1), reported by
  @coffedahl). A Hyprland group occupies one tile however many windows it
  holds, but each member was counted, so a workspace showing a single group
  exceeded `max_windows` and got no inset. Two groups still count as two, and
  `max_windows` 2 admits a group beside a loose window.

### Docs

- An animated demo at the top of the README, generated by `gen_demo.py` into a
  light and a dark SVG. The logo now switches with the reader's theme too;
  `logo-dark.svg` had been in the repo since 0.1.0 with nothing referencing it.

### Migration

- Nothing to do. No config or state file changes in this release.
- After `omarchy plugin update`, run `omarchy restart shell` and
  `hyprctl reload` so both halves pick up the new code.

## 0.2.0 — 2026-09-07

Settings for a wider range of setups. Every addition is optional; a 0.1.0
settings file is read as it is and rewritten in the new form on the next
change.

### Added

- **`settings` block** with `notify` (`never`, `changes`, `always`) to choose
  how much Ichi says, `fine_step` for a second, finer arrow-key increment,
  `all_workspaces` to inset every workspace unless it opts out with `false`,
  `max_windows` to let a few tiled windows share the box, and `min_percent`
  as the smallest share a size may be (default 20, was a fixed 30).
- **Entries that follow the defaults.** A workspace entry of `true` means on,
  at whatever the defaults say. Toggling on and `reset` write it, the first
  nudge replaces it with a fixed size, and `adopt` puts the workspace back on
  it after copying its size out. Changing the defaults now reaches those
  workspaces at once.
- **Pixel caps.** `defaults.max_width` and `max_height` cap the box in
  pixels, whatever the percentage works out to.
- **Alignment.** `defaults.align_x` and `align_y`, 0 to 100 with 50 as the
  centre, say where the box sits in the space around it.
- **Per-monitor overrides.** A `monitors` block keyed by connector name or
  `desc:` plus part of the description, overriding width, height, caps and
  alignment for workspaces that follow the defaults. `adopt_monitor` writes
  one from a tuned workspace.
- **Presets.** A `presets` block of named entries, with `preset <name>`,
  `cycle`, `save_preset <name>` and `remove_preset <name>`.
- **`ichi.nudge(dx, dy, fine)`** for bindings, taking directions instead of
  step sizes. The suggested bindings now use it with `repeating = true`, so
  holding an arrow keeps nudging, plus a SHIFT variant for the fine step.
- New commands: `nudge`, `notify`, `all`, `windows`, `min`, `max`, `align`,
  `preset`, `cycle`, `cycle_back`, `save_preset`, `remove_preset`, `adopt_monitor`,
  `nudge_fine` and `fine_step`.
- Refresh on `workspace.created`, `workspace.move_to_monitor`,
  `monitor.added` and `monitor.removed`.

### Changed

- `step` lives under `settings`. The old `defaults.step` is still read, and
  `ichi.config.defaults.step` is kept in sync for bindings written against
  0.1.0.
- Sizes are clamped to `min_percent`–100 instead of 30–100.

### Migration

- Nothing to do. Existing fixed `size` and `aspect` entries are untouched;
  `reset` a workspace if you want it to follow the defaults instead.
- After `omarchy plugin update`, run `omarchy restart shell` and
  `hyprctl reload` so both halves pick up the new code.
- Going back to 0.1.0 after the file has been rewritten drops `true` and
  `false` entries, the `monitors` and `presets` blocks, and every new
  setting, since the 0.1.0 parser does not know them.

## 0.1.0 — 2026-09-06

First release under the name Ichi: per-workspace inset for the lone window,
size and aspect modes, live nudging, a plain JSON state file, and yielding to
plugin-registered layouts.

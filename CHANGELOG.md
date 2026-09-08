# Changelog

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

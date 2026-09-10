import Quickshell.Io

// Ichi's IPC surface, instantiated once per target name by Service.qml so
// `ichi` and the reverse-DNS id expose exactly the same commands. Every
// function here is a one-line forward to its cmd* twin on the service, which
// is where the behaviour lives.
//
// Two constraints shape this file. The IPC layer requires every declared
// argument, so a command with an optional argument is two functions here
// (adopt and adopt_monitor, cycle and cycle_back, step and fine_step, nudge
// and nudge_fine). And arguments arrive as strings, so the cmd* side coerces.
IpcHandler {
  id: handler

  // The Service.qml root. Required, so a missing wiring fails loudly at load
  // rather than silently answering nothing over IPC.
  required property var api

  function status(): string {
    return handler.api.cmdStatus()
  }

  // "true" or "false" for the focused workspace; drives the menu checkmark.
  function enabled(): string {
    return handler.api.cmdEnabled()
  }

  function toggle(): string {
    return handler.api.cmdToggle()
  }

  function reset(): void {
    handler.api.cmdReset()
  }

  // Percentage-point deltas for width and height, e.g. adjust 5 0.
  function adjust(width: string, height: string): void {
    handler.api.cmdAdjust(width, height)
  }

  // Switch the focused workspace to aspect mode, e.g. aspect 4 3.
  function aspect(width: string, height: string): void {
    handler.api.cmdAspect(width, height)
  }

  // What a workspace that follows the defaults gets, e.g. defaults 65 85.
  function defaults(width: string, height: string): void {
    handler.api.cmdDefaults(width, height)
  }

  // Pixel caps on the box, e.g. max 1800 0; zero is none.
  function max(width: string, height: string): void {
    handler.api.cmdMax(width, height)
  }

  // Where the box sits, 0-100 across and down; e.g. align 50 40.
  function align(x: string, y: string): void {
    handler.api.cmdAlign(x, y)
  }

  // Arrow-key increment in percentage points, e.g. step 10.
  function step(points: string): void {
    handler.api.cmdStep(points)
  }

  // The shifted arrows' increment, e.g. fine_step 2.
  function fine_step(points: string): void {
    handler.api.cmdFineStep(points)
  }

  // Directions as -1, 0 or 1, scaled by the step; e.g. nudge -1 0.
  function nudge(width: string, height: string): void {
    handler.api.cmdNudge(width, height, false)
  }

  // The same, scaled by the fine step.
  function nudge_fine(width: string, height: string): void {
    handler.api.cmdNudge(width, height, true)
  }

  // The smallest share of the screen a size may be, e.g. min 10.
  function min(percent: string): void {
    handler.api.cmdMin(percent)
  }

  // How many tiled windows may share the box, e.g. windows 2.
  function windows(count: string): void {
    handler.api.cmdWindows(count)
  }

  // Suspend Ichi everywhere: pause on | off. Entries are left alone, so
  // resuming restores every inset.
  function pause(state: string): void {
    handler.api.cmdPause(state)
  }

  function pause_toggle(): void {
    handler.api.cmdPauseToggle()
  }

  // "true" or "false"; drives the menu checkmark.
  function paused(): string {
    return handler.api.cmdPaused()
  }

  // Every workspace on unless it opts out: all on | off.
  function all(state: string): void {
    handler.api.cmdAll(state)
  }

  // How chatty to be: never, changes or always.
  function notify(level: string): void {
    handler.api.cmdNotify(level)
  }

  // Give the focused workspace a preset by name.
  function preset(name: string): void {
    handler.api.cmdPreset(name)
  }

  function cycle(): void {
    handler.api.cmdCycle(1)
  }

  function cycle_back(): void {
    handler.api.cmdCycle(-1)
  }

  // Keep the focused workspace's current size as a named preset.
  function save_preset(name: string): void {
    handler.api.cmdSavePreset(name)
  }

  function remove_preset(name: string): void {
    handler.api.cmdRemovePreset(name)
  }

  // Adopt the focused workspace's current size as the default.
  function adopt(): void {
    handler.api.cmdAdopt("")
  }

  // The same, but as the default for the focused workspace's monitor only.
  function adopt_monitor(): void {
    handler.api.cmdAdopt("monitor")
  }

  function refresh(): void {
    handler.api.cmdRefresh()
  }

  // Re-checks hyprland.lua and installs the loader line if it is missing.
  function sync(): void {
    handler.api.cmdSync()
  }
}

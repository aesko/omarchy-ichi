import QtQuick
import Quickshell.Io

// Ichi's IPC surface, instantiated once per target name by Service.qml so
// `ichi` and the reverse-DNS id expose exactly the same commands. Every
// function here is a one-line forward to its cmd* twin on the service, which
// is where the behaviour lives.
//
// The handler is wrapped rather than being the root, because Quickshell tries
// to expose every property declared on an IpcHandler over IPC and warns about
// any it cannot serialise. Keeping `api` on the wrapper leaves the handler
// holding nothing but functions.
//
// Two constraints shape the functions. The IPC layer requires every declared
// argument, so a command with an optional argument is two functions here
// (adopt and adopt_monitor, cycle and cycle_back, step and fine_step, nudge
// and nudge_fine). And arguments arrive as strings, so the cmd* side coerces.
Item {
  id: wrapper

  // The Service.qml root. Required, so a missing wiring fails loudly at load
  // rather than silently answering nothing over IPC.
  required property QtObject api

  // Written by Service.qml as `IchiIpc { target: "ichi" }`.
  property alias target: handler.target

  IpcHandler {
    id: handler

    function help(): string {
      return wrapper.api.cmdHelp()
    }

    function status(): string {
      return wrapper.api.cmdStatus()
    }

    // The same state as a JSON document, for anything parsing it.
    function status_json(): string {
      return wrapper.api.cmdStatusJson()
    }

    // "true" or "false" for the focused workspace; drives the menu checkmark.
    function enabled(): string {
      return wrapper.api.cmdEnabled()
    }

    function toggle(): string {
      return wrapper.api.cmdToggle()
    }

    function reset(): void {
      wrapper.api.cmdReset()
    }

    // One setting by its place in the file, e.g. set settings.step 10 or
    // set defaults.width 65. Prints why when there is no such setting.
    function set(key: string, value: string): string {
      return wrapper.api.cmdSet(key, value)
    }

    // Deprecated: nudge or size. Goes in 1.0.
    function adjust(width: string, height: string): string {
      return wrapper.api.cmdAdjust(width, height)
    }

    // Switch the focused workspace to aspect mode, e.g. aspect 4 3.
    function aspect(width: string, height: string): void {
      wrapper.api.cmdAspect(width, height)
    }

    // Deprecated: set defaults.width and defaults.height. Goes in 1.0.
    function defaults(width: string, height: string): string {
      return wrapper.api.cmdDefaults(width, height)
    }

    // Deprecated: set defaults.max_width and defaults.max_height. Goes in 1.0.
    function max(width: string, height: string): string {
      return wrapper.api.cmdMax(width, height)
    }

    // Deprecated: set defaults.align_x and defaults.align_y. Goes in 1.0.
    function align(x: string, y: string): string {
      return wrapper.api.cmdAlign(x, y)
    }

    // Deprecated: set settings.step. Goes in 1.0.
    function step(points: string): string {
      return wrapper.api.cmdStep(points)
    }

    // Deprecated: set settings.fine_step. Goes in 1.0.
    function fine_step(points: string): string {
      return wrapper.api.cmdFineStep(points)
    }

    // An absolute size for the focused workspace, e.g. size 65 85.
    function size(width: string, height: string): void {
      wrapper.api.cmdSize(width, height)
    }

    // Directions as -1, 0 or 1, scaled by the step; e.g. nudge -1 0.
    function nudge(width: string, height: string): void {
      wrapper.api.cmdNudge(width, height, false)
    }

    // The same, scaled by the fine step.
    function nudge_fine(width: string, height: string): void {
      wrapper.api.cmdNudge(width, height, true)
    }

    // Deprecated, and does nothing: the smallest size is fixed. Goes in 1.0.
    function min(percent: string): string {
      return wrapper.api.cmdMin(percent)
    }

    // Deprecated: set settings.max_windows. Goes in 1.0.
    function windows(count: string): string {
      return wrapper.api.cmdWindows(count)
    }

    // Suspend Ichi everywhere: pause on | off. Entries are left alone, so
    // resuming restores every inset.
    function pause(state: string): void {
      wrapper.api.cmdPause(state)
    }

    function pause_toggle(): void {
      wrapper.api.cmdPauseToggle()
    }

    // "true" or "false"; drives the menu checkmark.
    function paused(): string {
      return wrapper.api.cmdPaused()
    }

    // Deprecated: set settings.all_workspaces. Goes in 1.0.
    function all(state: string): string {
      return wrapper.api.cmdAll(state)
    }

    // Deprecated: set settings.notify. Goes in 1.0.
    function notify(level: string): string {
      return wrapper.api.cmdNotify(level)
    }

    // Give the focused workspace a preset by name.
    function preset(name: string): void {
      wrapper.api.cmdPreset(name)
    }

    function cycle(): void {
      wrapper.api.cmdCycle(1)
    }

    function cycle_back(): void {
      wrapper.api.cmdCycle(-1)
    }

    // Keep the focused workspace's current size as a named preset.
    function save_preset(name: string): void {
      wrapper.api.cmdSavePreset(name)
    }

    function remove_preset(name: string): void {
      wrapper.api.cmdRemovePreset(name)
    }

    // Adopt the focused workspace's current size as the default.
    function adopt(): void {
      wrapper.api.cmdAdopt("")
    }

    // The same, but as the default for the focused workspace's monitor only.
    function adopt_monitor(): void {
      wrapper.api.cmdAdopt("monitor")
    }

    function refresh(): void {
      wrapper.api.cmdRefresh()
    }

    // Re-checks hyprland.lua and installs the loader line if it is missing.
    function sync(): void {
      wrapper.api.cmdSync()
    }
  }
}

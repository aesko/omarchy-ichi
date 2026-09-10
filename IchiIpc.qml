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

    function status(): string {
      return wrapper.api.cmdStatus()
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

    // Percentage-point deltas for width and height, e.g. adjust 5 0.
    function adjust(width: string, height: string): void {
      wrapper.api.cmdAdjust(width, height)
    }

    // Switch the focused workspace to aspect mode, e.g. aspect 4 3.
    function aspect(width: string, height: string): void {
      wrapper.api.cmdAspect(width, height)
    }

    // What a workspace that follows the defaults gets, e.g. defaults 65 85.
    function defaults(width: string, height: string): void {
      wrapper.api.cmdDefaults(width, height)
    }

    // Pixel caps on the box, e.g. max 1800 0; zero is none.
    function max(width: string, height: string): void {
      wrapper.api.cmdMax(width, height)
    }

    // Where the box sits, 0-100 across and down; e.g. align 50 40.
    function align(x: string, y: string): void {
      wrapper.api.cmdAlign(x, y)
    }

    // Arrow-key increment in percentage points, e.g. step 10.
    function step(points: string): void {
      wrapper.api.cmdStep(points)
    }

    // The shifted arrows' increment, e.g. fine_step 2.
    function fine_step(points: string): void {
      wrapper.api.cmdFineStep(points)
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

    // The smallest share of the screen a size may be, e.g. min 10.
    function min(percent: string): void {
      wrapper.api.cmdMin(percent)
    }

    // How many tiled windows may share the box, e.g. windows 2.
    function windows(count: string): void {
      wrapper.api.cmdWindows(count)
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

    // Every workspace on unless it opts out: all on | off.
    function all(state: string): void {
      wrapper.api.cmdAll(state)
    }

    // How chatty to be: never, changes or always.
    function notify(level: string): void {
      wrapper.api.cmdNotify(level)
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

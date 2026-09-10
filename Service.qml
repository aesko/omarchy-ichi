import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Model.js" as Model

// The shell side of Ichi. Thin by design: ichi.lua owns the
// behaviour and is the only writer of the state file. This service installs
// the loader line into hyprland.lua, mirrors the state file for the menu and
// a future bar widget, and turns IPC calls into `hyprctl eval`.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null

  readonly property string pluginId: "io.github.aesko.ichi"
  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
  readonly property string hyprlandLuaPath: configDir + "/hypr/hyprland.lua"
  readonly property string statePath: configDir + "/omarchy/ichi.json"

  property var config: Model.defaultConfig()
  property bool loaderInstalled: false
  property string lastError: ""

  // The focused workspace's name, which is the key the config uses. A numeric
  // workspace is named by its number, and a named one has no useful id.
  readonly property var activeWorkspaceId: Hyprland.focusedWorkspace
    ? String(Hyprland.focusedWorkspace.name !== undefined && Hyprland.focusedWorkspace.name !== null
      ? Hyprland.focusedWorkspace.name : Hyprland.focusedWorkspace.id)
    : null
  readonly property var activeMonitor: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.monitor
    ? { name: Hyprland.focusedWorkspace.monitor.name, description: Hyprland.focusedWorkspace.monitor.description }
    : null
  readonly property var status: Model.status(config, activeWorkspaceId, activeMonitor)
  readonly property bool enabled: status.enabled

  // ------------------------------------------------------------- eval --
  //
  // Queued in order, not latest-wins: a toggle followed by a nudge are two
  // different user actions and dropping either one would be visible.

  property var queue: []

  function evaluate(lua) {
    queue = queue.concat([lua])
    if (!evalProcess.running) flush()
  }

  function flush() {
    if (queue.length === 0) return
    var next = queue[0]
    queue = queue.slice(1)
    evalProcess.command = Model.hyprctlEvalArgs(next)
    evalProcess.running = true
  }

  Process {
    id: evalProcess
    stderr: StdioCollector {
      onStreamFinished: {
        var message = String(text || "").trim()
        // "ok" is hyprctl's success reply; anything else is worth surfacing.
        root.lastError = (message.length > 0 && message !== "ok") ? message : ""
        if (root.lastError !== "") console.warn("ichi:", root.lastError)
      }
    }
    onExited: root.flush()
  }

  // ------------------------------------------------------------ state --
  //
  // Written by ichi.lua, read here. A hand-edit arrives on the same path,
  // so Hyprland is asked to re-read after every change; its own writes come
  // back through here too, which costs one idempotent refresh.

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false

    onLoaded: {
      var parsed = Model.parseConfig(text())
      if (parsed) {
        root.config = parsed
      } else {
        console.warn("ichi: state file is not valid JSON, keeping the last good document")
      }
    }

    onLoadFailed: root.config = Model.defaultConfig()

    // text() is stale inside the change signal, so re-read and let onLoaded
    // parse fresh content.
    onFileChanged: {
      reload()
      root.evaluate("if ichi then ichi.load(); ichi.refresh() end")
    }
  }

  // ----------------------------------------------------------- loader --
  //
  // Hyprland only reads what its config asks for, so ichi.lua needs one
  // `dofile` line in hyprland.lua. It is guarded by an existence check, so
  // removing the plugin can never break the config. Written in place rather
  // than atomically: hyprland.lua is often a symlink into a dotfiles repo, and
  // a rename-over would silently replace the link with a plain file.

  FileView {
    id: hyprlandLuaFile
    path: root.hyprlandLuaPath
    atomicWrites: false
    watchChanges: false
    printErrors: false

    onLoaded: {
      var current = text()
      if (Model.needsLoader(current)) {
        setText(Model.withLoader(current))
        // The one edit Ichi ever makes to a user file; say so when it happens.
        notifyProcess.running = true
      }
      root.loaderInstalled = true
    }

    onLoadFailed: {
      // No hyprland.lua means this is not an Omarchy Hyprland session; leave it
      // alone rather than creating a config file out of nowhere.
      root.loaderInstalled = false
    }
  }

  Process {
    id: notifyProcess
    command: ["omarchy-notification-send", "-u", "low",
      "Ichi added one guarded line to ~/.config/hypr/hyprland.lua so Hyprland loads it. Remove it any time; it is harmless without the plugin."]
  }

  // --------------------------------------------------------- commands --
  //
  // One implementation per command. Every IPC target forwards here, so the
  // short name and the reverse-DNS id cannot drift apart.

  function cmdStatus() {
    return JSON.stringify(root.status)
  }

  // "true" or "false" for the focused workspace; drives the menu checkmark.
  function cmdEnabled() {
    return root.enabled ? "true" : "false"
  }

  function cmdToggle() {
    root.evaluate("if ichi then ichi.toggle() end")
    return root.enabled ? "disabling" : "enabling"
  }

  // "Follow the defaults", which on a workspace that is off means turning it
  // on that way. enable() with no entry writes exactly that.
  function cmdUseDefaults() {
    root.evaluate("if ichi then ichi.enable() end")
  }

  function cmdReset() {
    root.evaluate("if ichi then ichi.reset() end")
  }

  // Percentage-point deltas for width and height, e.g. adjust 5 0.
  function cmdAdjust(width, height) {
    root.evaluate("if ichi then ichi.adjust(" + (Number(width) || 0) + ", " + (Number(height) || 0) + ") end")
  }

  // Switch the focused workspace to aspect mode, e.g. aspect 4 3.
  function cmdAspect(width, height) {
    var rw = Number(width) || 0
    var rh = Number(height) || 0
    if (rw <= 0 || rh <= 0) return
    root.evaluate("if ichi then ichi.set_aspect(" + rw + ", " + rh + ") end")
  }

  // What a workspace that follows the defaults gets, e.g. defaults 65 85.
  function cmdDefaults(width, height) {
    root.evaluate("if ichi then ichi.set_defaults(" + (Number(width) || 0) + ", " + (Number(height) || 0) + ", 0) end")
  }

  // Pixel caps on the box, e.g. max 1800 0; zero is none.
  function cmdMax(width, height) {
    root.evaluate("if ichi then ichi.set_max(" + (Number(width) || 0) + ", " + (Number(height) || 0) + ") end")
  }

  // Where the box sits, 0-100 across and down; e.g. align 50 40 for a
  // little above centre.
  function cmdAlign(x, y) {
    root.evaluate("if ichi then ichi.set_align(" + (Number(x) || 0) + ", " + (Number(y) || 0) + ") end")
  }

  // Arrow-key increment in percentage points, e.g. step 10.
  function cmdStep(points) {
    root.evaluate("if ichi then ichi.set_step(" + (Number(points) || 0) + ", 0) end")
  }

  // The shifted arrows' increment, e.g. fine_step 2.
  function cmdFineStep(points) {
    root.evaluate("if ichi then ichi.set_step(0, " + (Number(points) || 0) + ") end")
  }

  // An absolute size for the focused workspace, which is what a slider has.
  function cmdSize(width, height) {
    root.evaluate("if ichi then ichi.set_size(" + (Number(width) || 0) + ", " + (Number(height) || 0) + ") end")
  }

  // Directions as -1, 0 or 1, scaled by the step or the fine step.
  function cmdNudge(width, height, fine) {
    root.evaluate("if ichi then ichi.nudge(" + (Number(width) || 0) + ", " + (Number(height) || 0) + ", " + (fine === true) + ") end")
  }

  // The smallest share of the screen a size may be, e.g. min 10.
  function cmdMin(percent) {
    root.evaluate("if ichi then ichi.set_min_percent(" + (Number(percent) || 20) + ") end")
  }

  // How many tiled windows may share the box, e.g. windows 2.
  function cmdWindows(count) {
    root.evaluate("if ichi then ichi.set_max_windows(" + (Number(count) || 1) + ") end")
  }

  // Suspend Ichi everywhere without changing any workspace entry.
  function cmdPause(state) {
    root.evaluate("if ichi then ichi.set_paused(" + (state === "on" || state === "true") + ") end")
  }

  function cmdPauseToggle() {
    root.evaluate("if ichi then ichi.toggle_pause() end")
  }

  function cmdPaused() {
    return root.status.paused ? "true" : "false"
  }

  // Every workspace on unless it opts out: all on | off.
  function cmdAll(state) {
    root.evaluate("if ichi then ichi.set_all_workspaces(" + (state === "on" || state === "true") + ") end")
  }

  // How chatty to be: never, changes or always.
  function cmdNotify(level) {
    if (Model.NOTIFY_LEVELS.indexOf(level) === -1) return
    root.evaluate("if ichi then ichi.set_notify(\"" + level + "\") end")
  }

  // Give the focused workspace a preset by name.
  function cmdPreset(name) {
    root.evaluate("if ichi then ichi.preset(" + JSON.stringify(String(name)) + ") end")
  }

  // Step through the presets; delta is 1 forwards, -1 back.
  function cmdCycle(delta) {
    root.evaluate("if ichi then ichi.cycle(" + delta + ") end")
  }

  // Keep the focused workspace's current size as a named preset.
  function cmdSavePreset(name) {
    root.evaluate("if ichi then ichi.save_preset(" + JSON.stringify(String(name)) + ") end")
  }

  function cmdRemovePreset(name) {
    root.evaluate("if ichi then ichi.remove_preset(" + JSON.stringify(String(name)) + ") end")
  }

  // Adopt the focused workspace's current size as the default, or with
  // scope "monitor", as the default for its monitor only.
  function cmdAdopt(scope) {
    var lua = scope === "monitor" ? 'ichi.adopt_defaults(nil, "monitor")' : "ichi.adopt_defaults()"
    root.evaluate("if ichi then " + lua + " end")
  }

  function cmdRefresh() {
    root.evaluate("if ichi then ichi.load(); ichi.refresh() end")
  }

  // Re-checks hyprland.lua and installs the loader line if it is missing.
  function cmdSync() {
    hyprlandLuaFile.reload()
  }

  // -------------------------------------------------------------- ipc --
  //
  // omarchy-shell ichi <method> [args]
  // omarchy-shell io.github.aesko.ichi <method> [args]
  //
  // The same surface under both names: `ichi` to type, the reverse-DNS id
  // for anything that wants the unambiguous one. Scripts written against
  // either keep working.

  IchiIpc {
    target: root.pluginId
    api: root
  }

  IchiIpc {
    target: "ichi"
    api: root
  }

  Component.onCompleted: {
    hyprlandLuaFile.reload()
    stateFile.reload()
  }
}

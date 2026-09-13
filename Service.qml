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
  // The state file, in the order ichi.lua picks it: ichi/ichi.json, or while
  // nothing is there, a file from before 0.7 at omarchy/ichi.json, used where
  // it is. usePreviousPath flips once, when the first path cannot be read.
  readonly property string statePath: configDir + "/ichi/ichi.json"
  readonly property string previousStatePath: configDir + "/omarchy/ichi.json"
  property bool usePreviousPath: false
  property bool checkedPreviousPath: false
  readonly property string loaderInstallerPath: decodeURIComponent(String(Qt.resolvedUrl("scripts/install-hyprland-loader.sh")).replace(/^file:\/\//, ""))
  // For notifications: the actual path Ichi read and wrote, home-relative
  // when it is under $HOME (it need not be, with XDG_CONFIG_HOME set).
  readonly property string hyprlandLuaDisplayPath: root.hyprlandLuaPath.indexOf(root.home + "/") === 0
    ? "~" + root.hyprlandLuaPath.slice(root.home.length)
    : root.hyprlandLuaPath

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
    path: root.usePreviousPath ? root.previousStatePath : root.statePath
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

    onLoadFailed: {
      root.config = Model.defaultConfig()
      if (!root.checkedPreviousPath) {
        // Nothing at the new path: try the one from before 0.7. Deferred,
        // because a reload from inside this handler does not load.
        root.checkedPreviousPath = true
        root.usePreviousPath = true
        Qt.callLater(stateFile.reload)
      } else if (root.usePreviousPath) {
        // Neither exists. Go back to the new path, where ichi.lua will create
        // the file, and make its directory first: a watch on a file whose
        // directory is missing never sees the file appear.
        root.usePreviousPath = false
        stateDirProcess.running = true
      }
    }

    // text() is stale inside the change signal, so re-read and let onLoaded
    // parse fresh content.
    onFileChanged: {
      reload()
      root.evaluate("if ichi then ichi.load(); ichi.refresh() end")
    }
  }

  Process {
    id: stateDirProcess
    command: ["mkdir", "-p", "--", root.configDir + "/ichi"]
    onExited: stateFile.reload()
  }

  // ----------------------------------------------------------- loader --
  //
  // Hyprland only reads what its config asks for, so ichi.lua needs one
  // `dofile` line in hyprland.lua. It is guarded by an existence check, so
  // removing the plugin can never break the config.
  //
  // hyprland.lua is often a symlink into a dotfiles repo, so this reads it
  // through FileView but never writes through it: FileView has no ownership
  // or no-follow controls, and a plain in-place write would happily follow
  // a symlink planted by anyone. The actual write goes through
  // scripts/install-hyprland-loader.sh, which resolves that symlink chain
  // itself and refuses unless every step of it belongs to the current user.

  FileView {
    id: hyprlandLuaFile
    path: root.hyprlandLuaPath
    watchChanges: false
    printErrors: false

    onLoaded: {
      var current = text()
      if (Model.needsLoader(current)) {
        installLoaderProcess.command = [root.loaderInstallerPath,
          root.hyprlandLuaPath, root.home, Model.withLoader(current)]
        installLoaderProcess.running = true
      } else {
        root.loaderInstalled = true
      }
    }

    onLoadFailed: {
      // No hyprland.lua means this is not an Omarchy Hyprland session; leave it
      // alone rather than creating a config file out of nowhere.
      root.loaderInstalled = false
    }
  }

  Process {
    id: installLoaderProcess
    property string errorText: ""
    stderr: StdioCollector {
      // The script's own fail() already writes "ichi: <reason>"; kept as-is
      // here since this is also what reaches the notification.
      onStreamFinished: installLoaderProcess.errorText = String(text || "").trim()
    }
    onExited: (exitCode) => {
      root.loaderInstalled = exitCode === 0
      if (exitCode === 0) {
        // The one edit Ichi ever makes to a user file; say so when it happens.
        notifyProcess.running = true
      } else {
        var reason = installLoaderProcess.errorText || "ichi: refused to edit hyprland.lua"
        console.warn(reason)
        notifyRefusedProcess.command = ["omarchy-notification-send", "-u", "normal",
          "Ichi did not edit " + root.hyprlandLuaDisplayPath + ": " +
          reason.replace(/^ichi:\s*/, "") +
          ". Add the guarded loader line yourself (see the README), or fix this and run `ichi sync`."]
        notifyRefusedProcess.running = true
      }
      installLoaderProcess.errorText = ""
    }
  }

  Process {
    id: notifyProcess
    command: ["omarchy-notification-send", "-u", "low",
      "Ichi added one guarded line to " + root.hyprlandLuaDisplayPath +
      " so Hyprland loads it. Remove it any time; it is harmless without the plugin."]
  }

  Process {
    id: notifyRefusedProcess
  }

  // --------------------------------------------------------- commands --
  //
  // One implementation per command. Every IPC target forwards here, so the
  // short name and the reverse-DNS id cannot drift apart.

  // Every command goes out through here. `quiet` suppresses the notification
  // for callers that already show their own result, which is the panel.
  function run(body, quiet) {
    root.evaluate(quiet
      ? "if ichi then ichi.silently(function() " + body + " end) end"
      : "if ichi then " + body + " end")
  }

  function cmdStatus() {
    return Model.statusText(root.status)
  }

  function cmdStatusJson() {
    return JSON.stringify(root.status)
  }

  // "true" or "false" for the focused workspace; drives the menu checkmark.
  function cmdEnabled() {
    return root.enabled ? "true" : "false"
  }

  function cmdToggle(quiet) {
    run("ichi.toggle()", quiet)
    return root.enabled ? "disabling" : "enabling"
  }

  // "Follow the defaults", which on a workspace that is off means turning it
  // on that way. enable() with no entry writes exactly that.
  function cmdUseDefaults(quiet) {
    run("ichi.enable()", quiet)
  }

  function cmdReset() {
    root.evaluate("if ichi then ichi.reset() end")
  }

  // What a deprecated command prints. They keep working through 0.7 and go
  // in 1.0.
  function deprecated(command, instead) {
    return "ichi: `" + command + "` is deprecated and goes in 1.0; use `ichi " + instead + "`"
  }

  // One setting by its place in the file, e.g. set settings.step 10. An
  // unknown key is refused here, so the command line hears why; ichi.lua
  // checks the value and says what the setting takes.
  function cmdSet(key, value, quiet) {
    if (Model.SETTABLE.indexOf(key) === -1) {
      return "ichi: there is no setting called " + key + ". Settings: " + Model.SETTABLE.join(", ")
    }
    run("ichi.set(" + JSON.stringify(String(key)) + ", " + JSON.stringify(String(value)) + ")", quiet)
    return ""
  }

  // Deprecated: nudge or size.
  function cmdAdjust(width, height) {
    root.evaluate("if ichi then ichi.adjust(" + (Number(width) || 0) + ", " + (Number(height) || 0) + ") end")
    return deprecated("adjust", "nudge or ichi size")
  }

  // Switch the focused workspace to aspect mode, e.g. aspect 4 3.
  function cmdAspect(width, height, quiet) {
    var rw = Number(width) || 0
    var rh = Number(height) || 0
    if (rw <= 0 || rh <= 0) return
    run("ichi.set_aspect(" + rw + ", " + rh + ")", quiet)
  }

  // Deprecated: set defaults.width and defaults.height.
  function cmdDefaults(width, height) {
    root.evaluate("if ichi then ichi.set_defaults(" + (Number(width) || 0) + ", " + (Number(height) || 0) + ", 0) end")
    return deprecated("defaults", "set defaults.width and ichi set defaults.height")
  }

  // Deprecated: set defaults.max_width and defaults.max_height.
  function cmdMax(width, height) {
    root.evaluate("if ichi then ichi.set_max(" + (Number(width) || 0) + ", " + (Number(height) || 0) + ") end")
    return deprecated("max", "set defaults.max_width and ichi set defaults.max_height")
  }

  // Deprecated: set defaults.align_x and defaults.align_y.
  function cmdAlign(x, y) {
    root.evaluate("if ichi then ichi.set_align(" + (Number(x) || 0) + ", " + (Number(y) || 0) + ") end")
    return deprecated("align", "set defaults.align_x and ichi set defaults.align_y")
  }

  // Deprecated: set settings.step.
  function cmdStep(points) {
    root.evaluate("if ichi then ichi.set_step(" + (Number(points) || 0) + ", 0) end")
    return deprecated("step", "set settings.step")
  }

  // Deprecated: set settings.fine_step.
  function cmdFineStep(points) {
    root.evaluate("if ichi then ichi.set_step(0, " + (Number(points) || 0) + ") end")
    return deprecated("fine_step", "set settings.fine_step")
  }

  // An absolute size for the focused workspace, which is what a slider has.
  function cmdSize(width, height, quiet) {
    run("ichi.set_size(" + (Number(width) || 0) + ", " + (Number(height) || 0) + ")", quiet)
  }

  // Directions as -1, 0 or 1, scaled by the step or the fine step.
  function cmdNudge(width, height, fine, quiet) {
    run("ichi.nudge(" + (Number(width) || 0) + ", " + (Number(height) || 0) + ", " + (fine === true) + ")", quiet)
  }

  // Deprecated, and does nothing: the smallest size is fixed since 0.7.
  function cmdMin(percent) {
    return "ichi: the smallest size is fixed at " + Model.LIMITS.min + "% since 0.7, so `min` does nothing and goes in 1.0"
  }

  // Deprecated: set settings.max_windows.
  function cmdWindows(count) {
    root.evaluate("if ichi then ichi.set_max_windows(" + (Number(count) || 1) + ") end")
    return deprecated("windows", "set settings.max_windows")
  }

  // Suspend Ichi everywhere without changing any workspace entry.
  function cmdPause(state) {
    root.evaluate("if ichi then ichi.set_paused(" + (state === "on" || state === "true") + ") end")
  }

  function cmdPauseToggle(quiet) {
    run("ichi.toggle_pause()", quiet)
  }

  function cmdPaused() {
    return root.status.paused ? "true" : "false"
  }

  // Deprecated: set settings.all_workspaces.
  function cmdAll(state) {
    root.evaluate("if ichi then ichi.set_all_workspaces(" + (state === "on" || state === "true") + ") end")
    return deprecated("all", "set settings.all_workspaces")
  }

  // Deprecated: set settings.notify.
  function cmdNotify(level) {
    if (Model.NOTIFY_LEVELS.indexOf(level) !== -1) root.evaluate("if ichi then ichi.set_notify(\"" + level + "\") end")
    return deprecated("notify", "set settings.notify")
  }

  // Give the focused workspace a preset by name.
  function cmdPreset(name, quiet) {
    run("ichi.preset(" + JSON.stringify(String(name)) + ")", quiet)
  }

  // Step through the presets; delta is 1 forwards, -1 back.
  function cmdCycle(delta, quiet) {
    run("ichi.cycle(" + delta + ")", quiet)
  }

  // Keep the focused workspace's current size as a named preset.
  function cmdSavePreset(name, quiet) {
    run("ichi.save_preset(" + JSON.stringify(String(name)) + ")", quiet)
  }

  function cmdRemovePreset(name, quiet) {
    run("ichi.remove_preset(" + JSON.stringify(String(name)) + ")", quiet)
  }

  // Adopt the focused workspace's current size as the default, or with
  // scope "monitor", as the default for its monitor only.
  function cmdAdopt(scope, quiet) {
    run(scope === "monitor" ? 'ichi.adopt_defaults(nil, "monitor")' : "ichi.adopt_defaults()", quiet)
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

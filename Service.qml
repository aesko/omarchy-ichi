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
  // The state file, picked the way ichi.lua picks it: ichi/ichi.json, or while
  // nothing is there, a file from before 0.7 at omarchy/ichi.json, used where
  // it is. Both are watched and what each watch last found decides, so the
  // pick follows a file that appears or goes away while the shell runs.
  readonly property string statePath: configDir + "/ichi/ichi.json"
  readonly property string previousStatePath: configDir + "/omarchy/ichi.json"
  property var stateRead: null
  property var previousStateRead: null
  property bool stateDirMade: false
  readonly property var stateChoice: Model.chooseState(stateRead, previousStateRead)
  // Why saving is blocked, as `status` shows it; null while it is not.
  readonly property var stateProblem: stateChoice.problem
    ? homeRelative(stateChoice.previous ? previousStatePath : statePath) + " " + stateChoice.problem
    : null
  readonly property string loaderInstallerPath: decodeURIComponent(String(Qt.resolvedUrl("scripts/install-hyprland-loader.sh")).replace(/^file:\/\//, ""))
  // For notifications: the actual path Ichi read and wrote.
  readonly property string hyprlandLuaDisplayPath: homeRelative(hyprlandLuaPath)

  // Home-relative when under $HOME, which a path need not be with
  // XDG_CONFIG_HOME set.
  function homeRelative(path) {
    return path.indexOf(root.home + "/") === 0 ? "~" + path.slice(root.home.length) : path
  }

  readonly property var config: stateChoice.config
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
  readonly property var status: Model.status(config, activeWorkspaceId, activeMonitor, stateProblem)
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
  //
  // text() is stale inside a change signal, so each watch re-reads and lets
  // onLoaded parse the fresh content.

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.stateRead = Model.readState(root.stateRead, "text", text())
    onLoadFailed: (error) => root.stateReadFailed(false, error)
    onFileChanged: {
      reload()
      root.evaluate("if ichi then ichi.load(); ichi.refresh() end")
    }
  }

  FileView {
    id: previousStateFile
    path: root.previousStatePath
    watchChanges: true
    printErrors: false
    onLoaded: root.previousStateRead = Model.readState(root.previousStateRead, "text", text())
    onLoadFailed: (error) => root.stateReadFailed(true, error)
    onFileChanged: {
      reload()
      root.evaluate("if ichi then ichi.load(); ichi.refresh() end")
    }
  }

  function stateReadFailed(previous, error) {
    var outcome = error === FileViewError.FileNotFound ? "missing" : "unreadable"
    if (previous) root.previousStateRead = Model.readState(root.previousStateRead, outcome)
    else root.stateRead = Model.readState(root.stateRead, outcome)
    // With neither file there, make the new one's directory, where ichi.lua
    // will create it: a watch on a file whose directory is missing never sees
    // the file appear.
    if (!root.stateDirMade && root.stateRead && root.previousStateRead
        && !root.stateRead.present && !root.previousStateRead.present) {
      root.stateDirMade = true
      stateDirProcess.running = true
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
  // itself, refuses unless every step of it belongs to the current user, and
  // replaces the file by rename rather than truncating it in place, so a
  // write that fails partway leaves the config as it was.

  FileView {
    id: hyprlandLuaFile
    path: root.hyprlandLuaPath
    watchChanges: false
    printErrors: false

    onLoaded: {
      var current = text()
      if (Model.needsLoader(current)) {
        // The content travels in the environment, not in argv: this is the
        // user's whole Hyprland config and /proc/<pid>/cmdline is readable by
        // every local account, while /proc/<pid>/environ is not.
        installLoaderProcess.environment = ({ "ICHI_LOADER_CONTENT": Model.withLoader(current) })
        installLoaderProcess.command = [root.loaderInstallerPath,
          root.hyprlandLuaPath, root.home]
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
      // Not kept around any longer than the one run that needs it.
      installLoaderProcess.environment = ({})
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

  // Which workspace a command is about, as the argument every per-workspace
  // action in ichi.lua takes last or first: a quoted name, or nil for
  // "whatever is focused". The command line, the menu and the keybindings
  // all mean the focused one. The bar widget means the workspace on its own
  // monitor, because the bar is drawn once per screen and each copy is about
  // the screen it is on.
  function target(workspace) {
    return workspace === undefined || workspace === null || workspace === ""
      ? "nil"
      : JSON.stringify(String(workspace))
  }

  // Whether Ichi is on for one workspace, defaulting to the focused one.
  function enabledOn(workspace) {
    var key = workspace === undefined || workspace === null || workspace === ""
      ? root.activeWorkspaceId
      : String(workspace)
    return key !== null && Model.entryFor(root.config, key) !== null
  }

  function cmdHelp() {
    return Model.HELP_TEXT
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

  function cmdToggle(quiet, workspace) {
    run("ichi.toggle(" + target(workspace) + ")", quiet)
    return enabledOn(workspace) ? "disabling" : "enabling"
  }

  // "Follow the defaults", which on a workspace that is off means turning it
  // on that way. enable() with no entry writes exactly that.
  function cmdUseDefaults(quiet, workspace) {
    run("ichi.enable(" + target(workspace) + ")", quiet)
  }

  function cmdReset(quiet, workspace) {
    run("ichi.reset(" + target(workspace) + ")", quiet)
  }

  // What a deprecated command prints. They keep working through 0.7 and go
  // in 1.0.
  function deprecated(command, instead) {
    return "ichi: `" + command + "` is deprecated and goes in 1.0; use `ichi " + instead + "`"
  }

  // One setting by its place in the file, e.g. set settings.step 10. An
  // unknown key or a value of the wrong kind is refused here, so the command
  // line hears why; ichi.lua clamps numbers to their range.
  function cmdSet(key, value, quiet) {
    var problem = Model.settingProblem(key, value)
    if (problem !== "") return "ichi: " + problem
    run("ichi.set(" + JSON.stringify(String(key)) + ", " + JSON.stringify(String(value)) + ")", quiet)
    return ""
  }

  // Deprecated: nudge or size.
  function cmdAdjust(width, height) {
    root.evaluate("if ichi then ichi.adjust(" + (Number(width) || 0) + ", " + (Number(height) || 0) + ") end")
    return deprecated("adjust", "nudge or ichi size")
  }

  // Switch a workspace to aspect mode, e.g. aspect 4 3.
  function cmdAspect(width, height, quiet, workspace) {
    var rw = Number(width) || 0
    var rh = Number(height) || 0
    if (rw <= 0 || rh <= 0) return
    run("ichi.set_aspect(" + rw + ", " + rh + ", " + target(workspace) + ")", quiet)
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

  // An absolute size for a workspace, which is what a slider has.
  function cmdSize(width, height, quiet, workspace) {
    run("ichi.set_size(" + (Number(width) || 0) + ", " + (Number(height) || 0)
      + ", " + target(workspace) + ")", quiet)
  }

  // Directions as -1, 0 or 1, scaled by the step or the fine step.
  function cmdNudge(width, height, fine, quiet, workspace) {
    run("ichi.nudge(" + (Number(width) || 0) + ", " + (Number(height) || 0)
      + ", " + (fine === true) + ", " + target(workspace) + ")", quiet)
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

  // Whether Ichi runs on a workspace's monitor at all: the narrower veto
  // between pause and a workspace's own entry. Entries are left alone, so a
  // monitor switched back on gets every inset on it back.
  function cmdMonitor(state, quiet, workspace) {
    var on = state === "on" || state === "true"
    run("ichi.set_monitor_enabled(" + on + ", " + target(workspace) + ")", quiet)
  }

  function cmdMonitorToggle(quiet, workspace) {
    run("ichi.toggle_monitor(" + target(workspace) + ")", quiet)
  }

  // "true" or "false"; drives the menu checkmark and the panel's switch.
  function cmdMonitorEnabled() {
    return root.status.monitorEnabled === false ? "false" : "true"
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

  // Give a workspace a preset by name.
  function cmdPreset(name, quiet, workspace) {
    run("ichi.preset(" + JSON.stringify(String(name)) + ", " + target(workspace) + ")", quiet)
  }

  // Step through the presets; delta is 1 forwards, -1 back.
  function cmdCycle(delta, quiet, workspace) {
    run("ichi.cycle(" + delta + ", " + target(workspace) + ")", quiet)
  }

  // Keep a workspace's current size as a named preset.
  function cmdSavePreset(name, quiet, workspace) {
    run("ichi.save_preset(" + JSON.stringify(String(name)) + ", " + target(workspace) + ")", quiet)
  }

  function cmdRemovePreset(name, quiet) {
    run("ichi.remove_preset(" + JSON.stringify(String(name)) + ")", quiet)
  }

  // Adopt a workspace's current size as the default, or with scope
  // "monitor", as the default for its monitor only.
  function cmdAdopt(scope, quiet, workspace) {
    run("ichi.adopt_defaults(" + target(workspace)
      + (scope === "monitor" ? ', "monitor")' : ")"), quiet)
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
    previousStateFile.reload()
  }
}

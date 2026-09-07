// Pure logic for the shell side of Ichi. No Qt, no I/O, so
// tests/model.test.mjs can run it under plain node.
.pragma library

var PLUGIN_ID = "io.github.aesko.ichi"
var LOADER_MARK = "-- " + PLUGIN_ID + ": loads Ichi's Hyprland-side logic if installed."
var LOADER_LINE = LOADER_MARK + "\n" +
  'do local p = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. ' +
  '"/omarchy/plugins/' + PLUGIN_ID + '/ichi.lua"; ' +
  'local f = io.open(p, "r"); if f then f:close(); dofile(p) end end\n'

var LIMITS = { min: 30, max: 100 }

var NOTIFY_LEVELS = ["never", "changes", "always"]

function defaultConfig() {
  return {
    settings: { step: 5, fine_step: 1, notify: "always" },
    defaults: { width: 70, height: 80 },
    workspaces: {},
  }
}

function clamp(value, lo, hi) {
  return Math.max(lo, Math.min(hi, value))
}

// `true` (or mode "default") follows the defaults; "size" and "aspect" are
// fixed for that workspace.
function normalizeEntry(entry, defaults) {
  if (entry === true) return { mode: "default" }
  if (!entry || typeof entry !== "object") return null
  if (entry.mode === "default") return { mode: "default" }
  if (entry.mode === "aspect") {
    var ratio = Array.isArray(entry.ratio) ? entry.ratio : []
    var rw = Number(ratio[0]), rh = Number(ratio[1])
    if (!(rw > 0) || !(rh > 0)) return null
    return { mode: "aspect", ratio: [rw, rh] }
  }
  var width = Number(entry.width), height = Number(entry.height)
  return {
    mode: "size",
    width: clamp(Math.floor(isFinite(width) ? width : defaults.width), LIMITS.min, LIMITS.max),
    height: clamp(Math.floor(isFinite(height) ? height : defaults.height), LIMITS.min, LIMITS.max),
  }
}

// Mirrors ichi.lua's parser: a bad entry is dropped, never the file.
function normalizeConfig(document) {
  var config = defaultConfig()
  if (!document || typeof document !== "object") return config

  var defaults = document.defaults || {}
  var settings = document.settings || {}
  if (isFinite(Number(defaults.width))) config.defaults.width = clamp(Math.floor(Number(defaults.width)), LIMITS.min, LIMITS.max)
  if (isFinite(Number(defaults.height))) config.defaults.height = clamp(Math.floor(Number(defaults.height)), LIMITS.min, LIMITS.max)
  // `step` lived under defaults before 0.2; both places are read.
  var step = isFinite(Number(settings.step)) ? settings.step : defaults.step
  if (isFinite(Number(step))) config.settings.step = clamp(Math.floor(Number(step)), 1, 25)
  if (isFinite(Number(settings.fine_step))) config.settings.fine_step = clamp(Math.floor(Number(settings.fine_step)), 1, 25)
  if (NOTIFY_LEVELS.indexOf(settings.notify) !== -1) config.settings.notify = settings.notify

  var workspaces = document.workspaces || {}
  for (var key in workspaces) {
    if (!/^\d+$/.test(key)) continue
    var entry = normalizeEntry(workspaces[key], config.defaults)
    if (entry) config.workspaces[key] = entry
  }
  return config
}

function parseConfig(text) {
  try {
    return normalizeConfig(JSON.parse(String(text || "")))
  } catch (error) {
    return null
  }
}

function needsLoader(hyprlandLua) {
  return String(hyprlandLua || "").indexOf(LOADER_MARK) === -1
}

function withLoader(hyprlandLua) {
  var text = String(hyprlandLua || "")
  if (!needsLoader(text)) return text
  if (text.length > 0 && text[text.length - 1] !== "\n") text += "\n"
  return text + "\n" + LOADER_LINE
}

function hyprctlEvalArgs(lua) {
  return ["hyprctl", "eval", "do\n" + String(lua) + "\nend"]
}

// A default entry is shown with what it currently amounts to.
function resolve(entry, config) {
  if (entry && entry.mode === "default") {
    return { mode: "size", width: config.defaults.width, height: config.defaults.height }
  }
  return entry
}

function describe(entry, config) {
  if (!entry) return "off"
  var suffix = entry.mode === "default" ? " (default)" : ""
  entry = resolve(entry, config)
  if (entry.mode === "aspect") return entry.ratio[0] + ":" + entry.ratio[1]
  return entry.width + "% x " + entry.height + "%" + suffix
}

function status(config, activeWorkspaceId) {
  var key = activeWorkspaceId === null || activeWorkspaceId === undefined ? null : String(activeWorkspaceId)
  var entry = key !== null ? (config.workspaces[key] || null) : null
  return {
    workspace: key === null ? null : Number(key),
    enabled: entry !== null,
    entry: entry,
    summary: describe(entry, config),
    settings: config.settings,
    defaults: config.defaults,
    workspaces: Object.keys(config.workspaces).map(Number).sort(function (a, b) { return a - b }),
  }
}

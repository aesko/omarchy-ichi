// Pure logic for the shell side of Ichi. No Qt, no I/O, so
// tests/model.test.mjs can run it under plain node.
.pragma library

var PLUGIN_ID = "aesko.ichi"
var LOADER_MARK = "-- " + PLUGIN_ID + ": loads Ichi's Hyprland-side logic if installed."
var LOADER_LINE = LOADER_MARK + "\n" +
  'do local p = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. ' +
  '"/omarchy/plugins/' + PLUGIN_ID + '/ichi.lua"; ' +
  'local f = io.open(p, "r"); if f then f:close(); dofile(p) end end\n'

var LIMITS = { min: 30, max: 100 }

function defaultConfig() {
  return { defaults: { width: 70, height: 80, step: 5 }, workspaces: {} }
}

function clamp(value, lo, hi) {
  return Math.max(lo, Math.min(hi, value))
}

function normalizeEntry(entry, defaults) {
  if (!entry || typeof entry !== "object") return null
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
  if (isFinite(Number(defaults.width))) config.defaults.width = clamp(Math.floor(Number(defaults.width)), LIMITS.min, LIMITS.max)
  if (isFinite(Number(defaults.height))) config.defaults.height = clamp(Math.floor(Number(defaults.height)), LIMITS.min, LIMITS.max)
  if (isFinite(Number(defaults.step))) config.defaults.step = clamp(Math.floor(Number(defaults.step)), 1, 25)

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

function describe(entry) {
  if (!entry) return "off"
  if (entry.mode === "aspect") return entry.ratio[0] + ":" + entry.ratio[1]
  return entry.width + "% x " + entry.height + "%"
}

function status(config, activeWorkspaceId) {
  var key = activeWorkspaceId === null || activeWorkspaceId === undefined ? null : String(activeWorkspaceId)
  var entry = key !== null ? (config.workspaces[key] || null) : null
  return {
    workspace: key === null ? null : Number(key),
    enabled: entry !== null,
    entry: entry,
    summary: describe(entry),
    defaults: config.defaults,
    workspaces: Object.keys(config.workspaces).map(Number).sort(function (a, b) { return a - b }),
  }
}

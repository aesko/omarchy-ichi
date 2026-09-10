// Pure logic for the shell side of Ichi. No Qt, no I/O, so
// tests/model.test.mjs can run it under plain node.
.pragma library

var PLUGIN_ID = "io.github.aesko.ichi"
var LOADER_MARK = "-- " + PLUGIN_ID + ": loads Ichi's Hyprland-side logic if installed."
var LOADER_LINE = LOADER_MARK + "\n" +
  'do local p = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. ' +
  '"/omarchy/plugins/' + PLUGIN_ID + '/ichi.lua"; ' +
  'local f = io.open(p, "r"); if f then f:close(); dofile(p) end end\n'

// The range settings.min_percent may take; sizes are clamped between that
// setting and 100.
var LIMITS = { min: 5, max: 100 }

var NOTIFY_LEVELS = ["never", "changes", "always"]

function defaultConfig() {
  return {
    settings: { step: 5, fine_step: 1, notify: "always", all_workspaces: false, max_windows: 1, min_percent: 20, paused: false },
    defaults: { width: 70, height: 80 },
    monitors: [],
    presets: [],
    workspaces: {},
  }
}

function clamp(value, lo, hi) {
  return Math.max(lo, Math.min(hi, value))
}

// `true` (or mode "default") follows the defaults; "size" and "aspect" are
// fixed for that workspace.
function normalizeEntry(entry, defaults, min) {
  if (entry === true) return { mode: "default" }
  if (entry === false) return false
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
    width: clamp(Math.floor(isFinite(width) ? width : defaults.width), min, LIMITS.max),
    height: clamp(Math.floor(isFinite(height) ? height : defaults.height), min, LIMITS.max),
  }
}

// Mirrors ichi.lua's parser: a bad entry is dropped, never the file.
function normalizeConfig(document) {
  var config = defaultConfig()
  if (!document || typeof document !== "object") return config

  var defaults = document.defaults || {}
  var settings = document.settings || {}
  // Read first: every size below is clamped against it.
  if (isFinite(Number(settings.min_percent))) config.settings.min_percent = clamp(Math.floor(Number(settings.min_percent)), LIMITS.min, LIMITS.max)
  var min = config.settings.min_percent
  if (isFinite(Number(defaults.width))) config.defaults.width = clamp(Math.floor(Number(defaults.width)), min, LIMITS.max)
  if (isFinite(Number(defaults.height))) config.defaults.height = clamp(Math.floor(Number(defaults.height)), min, LIMITS.max)
  if (Number(defaults.max_width) > 0) config.defaults.max_width = Math.floor(Number(defaults.max_width))
  if (Number(defaults.max_height) > 0) config.defaults.max_height = Math.floor(Number(defaults.max_height))
  if (isFinite(Number(defaults.align_x))) config.defaults.align_x = clamp(Math.floor(Number(defaults.align_x)), 0, 100)
  if (isFinite(Number(defaults.align_y))) config.defaults.align_y = clamp(Math.floor(Number(defaults.align_y)), 0, 100)
  // `step` lived under defaults before 0.2; both places are read.
  var step = isFinite(Number(settings.step)) ? settings.step : defaults.step
  if (isFinite(Number(step))) config.settings.step = clamp(Math.floor(Number(step)), 1, 25)
  if (isFinite(Number(settings.fine_step))) config.settings.fine_step = clamp(Math.floor(Number(settings.fine_step)), 1, 25)
  if (NOTIFY_LEVELS.indexOf(settings.notify) !== -1) config.settings.notify = settings.notify
  config.settings.all_workspaces = settings.all_workspaces === true
  config.settings.paused = settings.paused === true
  if (isFinite(Number(settings.max_windows))) config.settings.max_windows = clamp(Math.floor(Number(settings.max_windows)), 1, 10)

  var monitors = document.monitors || {}
  for (var mkey in monitors) {
    var raw = monitors[mkey]
    if (!raw || typeof raw !== "object") continue
    var block = { key: mkey }
    if (isFinite(Number(raw.width))) block.width = clamp(Math.floor(Number(raw.width)), min, LIMITS.max)
    if (isFinite(Number(raw.height))) block.height = clamp(Math.floor(Number(raw.height)), min, LIMITS.max)
    if (isFinite(Number(raw.max_width))) block.max_width = Math.max(0, Math.floor(Number(raw.max_width)))
    if (isFinite(Number(raw.max_height))) block.max_height = Math.max(0, Math.floor(Number(raw.max_height)))
    if (isFinite(Number(raw.align_x))) block.align_x = clamp(Math.floor(Number(raw.align_x)), 0, 100)
    if (isFinite(Number(raw.align_y))) block.align_y = clamp(Math.floor(Number(raw.align_y)), 0, 100)
    config.monitors.push(block)
  }

  var presets = document.presets || {}
  for (var name in presets) {
    var preset = normalizeEntry(presets[name], config.defaults, min)
    if (preset) config.presets.push({ name: name, entry: preset })
  }

  var workspaces = document.workspaces || {}
  for (var key in workspaces) {
    // Keys are workspace names. Hyprland names a numeric workspace by its
    // number, so "2" still means workspace 2.
    if (!key) continue
    var entry = normalizeEntry(workspaces[key], config.defaults, min)
    if (entry !== null && entry !== undefined) config.workspaces[key] = entry
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

// Mirrors ichi.lua: exact connector name, or "desc:" matching any part of the
// description; first block wins. `monitor` is { name, description } or null.
function monitorBlock(config, monitor) {
  if (!monitor) return null
  for (var i = 0; i < config.monitors.length; i++) {
    var block = config.monitors[i]
    if (block.key.indexOf("desc:") === 0) {
      var desc = block.key.slice(5)
      if (desc !== "" && String(monitor.description || "").indexOf(desc) !== -1) return block
    } else if (block.key === monitor.name) {
      return block
    }
  }
  return null
}

function defaultsFor(config, monitor) {
  var out = {}
  for (var k in config.defaults) out[k] = config.defaults[k]
  var block = monitorBlock(config, monitor)
  if (block) {
    ["width", "height", "max_width", "max_height", "align_x", "align_y"].forEach(function (field) {
      if (block[field] !== undefined) out[field] = block[field]
    })
  }
  return out
}

// A default entry is shown with what it currently amounts to on this monitor.
function resolve(entry, config, monitor) {
  if (entry && entry.mode === "default") {
    var d = defaultsFor(config, monitor)
    return { mode: "size", width: d.width, height: d.height }
  }
  return entry
}

function describe(entry, config, monitor) {
  if (!entry) return "off"
  var suffix = entry.mode === "default" ? " (default)" : ""
  entry = resolve(entry, config, monitor)
  if (entry.mode === "aspect") return entry.ratio[0] + ":" + entry.ratio[1]
  return entry.width + "% x " + entry.height + "%" + suffix
}

function sameEntry(a, b) {
  if (!a || !b || a.mode !== b.mode) return false
  if (a.mode === "aspect") return a.ratio[0] === b.ratio[0] && a.ratio[1] === b.ratio[1]
  return a.mode === "default" || (a.width === b.width && a.height === b.height)
}

// The name of the preset the entry matches, if any.
function presetName(config, entry) {
  for (var i = 0; i < config.presets.length; i++) {
    if (sameEntry(config.presets[i].entry, entry)) return config.presets[i].name
  }
  return null
}

// Mirrors ichi.lua's entry_for: false is off, absent follows the defaults
// when all_workspaces is on.
function entryFor(config, key) {
  var entry = config.workspaces[key]
  if (entry === false) return null
  if (entry === undefined && config.settings.all_workspaces) return { mode: "default" }
  return entry || null
}

// `activeWorkspace` is the focused workspace's name, which is its number on a
// numeric workspace.
function status(config, activeWorkspaceId, monitor) {
  var key = activeWorkspaceId === null || activeWorkspaceId === undefined ? null : String(activeWorkspaceId)
  var entry = key !== null ? entryFor(config, key) : null
  return {
    workspace: key,
    enabled: entry !== null,
    entry: entry,
    summary: describe(entry, config, monitor),
    // The concrete size an entry amounts to here, so a caller does not have to
    // re-derive what "follows the defaults" means on this monitor.
    resolved: entry ? resolve(entry, config, monitor) : null,
    settings: config.settings,
    defaults: config.defaults,
    paused: config.settings.paused,
    monitor: monitorBlock(config, monitor),
    preset: presetName(config, entry),
    presets: config.presets.map(function (p) { return p.name }),
    workspaces: Object.keys(config.workspaces).filter(function (k) { return config.workspaces[k] !== false })
      .sort(function (a, b) {
        var na = Number(a), nb = Number(b)
        if (isFinite(na) && isFinite(nb)) return na - nb
        if (isFinite(na)) return -1
        if (isFinite(nb)) return 1
        return a < b ? -1 : a > b ? 1 : 0
      }),
  }
}

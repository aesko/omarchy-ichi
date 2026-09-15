// Run: node tests/model.test.mjs
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import assert from "node:assert/strict"

// Model.js is a QML JS library (.pragma library, no exports); evaluate it as a
// script and pick its functions off the resulting scope.
const source = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const Model = new Function(source + `
  return { defaultConfig, normalizeConfig, parseConfig, needsLoader, withLoader, hyprctlEvalArgs, status, statusText, ichiBinds, HELP_TEXT, LOADER_LINE, LOADER_MARK, NOTIFY_LEVELS, SETTABLE, SETTING_KINDS, LIMITS, settingProblem, readState, chooseState, wellFormed }
`)()

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
    console.log("ok   " + name)
  } catch (error) {
    console.log("FAIL " + name + ": " + error.message)
    process.exitCode = 1
  }
}

const repo = join(dirname(fileURLToPath(import.meta.url)), "..")

// Every IPC function, with whether the comment above it says Deprecated.
function ipcCommands() {
  const qml = readFileSync(join(repo, "IchiIpc.qml"), "utf8")
  return [...qml.matchAll(/(\/\/ Deprecated[^\n]*\n\s*)?function (\w+)\(/g)]
    .map((m) => ({ name: m[2], deprecated: m[1] !== undefined }))
}

// The commands help lists: the first word of each indented row.
function helpCommands() {
  return Model.HELP_TEXT.split("\n")
    .filter((line) => line.startsWith("  "))
    .map((line) => line.trim().split(" ")[0])
}

function referenceCommands() {
  const reference = readFileSync(join(repo, "docs", "reference.md"), "utf8")
  const block = reference.slice(reference.indexOf("## Commands"), reference.indexOf("### set"))
  return [...block.matchAll(/omarchy-shell ichi (\w+)/g)].map((m) => m[1])
}

test("help lists every current command and nothing that is not one", () => {
  const commands = ipcCommands()
  const listed = helpCommands()
  const current = commands.filter((c) => !c.deprecated).map((c) => c.name)
  assert.deepEqual(current.filter((name) => !listed.includes(name)), [], "missing from help")
  const deprecated = commands.filter((c) => c.deprecated).map((c) => c.name)
  assert.deepEqual(listed.filter((name) => !current.includes(name)), [], "in help but not a current command")
  assert.ok(deprecated.length > 0, "found no deprecated commands; has the comment style changed?")
})

test("docs/reference.md lists every current command", () => {
  const listed = referenceCommands()
  const missing = ipcCommands().filter((c) => !c.deprecated && !listed.includes(c.name)).map((c) => c.name)
  assert.deepEqual(missing, [])
})

test("parseConfig normalizes and drops bad entries", () => {
  const config = Model.parseConfig(JSON.stringify({
    defaults: { width: 60, height: "75", step: 99 },
    workspaces: {
      "2": { mode: "size", width: 70, height: 80 },
      "5": { mode: "aspect", ratio: [4, 3] },
      "7": { mode: "aspect", ratio: [0, 3] },
      "8": true,
      "9": { mode: "default", width: 40 },
      "x": { mode: "size", width: 50, height: 50 },
    },
  }))
  assert.deepEqual(config.defaults, { width: 60, height: 75 })
  // A step under defaults, where it lived before 0.2, is no longer read.
  assert.deepEqual(config.settings, { step: 5, fine_step: 1, notify: "changes", all_workspaces: false, max_windows: 1, paused: false })
  assert.deepEqual(config.workspaces["2"], { mode: "size", width: 70, height: 80 })
  assert.deepEqual(config.workspaces["5"], { mode: "aspect", ratio: [4, 3] })
  assert.equal(config.workspaces["7"], undefined)
  assert.deepEqual(config.workspaces["8"], { mode: "default" })
  assert.deepEqual(config.workspaces["9"], { mode: "default" })
  assert.deepEqual(config.workspaces["x"], { mode: "size", width: 50, height: 50 })
})

test("settings block is read", () => {
  const modern = Model.parseConfig(JSON.stringify({ settings: { step: 10, fine_step: 2, notify: "never", max_windows: 30 }, defaults: { step: 3 } }))
  assert.deepEqual(modern.settings, { step: 10, fine_step: 2, notify: "never", all_workspaces: false, max_windows: 10, paused: false })
  // The floor is fixed; min_percent is ignored rather than read.
  const floor = Model.parseConfig(JSON.stringify({ settings: { min_percent: 40 }, defaults: { width: 5 }, workspaces: { "1": { width: 3, height: 12 } } }))
  assert.equal(floor.settings.min_percent, undefined)
  assert.equal(floor.defaults.width, 10)
  assert.equal(floor.workspaces["1"].width, 10)
  assert.equal(floor.workspaces["1"].height, 12)
  assert.equal(Model.parseConfig(JSON.stringify({ defaults: { step: 3 } })).settings.step, 5)
  const capped = Model.parseConfig(JSON.stringify({ defaults: { max_width: 1600.7, max_height: -1, align_x: 120, align_y: 40 } }))
  assert.equal(capped.defaults.max_width, 1600)
  assert.equal(capped.defaults.max_height, undefined)
  assert.equal(capped.defaults.align_x, 100)
  assert.equal(capped.defaults.align_y, 40)
  const aligned = Model.parseConfig(JSON.stringify({ monitors: { "eDP-1": { align_y: 0 } } }))
  assert.deepEqual(aligned.monitors, [{ key: "eDP-1", align_y: 0 }])
  const bogus = Model.parseConfig(JSON.stringify({ settings: { notify: "loudly" } }))
  assert.equal(bogus.settings.notify, "changes")
})

// ichi.lua is the one that checks and stores settings; the shell only has to
// agree with it on the keys and the floor.
const ichiLua = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "ichi.lua"), "utf8")

test("SETTING_KINDS has exactly ichi.lua's keys, each read the same way", () => {
  const kinds = { parse_int: "number", parse_bool: "switch", function: "level" }
  const found = {}
  for (const match of ichiLua.matchAll(/\["((?:settings|defaults)\.[a-z_]+)"\] = \{\s*parse = (parse_int|parse_bool|function)/g)) {
    found[match[1]] = kinds[match[2]]
  }
  assert.equal(Object.keys(found).length, 12)
  assert.deepEqual(found, Model.SETTING_KINDS)
  assert.deepEqual([...Model.SETTABLE].sort(), Object.keys(found).sort())
})

test("settingProblem refuses what ichi.lua could not take, and says why", () => {
  assert.equal(Model.settingProblem("settings.step", "10"), "")
  assert.equal(Model.settingProblem("defaults.align_x", "-3"), "")
  assert.match(Model.settingProblem("settings.step", "ten"), /^settings\.step takes a number$/)
  // Every form ichi.lua's tonumber reads gets through; ichi.lua clamps.
  for (const number of ["+5", "2e3", "0x10", ".5", "5.", " 7 "]) {
    assert.equal(Model.settingProblem("defaults.max_width", number), "", number)
  }
  for (const notNumber of ["", "  ", "Infinity", "1e999", "5px"]) {
    assert.match(Model.settingProblem("defaults.max_width", notNumber), /takes a number$/, notNumber)
  }
  assert.equal(Model.settingProblem("settings.paused", "on"), "")
  assert.match(Model.settingProblem("settings.paused", "yes"), /takes on or off$/)
  assert.equal(Model.settingProblem("settings.notify", "never"), "")
  assert.match(Model.settingProblem("settings.notify", "loudly"), /takes never, changes, always$/)
  assert.match(Model.settingProblem("settings.min_percent", "5"), /^there is no setting called settings\.min_percent\. Settings: settings\.step/)
})

test("the shell picks the state file by ichi.lua's rule", () => {
  const missing = Model.readState(null, "missing")
  const current = Model.readState(null, "text", JSON.stringify({ workspaces: { "3": true } }))
  const previous = Model.readState(null, "text", JSON.stringify({ workspaces: { "7": true } }))
  const keys = (choice) => Object.keys(choice.config.workspaces)
  assert.equal(Model.chooseState(current, previous).previous, false)
  assert.deepEqual(keys(Model.chooseState(current, previous)), ["3"])
  assert.equal(Model.chooseState(missing, previous).previous, true)
  assert.deepEqual(keys(Model.chooseState(missing, previous)), ["7"])
  assert.equal(Model.chooseState(missing, missing).previous, false)
  assert.deepEqual(Model.chooseState(missing, missing).config, Model.defaultConfig())
  // Something at the new path that cannot be read is still there, so it wins,
  // keeping the last config its watch had and saying why saving is blocked.
  const locked = Model.readState(current, "unreadable")
  assert.equal(Model.chooseState(locked, previous).previous, false)
  assert.equal(Model.chooseState(locked, previous).problem, "cannot be read")
  assert.deepEqual(keys(Model.chooseState(locked, previous)), ["3"])
  const broken = Model.readState(current, "text", '{ "workspaces": ')
  assert.equal(Model.chooseState(broken, missing).problem, "does not parse")
  assert.deepEqual(keys(Model.chooseState(broken, missing)), ["3"])
  assert.equal(Model.chooseState(current, previous).problem, null)
  // A trailing comma is not JSON, but ichi.lua reads and saves it, so saving
  // is not reported blocked; the last good config stays on show meanwhile.
  const trailing = Model.readState(current, "text", '{ "settings": { "step": 7, }, "workspaces": {} }')
  assert.equal(Model.chooseState(trailing, missing).problem, null)
  assert.deepEqual(keys(Model.chooseState(trailing, missing)), ["3"])
})

test("wellFormed agrees with ichi.lua's M.well_formed", () => {
  assert.ok(Model.wellFormed(JSON.stringify(Model.defaultConfig())))
  assert.ok(Model.wellFormed('{ "presets": { "a}\\"{": true } }'))
  assert.ok(Model.wellFormed('{ "settings": { "step": 7, } }'))
  assert.ok(!Model.wellFormed(""))
  assert.ok(!Model.wellFormed("  \n"))
  assert.ok(!Model.wellFormed('{ "workspaces": { "1": true,'))
  assert.ok(!Model.wellFormed('{ "workspaces": { "2": { "width": 60 } }'))
  assert.ok(!Model.wellFormed('{ "ratio": [4, 3} }'))
  assert.ok(!Model.wellFormed('{ "wor'))
  assert.ok(!Model.wellFormed("{ } }"))
})

test("statusText says when saving is blocked", () => {
  const text = Model.statusText(Model.status(Model.defaultConfig(), "1", null, "~/.config/ichi/ichi.json does not parse"))
  assert.match(text, /^Workspace {3}1\nSaving {6}blocked: ~\/\.config\/ichi\/ichi\.json does not parse\n/)
  assert.doesNotMatch(Model.statusText(Model.status(Model.defaultConfig(), "1", null, null)), /Saving/)
})

test("LIMITS matches ichi.lua's", () => {
  const match = /M\.limits = \{ min = (\d+), max = (\d+) \}/.exec(ichiLua)
  assert.ok(match, "M.limits not found in ichi.lua")
  assert.deepEqual(Model.LIMITS, { min: Number(match[1]), max: Number(match[2]) })
})

test("parseConfig returns null for malformed JSON so the caller keeps the last good document", () => {
  assert.equal(Model.parseConfig("{ not json"), null)
})

test("parseConfig of empty text is the default config", () => {
  assert.deepEqual(Model.normalizeConfig(null), Model.defaultConfig())
})

test("loader is added once and only once", () => {
  const original = "require(\"default.hypr.omarchy\")\n"
  const withLoader = Model.withLoader(original)
  assert.ok(Model.needsLoader(original))
  assert.ok(!Model.needsLoader(withLoader))
  assert.ok(withLoader.startsWith(original))
  assert.ok(withLoader.endsWith(Model.LOADER_LINE))
  assert.equal(Model.withLoader(withLoader), withLoader)
})

test("loader terminates an unterminated last line before appending", () => {
  const result = Model.withLoader("-- no trailing newline")
  assert.ok(result.includes("-- no trailing newline\n\n" + Model.LOADER_MARK))
})

test("loader line is guarded by an existence check", () => {
  assert.ok(Model.LOADER_LINE.includes('io.open(p, "r")'))
  assert.ok(Model.LOADER_LINE.includes("dofile(p)"))
})

test("hyprctlEvalArgs wraps the payload in a block", () => {
  assert.deepEqual(Model.hyprctlEvalArgs("ichi.toggle()"), ["hyprctl", "eval", "do\nichi.toggle()\nend"])
})

test("status reports the active workspace", () => {
  const config = Model.normalizeConfig({ workspaces: { "2": { width: 70, height: 80 }, "5": { mode: "aspect", ratio: [1, 1] } } })
  assert.deepEqual(Model.status(config, 2), {
    workspace: "2", problem: null, enabled: true, entry: { mode: "size", width: 70, height: 80 }, summary: "70% x 80%",
    resolved: { mode: "size", width: 70, height: 80 },
    settings: { step: 5, fine_step: 1, notify: "changes", all_workspaces: false, max_windows: 1, paused: false }, paused: false, defaults: { width: 70, height: 80 }, monitor: null, preset: null, presets: [], workspaces: ["2", "5"],
  })
  assert.equal(Model.status(config, 5).summary, "1:1")
  assert.equal(Model.status(config, 3).enabled, false)
  assert.deepEqual(Model.status(config, 3).resolved, { mode: "size", width: 70, height: 80 })
  assert.equal(Model.status(config, null).workspace, null)
  const following = Model.normalizeConfig({ defaults: { width: 60, height: 90 }, workspaces: { "3": true } })
  assert.equal(Model.status(following, 3).summary, "60% x 90% (default)")
  assert.equal(Model.status(following, 3).enabled, true)
  // A default entry resolves to what the defaults currently say.
  assert.deepEqual(Model.status(following, 3).resolved, { mode: "size", width: 60, height: 90 })
})

test("all_workspaces turns absent entries on and false entries off", () => {
  const config = Model.normalizeConfig({ settings: { all_workspaces: true }, workspaces: { "2": false, "3": { width: 50, height: 50 } } })
  assert.equal(config.settings.all_workspaces, true)
  assert.equal(config.workspaces["2"], false)
  assert.equal(Model.status(config, 1).enabled, true)
  assert.equal(Model.status(config, 1).summary, "70% x 80% (default)")
  assert.equal(Model.status(config, 2).enabled, false)
  assert.equal(Model.status(config, 3).summary, "50% x 50%")
  assert.deepEqual(Model.status(config, 1).workspaces, ["3"])
  const off = Model.normalizeConfig({ workspaces: { "2": false } })
  assert.equal(Model.status(off, 1).enabled, false)
  assert.equal(Model.status(off, 2).enabled, false)
})

test("paused is read and surfaced in status", () => {
  const on = Model.parseConfig(JSON.stringify({ settings: { paused: true }, workspaces: { "1": true } }))
  assert.equal(on.settings.paused, true)
  assert.equal(Model.status(on, 1).paused, true)
  // Pausing is a runtime veto, so the workspace still reads as enabled.
  assert.equal(Model.status(on, 1).enabled, true)
  assert.equal(Model.parseConfig("{}").settings.paused, false)
})

test("named workspaces are keys like any other", () => {
  const config = Model.normalizeConfig({
    defaults: { width: 60, height: 90 },
    workspaces: { "2": { width: 70, height: 80 }, "code": true, "mail": { mode: "aspect", ratio: [4, 3] } },
  })
  assert.equal(Model.status(config, "code").enabled, true)
  assert.equal(Model.status(config, "code").summary, "60% x 90% (default)")
  assert.equal(Model.status(config, "mail").summary, "4:3")
  assert.equal(Model.status(config, "notes").enabled, false)
  // Numbers sort first and numerically, names alphabetically after them.
  assert.deepEqual(Model.status(config, "2").workspaces, ["2", "code", "mail"])
})

test("presets keep their order and name the matching entry", () => {
  const config = Model.normalizeConfig({
    presets: { reading: { width: 55, height: 85 }, square: { mode: "aspect", ratio: [1, 1] }, home: true, bad: { mode: "aspect", ratio: [0, 1] } },
    workspaces: { "2": { width: 55, height: 85 }, "3": true, "4": { width: 56, height: 85 } },
  })
  assert.deepEqual(config.presets.map(p => p.name), ["reading", "square", "home"])
  assert.equal(Model.status(config, 2).preset, "reading")
  assert.equal(Model.status(config, 3).preset, "home")
  assert.equal(Model.status(config, 4).preset, null)
  assert.deepEqual(Model.status(config, 4).presets, ["reading", "square", "home"])
})

test("monitor blocks override the defaults for a default entry", () => {
  const config = Model.normalizeConfig({
    defaults: { width: 60, height: 90 },
    monitors: { "desc:ULTRAGEAR": { width: 50, max_width: 1600 }, "eDP-1": { width: 95, height: 95 } },
    workspaces: { "3": true, "4": { width: 80, height: 80 } },
  })
  assert.deepEqual(config.monitors, [
    { key: "desc:ULTRAGEAR", width: 50, max_width: 1600 }, { key: "eDP-1", width: 95, height: 95 },
  ])
  const big = { name: "DP-1", description: "LG Electronics LG ULTRAGEAR 011NTLE85288" }
  const laptop = { name: "eDP-1", description: "BOE 0x0BCA" }
  assert.equal(Model.status(config, 3, big).summary, "50% x 90% (default)")
  assert.equal(Model.status(config, 3, laptop).summary, "95% x 95% (default)")
  assert.equal(Model.status(config, 3, { name: "HDMI-A-1", description: "" }).summary, "60% x 90% (default)")
  assert.equal(Model.status(config, 4, big).summary, "80% x 80%")
  assert.equal(Model.status(config, 3, big).monitor.key, "desc:ULTRAGEAR")
  assert.equal(Model.status(config, 3, null).monitor, null)
})

test("statusText prints a stock setup in few lines", () => {
  const config = Model.normalizeConfig({ defaults: { width: 70, height: 80 }, workspaces: { "3": true } })
  assert.equal(Model.statusText(Model.status(config, "3")), [
    "Workspace   3",
    "Inset       70% x 80% (default)",
    "Default     70% x 80%",
    "On          3",
    "Step        5, fine 1",
    "Notify      changes",
  ].join("\n"))
})

test("statusText keeps the optional rows for what is actually set", () => {
  const config = Model.normalizeConfig({
    settings: { paused: true, max_windows: 2, all_workspaces: true },
    defaults: { width: 60, height: 90, max_width: 1800, align_y: 40 },
    monitors: { "eDP-1": { width: 95, max_width: 1600 } },
    presets: { reading: { width: 55, height: 85 } },
    workspaces: { "3": { width: 55, height: 85 } },
  })
  const laptop = { name: "eDP-1", description: "BOE 0x0BCA" }
  assert.equal(Model.statusText(Model.status(config, "3", laptop)), [
    "Workspace   3",
    "Inset       55% x 85% (paused)",
    "Preset      reading",
    "Default     60% x 90%",
    "Max         width 1800px",
    "Align       50 across, 40 down",
    "Monitor     eDP-1: width 95%, max width 1600px",
    "Presets     reading",
    "On          every workspace, unless it opts out",
    "Step        5, fine 1",
    "Windows     up to 2",
    "Notify      changes",
  ].join("\n"))
})

test("statusText says so when nothing is focused or enabled", () => {
  const text = Model.statusText(Model.status(Model.defaultConfig(), null))
  assert.match(text, /^Workspace {3}none focused$/m)
  assert.match(text, /^Inset {7}off$/m)
  assert.match(text, /^On {10}no workspace yet$/m)
})

// Real `hyprctl binds` output, trimmed to one foreign bind and three of ours.
const BINDS = [
  "bindled",
  "\tmodmask: 0",
  "\tsubmap: ",
  "\tkey: XF86AudioRaiseVolume",
  "\tkeycode: 0",
  "\tcatchall: false",
  "\tdescription: Volume up",
  "\tdispatcher: __lua",
  "\targ: 6",
  "",
  "bindd",
  "\tmodmask: 76",
  "\tsubmap: ",
  "\tkey: I",
  "\tkeycode: 0",
  "\tcatchall: false",
  "\tdescription: Ichi: toggle",
  "\tdispatcher: __lua",
  "\targ: 64",
  "",
  "bindde",
  "\tmodmask: 77",
  "\tsubmap: ",
  "\tkey: SUPER + LEFT",
  "\tkeycode: 0",
  "\tcatchall: false",
  "\tdescription: Ichi: nudge left (fine)",
  "\tdispatcher: __lua",
  "\targ: 12",
  "",
  "bindd",
  "\tmodmask: 0",
  "\tsubmap: ",
  "\tkey: ",
  "\tkeycode: 20",
  "\tcatchall: false",
  "\tdescription: Ichi: by keycode",
  "\tdispatcher: __lua",
  "\targ: 1",
].join("\n")

test("ichiBinds takes only the binds a description claims for Ichi", () => {
  assert.deepEqual(Model.ichiBinds(BINDS), [
    { keys: "SUPER CTRL ALT + I", action: "toggle" },
    { keys: "SUPER SHIFT CTRL ALT + LEFT", action: "nudge left (fine)" },
    { keys: "code:20", action: "by keycode" },
  ])
})

test("ichiBinds closes the last record without a trailing blank line", () => {
  const text = "bindd\n\tmodmask: 64\n\tkey: J\n\tkeycode: 0\n\tdescription: Ichi: toggle"
  assert.deepEqual(Model.ichiBinds(text), [{ keys: "SUPER + J", action: "toggle" }])
})

const DIRECTIONS = ["LEFT", "RIGHT", "UP", "DOWN"]
function bindText(modmask, key, description) {
  return `binded\n\tmodmask: ${modmask}\n\tkey: ${key}\n\tkeycode: 0\n\tdescription: ${description}\n`
}
function arrowSet(modmask, words, suffix = "") {
  return DIRECTIONS.map((key, i) => bindText(modmask, key, "Ichi: " + words[i] + suffix)).join("\n")
}

test("ichiBinds folds the README's arrow set into two resize rows", () => {
  const words = ["narrower", "wider", "taller", "shorter"]
  const text = [bindText(76, "I", "Ichi: toggle"), arrowSet(76, words), arrowSet(77, words, " (fine)")].join("\n")
  assert.deepEqual(Model.ichiBinds(text), [
    { keys: "SUPER CTRL ALT + I", action: "toggle" },
    { keys: "SUPER CTRL ALT + arrows", action: "resize" },
    { keys: "SUPER SHIFT CTRL ALT + arrows", action: "resize (fine)" },
  ])
})

test("ichiBinds folds the older nudge descriptions the same way", () => {
  const words = ["nudge left", "nudge right", "nudge up", "nudge down"]
  const text = [arrowSet(76, words), arrowSet(77, words, " (fine)")].join("\n")
  assert.deepEqual(Model.ichiBinds(text), [
    { keys: "SUPER CTRL ALT + arrows", action: "resize" },
    { keys: "SUPER SHIFT CTRL ALT + arrows", action: "resize (fine)" },
  ])
})

test("ichiBinds keeps separate rows for a partial or unlike arrow set", () => {
  const partial = DIRECTIONS.slice(0, 3).map((key) => bindText(76, key, "Ichi: " + key.toLowerCase())).join("\n")
  assert.equal(Model.ichiBinds(partial).length, 3)
  const unlike = arrowSet(76, ["narrower", "wider", "taller", "next preset"])
  assert.equal(Model.ichiBinds(unlike).length, 4)
})

test("ichiBinds does not relabel a non-resizing arrow set as resize", () => {
  const align = arrowSet(76, ["align left", "align right", "align up", "align down"])
  assert.deepEqual(Model.ichiBinds(align).map((row) => row.action), ["align left", "align right", "align up", "align down"])
})

test("ichiBinds is empty rather than throwing on nothing", () => {
  assert.deepEqual(Model.ichiBinds(""), [])
  assert.deepEqual(Model.ichiBinds(null), [])
})

console.log(passed + " passed")

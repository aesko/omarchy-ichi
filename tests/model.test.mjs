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
  return { defaultConfig, normalizeConfig, parseConfig, needsLoader, withLoader, hyprctlEvalArgs, status, LOADER_LINE, LOADER_MARK, NOTIFY_LEVELS }
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
  assert.deepEqual(config.settings, { step: 25, fine_step: 1, notify: "always", all_workspaces: false, max_windows: 1, min_percent: 20, paused: false })
  assert.deepEqual(config.workspaces["2"], { mode: "size", width: 70, height: 80 })
  assert.deepEqual(config.workspaces["5"], { mode: "aspect", ratio: [4, 3] })
  assert.equal(config.workspaces["7"], undefined)
  assert.deepEqual(config.workspaces["8"], { mode: "default" })
  assert.deepEqual(config.workspaces["9"], { mode: "default" })
  assert.deepEqual(config.workspaces["x"], { mode: "size", width: 50, height: 50 })
})

test("settings block is read, with the pre-0.2 step location as a fallback", () => {
  const modern = Model.parseConfig(JSON.stringify({ settings: { step: 10, fine_step: 2, notify: "never", max_windows: 30 }, defaults: { step: 3 } }))
  assert.deepEqual(modern.settings, { step: 10, fine_step: 2, notify: "never", all_workspaces: false, max_windows: 10, min_percent: 20, paused: false })
  const floor = Model.parseConfig(JSON.stringify({ settings: { min_percent: 40 }, defaults: { width: 30 }, workspaces: { "1": { width: 10, height: 90 } } }))
  assert.equal(floor.settings.min_percent, 40)
  assert.equal(floor.defaults.width, 40)
  assert.equal(floor.workspaces["1"].width, 40)
  assert.equal(Model.parseConfig(JSON.stringify({ settings: { min_percent: 1 } })).settings.min_percent, 5)
  assert.equal(Model.parseConfig(JSON.stringify({ settings: { min_percent: 10 }, workspaces: { "1": { width: 12, height: 12 } } })).workspaces["1"].width, 12)
  const legacy = Model.parseConfig(JSON.stringify({ defaults: { step: 3 } }))
  assert.equal(legacy.settings.step, 3)
  const capped = Model.parseConfig(JSON.stringify({ defaults: { max_width: 1600.7, max_height: -1, align_x: 120, align_y: 40 } }))
  assert.equal(capped.defaults.max_width, 1600)
  assert.equal(capped.defaults.max_height, undefined)
  assert.equal(capped.defaults.align_x, 100)
  assert.equal(capped.defaults.align_y, 40)
  const aligned = Model.parseConfig(JSON.stringify({ monitors: { "eDP-1": { align_y: 0 } } }))
  assert.deepEqual(aligned.monitors, [{ key: "eDP-1", align_y: 0 }])
  const bogus = Model.parseConfig(JSON.stringify({ settings: { notify: "loudly" } }))
  assert.equal(bogus.settings.notify, "always")
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
    workspace: "2", enabled: true, entry: { mode: "size", width: 70, height: 80 }, summary: "70% x 80%",
    resolved: { mode: "size", width: 70, height: 80 },
    settings: { step: 5, fine_step: 1, notify: "always", all_workspaces: false, max_windows: 1, min_percent: 20, paused: false }, paused: false, defaults: { width: 70, height: 80 }, monitor: null, preset: null, presets: [], workspaces: ["2", "5"],
  })
  assert.equal(Model.status(config, 5).summary, "1:1")
  assert.equal(Model.status(config, 3).enabled, false)
  assert.equal(Model.status(config, 3).resolved, null)
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

console.log(passed + " passed")

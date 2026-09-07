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
      "x": { mode: "size", width: 50, height: 50 },
    },
  }))
  assert.deepEqual(config.defaults, { width: 60, height: 75 })
  assert.deepEqual(config.settings, { step: 25, fine_step: 1, notify: "always" })
  assert.deepEqual(config.workspaces["2"], { mode: "size", width: 70, height: 80 })
  assert.deepEqual(config.workspaces["5"], { mode: "aspect", ratio: [4, 3] })
  assert.equal(config.workspaces["7"], undefined)
  assert.equal(config.workspaces["x"], undefined)
})

test("settings block is read, with the pre-0.2 step location as a fallback", () => {
  const modern = Model.parseConfig(JSON.stringify({ settings: { step: 10, fine_step: 2, notify: "never" }, defaults: { step: 3 } }))
  assert.deepEqual(modern.settings, { step: 10, fine_step: 2, notify: "never" })
  const legacy = Model.parseConfig(JSON.stringify({ defaults: { step: 3 } }))
  assert.equal(legacy.settings.step, 3)
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
    workspace: 2, enabled: true, entry: { mode: "size", width: 70, height: 80 }, summary: "70% x 80%",
    settings: { step: 5, fine_step: 1, notify: "always" }, defaults: { width: 70, height: 80 }, workspaces: [2, 5],
  })
  assert.equal(Model.status(config, 5).summary, "1:1")
  assert.equal(Model.status(config, 3).enabled, false)
  assert.equal(Model.status(config, null).workspace, null)
})

console.log(passed + " passed")

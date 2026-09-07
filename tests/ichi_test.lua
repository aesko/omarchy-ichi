-- Exercises the pure parts of ichi.lua under a fake `hl`. Run: lua tests/ichi_test.lua
local root = (arg[0]:match("^(.*)/tests/") or ".")
local tmp = os.tmpname()
os.remove(tmp)

hl = nil -- no compositor: ichi.lua must not touch hl.on
local M = dofile(root .. "/ichi.lua")

-- A fake compositor for the paths that apply rules and notify. Installed after
-- loading so the file's own event wiring stays off.
local fake = { workspaces = {}, windows = {}, rules = {}, notes = {}, config = {}, active = nil }
hl = {
  get_workspace = function(id) return fake.workspaces[id] end,
  get_workspaces = function()
    local list = {}
    for _, ws in pairs(fake.workspaces) do list[#list + 1] = ws end
    return list
  end,
  get_workspace_windows = function(id) return fake.windows[id] or {} end,
  get_active_workspace = function() return fake.active end,
  get_config = function(key) return fake.config[key] end,
  workspace_rule = function(spec) fake.rules[tonumber(spec.workspace)] = spec.gaps_out end,
  exec_cmd = function(cmd) fake.notes[#fake.notes + 1] = cmd end,
}

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local base = { top = 10, right = 10, bottom = 10, left = 10 }
-- The numbers measured on a 2560x1440 monitor with a 26px bar.
local usable_w, usable_h = 2560, 1414

local size = M.gaps_for(usable_w, usable_h, { mode = "size", width = 70, height = 80 }, base)
check("size 70x80 horizontal gap", size.left == 384 and size.right == 384, tostring(size.left))
check("size 70x80 vertical gap", size.top == 141 and size.bottom == 141, tostring(size.top))

local full = M.gaps_for(usable_w, usable_h, { mode = "size", width = 100, height = 100 }, base)
check("size 100x100 is exactly base gaps", full.left == 10 and full.top == 10)

local aspect = M.gaps_for(usable_w, usable_h, { mode = "aspect", ratio_w = 4, ratio_h = 3 }, base)
check("aspect 4:3 is height-limited", aspect.top == 10 and aspect.left == 337, aspect.left .. "/" .. aspect.top)

local square = M.gaps_for(usable_w, usable_h, { mode = "aspect", ratio_w = 1, ratio_h = 1 }, base)
check("aspect 1:1 centres a 1414 box", square.left == 573, tostring(square.left))

local tall = M.gaps_for(1000, 2000, { mode = "aspect", ratio_w = 4, ratio_h = 3 }, base)
check("aspect 4:3 on a portrait area is width-limited", tall.left == 10 and tall.top == 625, tall.top)

local capped = M.gaps_for(usable_w, usable_h, { mode = "size", width = 70, height = 80, max_width = 1600 }, base)
check("max_width caps a size box", capped.left == 480 and capped.top == 141, capped.left)
local capped_aspect = M.gaps_for(usable_w, usable_h, { mode = "aspect", ratio_w = 4, ratio_h = 3, max_width = 1600 }, base)
check("max_width shrinks an aspect box on both sides", capped_aspect.left == 480 and capped_aspect.top == 107,
  capped_aspect.left .. "/" .. capped_aspect.top)
local uncapped = M.gaps_for(usable_w, usable_h, { mode = "size", width = 70, height = 80, max_width = 4000, max_height = 0 }, base)
check("a cap above the box does nothing", uncapped.left == 384 and uncapped.top == 141)

check("normalize clamps and floors", M.normalize_entry({ width = 12.9, height = 400 }).width == 30
  and M.normalize_entry({ width = 12.9, height = 400 }).height == 100)
check("normalize rejects a bad aspect", M.normalize_entry({ mode = "aspect", ratio_w = 0, ratio_h = 3 }) == nil)
check("normalize fills from defaults", M.normalize_entry({}, { width = 55, height = 66 }).width == 55)

local text = [[
{
  "defaults": { "width": 60, "height": 75, "step": 10 },
  "workspaces": {
    "2": { "mode": "size", "width": 70, "height": 80 },
    "5": { "mode": "aspect", "ratio": [4, 3] },
    "7": { "mode": "size", "width": "garbage" },
    "8": true,
    "x": { "mode": "size", "width": 50, "height": 50 }
  }
}
]]
local cfg = M.parse_config(text)
check("parse defaults", cfg.defaults.width == 60 and cfg.defaults.height == 75)
check("parse reads the pre-0.2 step location", cfg.settings.step == 10 and cfg.defaults.step == 10)
check("parse without settings is not chatty by accident", cfg.settings.notify == "always")
local modern = M.parse_config('{ "settings": { "step": 8, "fine_step": 2, "notify": "never" }, "defaults": { "step": 3 } }')
check("parse prefers settings.step", modern.settings.step == 8 and modern.defaults.step == 8)
check("parse reads fine_step", modern.settings.fine_step == 2 and cfg.settings.fine_step == 1)
check("parse reads notify", modern.settings.notify == "never")
check("parse rejects an unknown notify level", M.parse_config('{ "settings": { "notify": "loud" } }').settings.notify == "always")
check("parse size entry", cfg.workspaces[2] and cfg.workspaces[2].width == 70 and cfg.workspaces[2].height == 80)
check("parse aspect entry", cfg.workspaces[5] and cfg.workspaces[5].mode == "aspect" and cfg.workspaces[5].ratio_w == 4)
check("bad width falls back to defaults", cfg.workspaces[7] and cfg.workspaces[7].width == 60)
check("non-numeric workspace key is ignored", cfg.workspaces.x == nil)
check("parse reads a true entry as default mode", cfg.workspaces[8] and cfg.workspaces[8].mode == "default")
check("encode writes a default entry as true", M.encode_config(cfg):find('"8": true', 1, true) ~= nil)
check("normalize accepts true", M.normalize_entry(true).mode == "default")
check("resolve turns default into the defaults' size", M.resolve({ mode = "default" }).width == 70
  and M.resolve({ mode = "default" }).mode == "size")
check("resolve leaves a fixed entry alone", M.resolve(cfg.workspaces[5]).mode == "aspect")
local with_caps = M.parse_config('{ "defaults": { "width": 60, "height": 60, "max_width": 1500, "max_height": -3 } }')
check("parse reads caps and floors negatives at none", with_caps.defaults.max_width == 1500 and with_caps.defaults.max_height == 0)
check("encode writes only the caps that are set", M.encode_config(with_caps):find('"max_width": 1500', 1, true) ~= nil
  and M.encode_config(with_caps):find("max_height", 1, true) == nil)
check("encode omits caps by default", M.encode_config(cfg):find("max_", 1, true) == nil)
M.config = with_caps
check("resolve carries the caps onto a default entry", M.resolve({ mode = "default" }).max_width == 1500)
check("resolve carries the caps onto a fixed entry", M.resolve({ mode = "aspect", ratio_w = 1, ratio_h = 1 }).max_width == 1500)
M.config = M.parse_config("")

-- Monitors: a block overrides the defaults field by field for matching displays.
local layered = M.parse_config([[
{
  "defaults": { "width": 60, "height": 90, "max_width": 2000 },
  "monitors": {
    "desc:ULTRAGEAR": { "width": 50, "max_width": 1600 },
    "eDP-1": { "width": 95, "height": 95, "max_width": 0 }
  },
  "workspaces": { "3": true }
}
]])
check("parse reads monitor blocks in order", #layered.monitors == 2 and layered.monitors[1].key == "desc:ULTRAGEAR"
  and layered.monitors[1].width == 50 and layered.monitors[1].height == nil and layered.monitors[1].max_width == 1600
  and layered.monitors[2].key == "eDP-1" and layered.monitors[2].max_width == 0)
M.config = layered
local big = { name = "DP-1", description = "LG Electronics LG ULTRAGEAR 011NTLE85288" }
local laptop = { name = "eDP-1", description = "BOE 0x0BCA" }
local other = { name = "HDMI-A-1", description = "" }
check("desc: matches part of the description", M.monitor_block(big) == layered.monitors[1])
check("a plain key matches the connector name", M.monitor_block(laptop) == layered.monitors[2])
check("no block for an unknown monitor", M.monitor_block(other) == nil and M.monitor_block(nil) == nil)
local on_big = M.resolve({ mode = "default" }, big)
check("resolve layers the block over the defaults", on_big.width == 50 and on_big.height == 90 and on_big.max_width == 1600)
local on_laptop = M.resolve({ mode = "default" }, laptop)
check("a block can clear a cap with zero", on_laptop.width == 95 and on_laptop.max_width == 0)
check("no block means the plain defaults", M.resolve({ mode = "default" }, other).width == 60
  and M.resolve({ mode = "default" }, nil).max_width == 2000)
check("a fixed entry keeps its size but takes the monitor's caps", M.resolve({ mode = "size", width = 80, height = 80 }, big).width == 80
  and M.resolve({ mode = "size", width = 80, height = 80 }, big).max_width == 1600)
local layered_text = M.encode_config(layered)
check("encode writes the monitors block", layered_text:find('"desc:ULTRAGEAR": { "width": 50, "max_width": 1600 }', 1, true) ~= nil
  and layered_text:find('"eDP-1": { "width": 95, "height": 95 }', 1, true) ~= nil, layered_text)
check("encode/parse round-trips monitors", #M.parse_config(layered_text).monitors == 2)
check("encode omits an empty monitors block", M.encode_config(M.parse_config("")):find("monitors", 1, true) == nil)
M.config = M.parse_config("")

local again = M.parse_config(M.encode_config(cfg))
check("encode/parse round-trips", again.workspaces[2].width == 70 and again.workspaces[5].ratio_h == 3
  and again.settings.step == 10 and again.workspaces[8].mode == "default")
check("encode writes step under settings", M.encode_config(cfg):find('"settings": { "step": 10, "fine_step": 1, "notify": "always" }', 1, true) ~= nil)

check("empty text gives defaults", M.parse_config("").defaults.width == 70 and next(M.parse_config("").workspaces) == nil)

-- Legacy import, oldest format: no JSON yet, an "<id> <width> <height>" file.
M.config_path = tmp .. ".json"
M.legacy_json_path = tmp .. ".legacy.json"
M.legacy_lines_path = tmp .. ".legacy"
local legacy = io.open(M.legacy_lines_path, "w")
legacy:write("2 70 80\n5 65 90\n")
legacy:close()
M.load()
check("line import reads both lines", M.config.workspaces[2] and M.config.workspaces[5]
  and M.config.workspaces[5].height == 90)
local written = io.open(M.config_path, "r")
check("line import writes the JSON once", written ~= nil)
if written then
  written:close()
end
M.load()
check("second load prefers the JSON", M.config.workspaces[2].width == 70)

-- Legacy import, pre-rename JSON: preferred over the line file when both exist.
os.remove(M.config_path)
local renamed = io.open(M.legacy_json_path, "w")
renamed:write('{ "defaults": { "width": 60, "height": 75, "step": 10 }, "workspaces": { "3": { "mode": "aspect", "ratio": [1, 1] } } }')
renamed:close()
M.load()
check("json import wins over the line file", M.config.workspaces[3] and M.config.workspaces[3].mode == "aspect"
  and M.config.workspaces[2] == nil and M.config.settings.step == 10)
check("json import writes the new file", io.open(M.config_path, "r") ~= nil)
os.remove(M.legacy_json_path)
-- Back to the line-file fixture (workspaces 2 and 5) for the defaults tests.
os.remove(M.config_path)
M.load()

-- Defaults: adjustable, clamped, zero means keep, and adoptable from a workspace.
M.set_defaults(65, 85, 10)
check("set_defaults stores all three", M.config.defaults.width == 65 and M.config.defaults.height == 85
  and M.config.settings.step == 10 and M.config.defaults.step == 10)
M.set_defaults(0, 400, 0)
check("set_defaults keeps zeros and clamps", M.config.defaults.width == 65 and M.config.defaults.height == 100
  and M.config.settings.step == 10)
check("set_defaults leaves existing workspaces alone", M.config.workspaces[2].width == 70)
check("set_defaults persists", M.parse_config(io.open(M.config_path):read("*a")).defaults.width == 65)
M.adopt_defaults(5)
check("adopt_defaults copies a size entry", M.config.defaults.width == 65 and M.config.defaults.height == 90)
M.config.workspaces[5] = { mode = "aspect", ratio_w = 4, ratio_h = 3 }
M.adopt_defaults(5)
check("adopt_defaults ignores an aspect entry", M.config.defaults.height == 90)
M.adopt_defaults(9)
check("adopt_defaults ignores an unknown workspace", M.config.defaults.height == 90)

-- Default entries: enabling follows the defaults and tracks changes to them.
fake.config["general.gaps_out"] = base
-- The window and its workspace report the same monitor, as in the compositor.
local screen = { name = "DP-1", description = "LG ULTRAGEAR", width = 2560, height = 1440, reserved = { top = 26 } }
fake.workspaces[4] = { id = 4, tiled_layout = "dwindle", monitor = screen }
fake.windows[4] = { { floating = false, monitor = screen } }
M.set_defaults(70, 80)
fake.notes = {}
M.enable(4)
check("enable without an entry follows the defaults", M.config.workspaces[4].mode == "default")
check("enable says so", fake.notes[1] and fake.notes[1]:find("70% x 80% (default)", 1, true) ~= nil, fake.notes[1])
check("a default entry is applied at the defaults' size", fake.rules[4] and fake.rules[4].left == 384, fake.rules[4] and fake.rules[4].left)
M.set_defaults(50, 100)
check("changing the defaults reaches a default entry", fake.rules[4].left == 640 and fake.rules[4].top == 10)
check("the file keeps the entry as true", io.open(M.config_path):read("*a"):find('"4": true', 1, true) ~= nil)
M.adjust(10, 0, 4)
check("nudging a default entry fixes it from the defaults", M.config.workspaces[4].mode == "size"
  and M.config.workspaces[4].width == 60 and M.config.workspaces[4].height == 100)
M.reset(4)
check("reset goes back to following the defaults", M.config.workspaces[4].mode == "default")
M.adjust(-5, -5, 4)
M.adopt_defaults(4)
check("adopt copies the size into the defaults", M.config.defaults.width == 45 and M.config.defaults.height == 95)
check("adopt leaves the workspace following the defaults", M.config.workspaces[4].mode == "default")
M.set_max(1000, 0)
check("set_max caps the applied box", fake.rules[4].left == 780, fake.rules[4].left)
check("set_max persists", M.parse_config(io.open(M.config_path):read("*a")).defaults.max_width == 1000)
M.set_max(0, 0)
check("set_max zero removes the cap", fake.rules[4].left == 704, fake.rules[4].left)
M.adjust(-15, 0, 4) -- 45 x 95 -> 30 x 95
M.adopt_defaults(4, "monitor")
check("adopt monitor writes a desc: block", #M.config.monitors == 1 and M.config.monitors[1].key == "desc:LG ULTRAGEAR"
  and M.config.monitors[1].width == 30 and M.config.monitors[1].height == 95)
check("adopt monitor leaves the global defaults alone", M.config.defaults.width == 45)
check("adopt monitor puts the workspace back on default", M.config.workspaces[4].mode == "default")
check("adopt monitor applies the block", fake.rules[4].left == 896, fake.rules[4].left)
M.adjust(10, 0, 4)
M.adopt_defaults(4, "monitor")
check("adopt monitor updates an existing block", #M.config.monitors == 1 and M.config.monitors[1].width == 40)
M.config.monitors = {}
M.reset(4)
M.disable(4)
check("disable resets the gaps", fake.rules[4].left == 10)
M.set_defaults(65, 90)

-- Steps, nudges and notification levels, on a workspace of a known size.
M.set_step(12, 3)
check("set_step stores both and mirrors the old alias", M.config.settings.step == 12 and M.config.settings.fine_step == 3
  and M.config.defaults.step == 12)
M.set_step(0, 0)
check("set_step keeps zeros", M.config.settings.step == 12 and M.config.settings.fine_step == 3)
M.config.workspaces[2] = { mode = "size", width = 70, height = 80 }
M.nudge(-1, 0, false, 2)
check("nudge scales by the step", M.config.workspaces[2].width == 58)
M.nudge(0, 1, true, 2)
check("nudge fine scales by the fine step", M.config.workspaces[2].height == 83)
M.set_notify("never")
check("set_notify stores a known level", M.config.settings.notify == "never")
fake.notes = {}
M.nudge(1, 0, false, 2)
check("notify never is silent", #fake.notes == 0)
M.set_notify("changes")
fake.notes = {}
M.nudge(-1, 0, false, 2)
check("notify changes skips nudges", #fake.notes == 0)
M.toggle(2)
check("notify changes reports a toggle", #fake.notes == 1)
M.set_notify("always")
fake.notes = {}
M.nudge(1, 0, false, 2)
check("notify always reports a nudge", #fake.notes == 1)
M.set_notify("loud")
check("set_notify ignores an unknown level", M.config.settings.notify == "always")
M.set_notify("never")
check("set_notify persists", M.parse_config(io.open(M.config_path):read("*a")).settings.notify == "never")
M.set_notify("always")
os.remove(M.config_path)
os.remove(M.legacy_lines_path)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")

-- Exercises the pure parts of ichi.lua under a fake `hl`. Run: lua tests/ichi_test.lua
local root = (arg[0]:match("^(.*)/tests/") or ".")
local tmp = os.tmpname()
os.remove(tmp)

hl = nil -- no compositor: ichi.lua must not touch hl.on
local M = dofile(root .. "/ichi.lua")

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
    "x": { "mode": "size", "width": 50, "height": 50 }
  }
}
]]
local cfg = M.parse_config(text)
check("parse defaults", cfg.defaults.width == 60 and cfg.defaults.height == 75)
check("parse reads the pre-0.2 step location", cfg.settings.step == 10 and cfg.defaults.step == 10)
check("parse without settings is not chatty by accident", cfg.settings.notify == "always")
local modern = M.parse_config('{ "settings": { "step": 8, "notify": "never" }, "defaults": { "step": 3 } }')
check("parse prefers settings.step", modern.settings.step == 8 and modern.defaults.step == 8)
check("parse reads notify", modern.settings.notify == "never")
check("parse rejects an unknown notify level", M.parse_config('{ "settings": { "notify": "loud" } }').settings.notify == "always")
check("parse size entry", cfg.workspaces[2] and cfg.workspaces[2].width == 70 and cfg.workspaces[2].height == 80)
check("parse aspect entry", cfg.workspaces[5] and cfg.workspaces[5].mode == "aspect" and cfg.workspaces[5].ratio_w == 4)
check("bad width falls back to defaults", cfg.workspaces[7] and cfg.workspaces[7].width == 60)
check("non-numeric workspace key is ignored", cfg.workspaces.x == nil)

local again = M.parse_config(M.encode_config(cfg))
check("encode/parse round-trips", again.workspaces[2].width == 70 and again.workspaces[5].ratio_h == 3
  and again.settings.step == 10)
check("encode writes step under settings", M.encode_config(cfg):find('"settings": { "step": 10, "notify": "always" }', 1, true) ~= nil)

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
M.set_notify("never")
check("set_notify stores a known level", M.config.settings.notify == "never")
M.set_notify("loud")
check("set_notify ignores an unknown level", M.config.settings.notify == "never")
check("set_notify persists", M.parse_config(io.open(M.config_path):read("*a")).settings.notify == "never")
M.set_notify("always")
check("set_defaults leaves existing workspaces alone", M.config.workspaces[2].width == 70)
check("set_defaults persists", M.parse_config(io.open(M.config_path):read("*a")).defaults.width == 65)
M.adopt_defaults(5)
check("adopt_defaults copies a size entry", M.config.defaults.width == 65 and M.config.defaults.height == 90)
M.config.workspaces[5] = { mode = "aspect", ratio_w = 4, ratio_h = 3 }
M.adopt_defaults(5)
check("adopt_defaults ignores an aspect entry", M.config.defaults.height == 90)
M.adopt_defaults(9)
check("adopt_defaults ignores an unknown workspace", M.config.defaults.height == 90)
os.remove(M.config_path)
os.remove(M.legacy_lines_path)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")

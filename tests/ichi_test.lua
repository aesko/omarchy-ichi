-- Exercises the pure parts of ichi.lua under a fake `hl`. Run: lua tests/ichi_test.lua
local root = (arg[0]:match("^(.*)/tests/") or ".")
local tmp = os.tmpname()
os.remove(tmp)

hl = nil -- no compositor: ichi.lua must not touch hl.on
local M = dofile(root .. "/ichi.lua")

-- Every path the module reads or writes goes to a temp file from the start;
-- anything that commits (cycle, save_preset, adopt, ...) saves.
M.config_path = tmp .. ".json"
-- The pre-0.7 path too: with nothing at config_path, load and save would
-- otherwise reach the real ~/.config/omarchy/ichi.json of whoever runs this.
M.previous_config_path = tmp .. ".previous.json"

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
  workspace_rule = function(spec) fake.rules[spec.workspace] = spec.gaps_out end,
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

local left_aligned = M.gaps_for(usable_w, usable_h, { mode = "size", width = 70, height = 80, align_x = 0 }, base)
check("align_x 0 puts the box at the left edge, base gap kept", left_aligned.left == 10 and left_aligned.right == 768
  and left_aligned.top == 141, left_aligned.left .. "/" .. left_aligned.right)
local bottom_aligned = M.gaps_for(usable_w, usable_h, { mode = "size", width = 70, height = 80, align_y = 100 }, base)
check("align_y 100 puts the box at the bottom", bottom_aligned.top == 282 and bottom_aligned.bottom == 10
  and bottom_aligned.left == 384, bottom_aligned.top .. "/" .. bottom_aligned.bottom)
local raised = M.gaps_for(usable_w, usable_h, { mode = "size", width = 70, height = 80, align_y = 40 }, base)
check("align_y 40 sits a little above centre", raised.top == 113 and raised.bottom == 169, raised.top .. "/" .. raised.bottom)
local aligned_aspect = M.gaps_for(usable_w, usable_h, { mode = "aspect", ratio_w = 4, ratio_h = 3, align_x = 100 }, base)
check("alignment applies to an aspect box too", aligned_aspect.left == 674 and aligned_aspect.right == 10, aligned_aspect.left)

local capped = M.gaps_for(usable_w, usable_h, { mode = "size", width = 70, height = 80, max_width = 1600 }, base)
check("max_width caps a size box", capped.left == 480 and capped.top == 141, capped.left)
local capped_aspect = M.gaps_for(usable_w, usable_h, { mode = "aspect", ratio_w = 4, ratio_h = 3, max_width = 1600 }, base)
check("max_width shrinks an aspect box on both sides", capped_aspect.left == 480 and capped_aspect.top == 107,
  capped_aspect.left .. "/" .. capped_aspect.top)
local uncapped = M.gaps_for(usable_w, usable_h, { mode = "size", width = 70, height = 80, max_width = 4000, max_height = 0 }, base)
check("a cap above the box does nothing", uncapped.left == 384 and uncapped.top == 141)

check("normalize clamps and floors", M.normalize_entry({ width = 12.9, height = 400 }).width == 12
  and M.normalize_entry({ width = 12.9, height = 400 }).height == 100)
check("normalize stops at the fixed floor", M.normalize_entry({ width = 4, height = 9.5 }).width == 10
  and M.normalize_entry({ width = 4, height = 9.5 }).height == 10)
check("normalize rejects a bad aspect", M.normalize_entry({ mode = "aspect", ratio_w = 0, ratio_h = 3 }) == nil)
check("normalize fills from defaults", M.normalize_entry({}, { width = 55, height = 66 }).width == 55)

local text = [[
{
  "settings": { "step": 10 },
  "defaults": { "width": 60, "height": 75 },
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
check("parse reads step from settings", cfg.settings.step == 10 and cfg.defaults.step == nil)
check("parse defaults to reporting changes, not every nudge", cfg.settings.notify == "changes")
local modern = M.parse_config('{ "settings": { "step": 8, "fine_step": 2, "notify": "never" }, "defaults": { "step": 3 } }')
check("parse ignores a step under defaults, where it lived before 0.2", modern.settings.step == 8
  and modern.defaults.step == nil and M.parse_config('{ "defaults": { "step": 3 } }').settings.step == 5)
check("parse reads fine_step", modern.settings.fine_step == 2 and cfg.settings.fine_step == 1)
check("parse reads notify", modern.settings.notify == "never")
check("parse defaults all_workspaces to off", modern.settings.all_workspaces == false)
check("parse defaults max_windows to one", modern.settings.max_windows == 1)
check("parse defaults paused to false", modern.settings.paused == false)
check("parse reads paused", M.parse_config('{ "settings": { "paused": true } }').settings.paused == true)
local floored = M.parse_config('{ "settings": { "min_percent": 40 }, "defaults": { "width": 5 }, "workspaces": { "1": { "width": 3, "height": 12 } } }')
check("parse clamps sizes to the fixed floor", floored.defaults.width == 10 and floored.workspaces["1"].width == 10
  and floored.workspaces["1"].height == 12)
check("parse ignores min_percent, which is gone", floored.settings.min_percent == nil
  and M.encode_config(floored):find("min_percent", 1, true) == nil)
check("parse clamps max_windows", M.parse_config('{ "settings": { "max_windows": 40 } }').settings.max_windows == 10
  and M.parse_config('{ "settings": { "max_windows": 0 } }').settings.max_windows == 1)
local everywhere = M.parse_config('{ "settings": { "all_workspaces": true }, "workspaces": { "2": false, "3": true } }')
check("parse reads all_workspaces and false entries", everywhere.settings.all_workspaces == true
  and everywhere.workspaces["2"] == false and everywhere.workspaces["3"].mode == "default")
check("encode writes all_workspaces and false entries", M.encode_config(everywhere):find('"all_workspaces": true', 1, true) ~= nil
  and M.encode_config(everywhere):find('"2": false', 1, true) ~= nil)
M.config = everywhere
check("entry_for follows the defaults when nothing is written", M.entry_for(9) and M.entry_for(9).mode == "default")
check("entry_for honours an explicit off", M.entry_for(2) == nil)
check("entry_for keeps an explicit entry", M.entry_for(3).mode == "default")
M.config = M.parse_config("")
check("entry_for is off by default when nothing is written", M.entry_for(9) == nil)
check("parse rejects an unknown notify level", M.parse_config('{ "settings": { "notify": "loud" } }').settings.notify == "changes")
check("parse size entry", cfg.workspaces["2"] and cfg.workspaces["2"].width == 70 and cfg.workspaces["2"].height == 80)
check("parse aspect entry", cfg.workspaces["5"] and cfg.workspaces["5"].mode == "aspect" and cfg.workspaces["5"].ratio_w == 4)
check("bad width falls back to defaults", cfg.workspaces["7"] and cfg.workspaces["7"].width == 60)
check("a named workspace is a key like any other", cfg.workspaces.x
  and cfg.workspaces.x.width == 50)
check("parse reads a true entry as default mode", cfg.workspaces["8"] and cfg.workspaces["8"].mode == "default")
check("encode writes a default entry as true", M.encode_config(cfg):find('"8": true', 1, true) ~= nil)
check("normalize accepts true", M.normalize_entry(true).mode == "default")
check("resolve turns default into the defaults' size", M.resolve({ mode = "default" }).width == 70
  and M.resolve({ mode = "default" }).mode == "size")
check("resolve leaves a fixed entry alone", M.resolve(cfg.workspaces["5"]).mode == "aspect")
local with_caps = M.parse_config('{ "defaults": { "width": 60, "height": 60, "max_width": 1500, "max_height": -3 } }')
check("parse reads caps and floors negatives at none", with_caps.defaults.max_width == 1500 and with_caps.defaults.max_height == 0)
check("parse defaults alignment to the centre", with_caps.defaults.align_x == 50 and with_caps.defaults.align_y == 50)
check("parse clamps alignment", M.parse_config('{ "defaults": { "align_x": 120, "align_y": -4 } }').defaults.align_x == 100
  and M.parse_config('{ "defaults": { "align_x": 120, "align_y": -4 } }').defaults.align_y == 0)
local with_align = M.parse_config('{ "defaults": { "align_x": 50, "align_y": 40 }, "monitors": { "eDP-1": { "align_y": 0 } } }')
check("parse reads alignment in a monitor block", with_align.monitors[1].align_y == 0 and with_align.monitors[1].align_x == nil)
check("encode writes alignment only off centre", M.encode_config(with_align):find('"align_y": 40', 1, true) ~= nil
  and M.encode_config(with_align):find('"align_x"', 1, true) == nil
  and M.encode_config(with_align):find('"eDP-1": { "align_y": 0 }', 1, true) ~= nil, M.encode_config(with_align))
M.config = with_align
check("resolve carries alignment, layered by monitor", M.resolve({ mode = "default" }).align_y == 40
  and M.resolve({ mode = "default" }, { name = "eDP-1" }).align_y == 0
  and M.resolve({ mode = "default" }, { name = "eDP-1" }).align_x == 50)
M.config = M.parse_config("")
check("encode writes only the caps that are set", M.encode_config(with_caps):find('"max_width": 1500', 1, true) ~= nil
  and M.encode_config(with_caps):find("max_height", 1, true) == nil)
check("encode omits caps by default", M.encode_config(cfg):find("max_width", 1, true) == nil
  and M.encode_config(cfg):find("max_height", 1, true) == nil)
M.config = with_caps
check("resolve carries the caps onto a default entry", M.resolve({ mode = "default" }).max_width == 1500)
check("resolve carries the caps onto a fixed entry", M.resolve({ mode = "aspect", ratio_w = 1, ratio_h = 1 }).max_width == 1500)
M.config = M.parse_config("")

-- Presets: parsed in file order, cycled in that order, saved from a workspace.
local with_presets = M.parse_config([[
{
  "presets": {
    "reading": { "mode": "size", "width": 55, "height": 85 },
    "square": { "mode": "aspect", "ratio": [1, 1] },
    "home": true,
    "bad": { "mode": "aspect", "ratio": [0, 1] }
  },
  "workspaces": { "2": { "mode": "size", "width": 55, "height": 85 } }
}
]])
check("parse keeps preset order and drops a bad one", #with_presets.presets == 3 and with_presets.presets[1].name == "reading"
  and with_presets.presets[2].entry.mode == "aspect" and with_presets.presets[3].entry.mode == "default")
local presets_text = M.encode_config(with_presets)
check("encode writes presets in order", presets_text:find('"reading": { "mode": "size", "width": 55, "height": 85 },\n    "square": { "mode": "aspect", "ratio": [1, 1] },\n    "home": true', 1, true) ~= nil, presets_text)
check("encode/parse round-trips presets", #M.parse_config(presets_text).presets == 3)
check("encode omits an empty presets block", M.encode_config(M.parse_config("")):find("presets", 1, true) == nil)
M.config = with_presets
M.cycle(1, 2)
check("cycle moves from a matching preset to the next", M.config.workspaces["2"].mode == "aspect")
M.cycle(1, 2)
check("cycle reaches the default preset", M.config.workspaces["2"].mode == "default")
M.cycle(1, 2)
check("cycle wraps around", M.config.workspaces["2"].mode == "size" and M.config.workspaces["2"].width == 55)
M.cycle(-1, 2)
check("cycle backwards wraps the other way", M.config.workspaces["2"].mode == "default")
M.config.workspaces["2"] = { mode = "size", width = 61, height = 61 }
M.cycle(1, 2)
check("cycle from an unmatched size starts at the first", M.config.workspaces["2"].width == 55)
M.config.workspaces["2"] = { mode = "size", width = 61, height = 61 }
M.cycle(-1, 2)
check("cycle backwards from an unmatched size starts at the last", M.config.workspaces["2"].mode == "default")
M.cycle(1, 9)
check("cycle turns an off workspace on with the first preset", M.config.workspaces["9"] and M.config.workspaces["9"].width == 55)
M.preset("square", 9)
check("preset by name", M.config.workspaces["9"].mode == "aspect")
M.preset("nope", 9)
check("an unknown preset changes nothing", M.config.workspaces["9"].mode == "aspect")
M.config.workspaces["9"] = { mode = "size", width = 40, height = 40 }
M.save_preset("tiny", 9)
check("save_preset appends", #M.config.presets == 4 and M.config.presets[4].name == "tiny" and M.config.presets[4].entry.width == 40)
M.config.workspaces["9"] = { mode = "size", width = 41, height = 41 }
M.save_preset("tiny", 9)
check("save_preset replaces by name in place", #M.config.presets == 4 and M.config.presets[4].entry.width == 41)
M.remove_preset("square")
check("remove_preset drops it", #M.config.presets == 3 and M.config.presets[2].name == "home")
M.config.workspaces["9"] = nil
fake.notes = {}
M.config.presets = {}
M.cycle(1, 2)
check("cycle with no presets says so", #fake.notes == 1 and fake.notes[1]:find("no presets", 1, true) ~= nil)
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
check("encode/parse round-trips", again.workspaces["2"].width == 70 and again.workspaces["5"].ratio_h == 3
  and again.settings.step == 10 and again.workspaces["8"].mode == "default")
check("encode writes step under settings", M.encode_config(cfg):find('"settings": { "step": 10, "fine_step": 1, "notify": "changes", "all_workspaces": false, "max_windows": 1, "paused": false }', 1, true) ~= nil)

check("empty text gives defaults", M.parse_config("").defaults.width == 70 and next(M.parse_config("").workspaces) == nil)

-- No file yet: defaults, and nothing written until something changes.
os.remove(M.config_path)
M.load()
check("with no file, load gives the defaults", M.config.defaults.width == 70 and next(M.config.workspaces) == nil)
check("load alone writes nothing", io.open(M.config_path, "r") == nil)

-- The fixture the defaults tests below build on: workspaces 2 and 5.
local fixture = io.open(M.config_path, "w")
fixture:write('{ "workspaces": { "2": { "mode": "size", "width": 70, "height": 80 }, "5": { "mode": "size", "width": 65, "height": 90 } } }')
fixture:close()
M.load()
check("load reads the file", M.config.workspaces["2"].width == 70 and M.config.workspaces["5"].height == 90)

-- Defaults: adjustable, clamped, zero means keep, and adoptable from a workspace.
M.set_defaults(65, 85, 10)
check("set_defaults stores all three", M.config.defaults.width == 65 and M.config.defaults.height == 85
  and M.config.settings.step == 10)
M.set_defaults(0, 400, 0)
check("set_defaults keeps zeros and clamps", M.config.defaults.width == 65 and M.config.defaults.height == 100
  and M.config.settings.step == 10)
check("set_defaults leaves existing workspaces alone", M.config.workspaces["2"].width == 70)
check("set_defaults persists", M.parse_config(io.open(M.config_path):read("*a")).defaults.width == 65)
M.adopt_defaults(5)
check("adopt_defaults copies a size entry", M.config.defaults.width == 65 and M.config.defaults.height == 90)
M.config.workspaces["5"] = { mode = "aspect", ratio_w = 4, ratio_h = 3 }
fake.notes = {}
M.adopt_defaults(5)
check("adopt_defaults ignores an aspect entry", M.config.defaults.height == 90)
check("adopt_defaults says why on an aspect entry", #fake.notes == 1
  and fake.notes[1]:find("aspect ratio", 1, true) ~= nil, fake.notes[1])
fake.notes = {}
M.adopt_defaults(9)
check("adopt_defaults ignores an unknown workspace", M.config.defaults.height == 90)
check("adopt_defaults says why on a workspace that is off", #fake.notes == 1
  and fake.notes[1]:find("is off", 1, true) ~= nil, fake.notes[1])
M.config.workspaces["9"] = { mode = "default" }
fake.notes = {}
M.adopt_defaults(9)
check("adopt_defaults ignores a workspace that already follows the defaults", M.config.defaults.height == 90)
check("adopt_defaults says why on a default entry", #fake.notes == 1
  and fake.notes[1]:find("already follows the defaults", 1, true) ~= nil, fake.notes[1])
M.config.workspaces["9"] = nil

-- Default entries: enabling follows the defaults and tracks changes to them.
fake.config["general.gaps_out"] = base
-- The window and its workspace report the same monitor, as in the compositor.
local screen = { name = "DP-1", description = "LG ULTRAGEAR", width = 2560, height = 1440, reserved = { top = 26 } }
fake.workspaces[4] = { id = 4, name = "4", config_name = "4", tiled_layout = "dwindle", monitor = screen }
fake.windows[4] = { { floating = false, monitor = screen } }
M.set_defaults(70, 80)
fake.notes = {}
M.enable(4)
check("enable without an entry follows the defaults", M.config.workspaces["4"].mode == "default")
check("enable says so", fake.notes[1] and fake.notes[1]:find("70% x 80% (default)", 1, true) ~= nil, fake.notes[1])
check("a default entry is applied at the defaults' size", fake.rules["4"] and fake.rules["4"].left == 384, fake.rules["4"] and fake.rules["4"].left)
-- The same screen as a 5K panel at scale 2: gaps are in scaled units, so the
-- rule must match the scale-1 one rather than doubling.
local hidpi = { name = "DP-2", width = 5120, height = 2880, scale = 2, reserved = { top = 26 } }
fake.windows[4] = { { floating = false, monitor = hidpi } }
M.refresh()
check("a scaled monitor is inset by its scaled size", fake.rules["4"].left == 384 and fake.rules["4"].top == 141,
  fake.rules["4"].left .. " " .. fake.rules["4"].top)
fake.windows[4] = { { floating = false, monitor = screen } }
M.refresh()
local lw, lh = M.logical_size({ width = 2880, height = 1800, scale = 1.5 })
check("logical_size divides by a fractional scale", lw == 1920 and lh == 1200, lw .. "x" .. lh)
lw, lh = M.logical_size({ width = 2560, height = 1440, scale = 2, transform = 1 })
check("logical_size swaps a monitor turned a quarter", lw == 720 and lh == 1280, lw .. "x" .. lh)
lw, lh = M.logical_size({ width = 2560, height = 1440, transform = 2 })
check("logical_size keeps a half turn and a missing scale as they are", lw == 2560 and lh == 1440, lw .. "x" .. lh)
M.set_defaults(50, 100)
check("changing the defaults reaches a default entry", fake.rules["4"].left == 640 and fake.rules["4"].top == 10)
check("the file keeps the entry as true", io.open(M.config_path):read("*a"):find('"4": true', 1, true) ~= nil)
M.adjust(10, 0, 4)
check("nudging a default entry fixes it from the defaults", M.config.workspaces["4"].mode == "size"
  and M.config.workspaces["4"].width == 60 and M.config.workspaces["4"].height == 100)
M.reset(4)
check("reset goes back to following the defaults", M.config.workspaces["4"].mode == "default")
M.adjust(-5, -5, 4)
M.adopt_defaults(4)
check("adopt copies the size into the defaults", M.config.defaults.width == 45 and M.config.defaults.height == 95)
check("adopt leaves the workspace following the defaults", M.config.workspaces["4"].mode == "default")
M.set_max(1000, 0)
check("set_max caps the applied box", fake.rules["4"].left == 780, fake.rules["4"].left)
check("set_max persists", M.parse_config(io.open(M.config_path):read("*a")).defaults.max_width == 1000)
M.set_max(0, 0)
check("set_max zero removes the cap", fake.rules["4"].left == 704, fake.rules["4"].left)
M.set_align(nil, 0)
check("set_align moves the applied box to the top", fake.rules["4"].top == 10 and fake.rules["4"].bottom > 10 and fake.rules["4"].left == 704)
check("set_align persists", M.parse_config(io.open(M.config_path):read("*a")).defaults.align_y == 0)
M.set_align(50, 50)
check("set_align back to centre", fake.rules["4"].top == fake.rules["4"].bottom)
M.adjust(-15, 0, 4) -- 45 x 95 -> 30 x 95
M.adopt_defaults(4, "monitor")
check("adopt monitor writes a desc: block", #M.config.monitors == 1 and M.config.monitors[1].key == "desc:LG ULTRAGEAR"
  and M.config.monitors[1].width == 30 and M.config.monitors[1].height == 95)
check("adopt monitor leaves the global defaults alone", M.config.defaults.width == 45)
check("adopt monitor puts the workspace back on default", M.config.workspaces["4"].mode == "default")
check("adopt monitor applies the block", fake.rules["4"].left == 896, fake.rules["4"].left)
M.adjust(10, 0, 4)
M.adopt_defaults(4, "monitor")
check("adopt monitor updates an existing block", #M.config.monitors == 1 and M.config.monitors[1].width == 40)
M.config.monitors = {}

-- Switching a whole display off. A second monitor, with a workspace of its
-- own on it, is what proves the veto stops at the display it names.
local other_screen = { name = "eDP-1", description = "Acme Laptop", width = 2560, height = 1440, reserved = { top = 26 } }
fake.workspaces[7] = { id = 7, name = "7", config_name = "7", tiled_layout = "dwindle", monitor = other_screen }
fake.windows[7] = { { floating = false, monitor = other_screen } }
M.enable(7)
local inset = fake.rules["7"].left
check("the second display insets too", inset > 10 and fake.rules["4"].left == inset,
  inset .. "/" .. fake.rules["4"].left)

fake.notes = {}
M.set_monitor_enabled(false, 4)
check("a display switched off goes back to plain gaps", fake.rules["4"].left == 10, fake.rules["4"].left)
check("switching a display off leaves the other alone", fake.rules["7"].left == inset, fake.rules["7"].left)
check("switching a display off keeps the workspace's entry", M.config.workspaces["4"] ~= nil)
check("switching a display off writes a block keyed by description",
  #M.config.monitors == 1 and M.config.monitors[1].key == "desc:LG ULTRAGEAR"
  and M.config.monitors[1].enabled == false)
check("switching a display off says which one", fake.notes[1] and fake.notes[1]:find("off on desc:LG ULTRAGEAR", 1, true) ~= nil, fake.notes[1])
check("monitor_enabled reports the veto", M.monitor_enabled(screen) == false and M.monitor_enabled(other_screen) == true)

local off_text = M.encode_config(M.config)
check("encode writes the veto", off_text:find('"desc:LG ULTRAGEAR": { "enabled": false }', 1, true) ~= nil, off_text:match('"monitors".-\n'))
check("encode/parse round-trips the veto", M.parse_config(off_text).monitors[1].enabled == false)
check("a non-boolean enabled leaves the display on",
  M.parse_config('{ "monitors": { "eDP-1": { "enabled": "no" } } }').monitors[1].enabled == nil)
check("enabled true is not stored as a veto",
  M.parse_config('{ "monitors": { "eDP-1": { "enabled": true } } }').monitors[1].enabled == nil)

-- Nudging a workspace on a display that is off still records the size; the
-- display decides whether Ichi runs there, not what the workspace wants.
M.adjust(5, 0, 4)
check("a workspace on a display that is off keeps taking sizes", M.config.workspaces["4"].mode == "size")
check("but is still not inset", fake.rules["4"].left == 10, fake.rules["4"].left)

M.set_monitor_enabled(true, 4)
check("switching a display back on restores the inset", fake.rules["4"].left ~= 10, fake.rules["4"].left)
check("switching back on drops a block that held nothing else", #M.config.monitors == 0)

M.adopt_defaults(4, "monitor")
M.set_monitor_enabled(false, 4)
check("switching off keeps a block that carries a size",
  #M.config.monitors == 1 and M.config.monitors[1].width ~= nil and M.config.monitors[1].enabled == false)
local kept_text = M.encode_config(M.config)
check("encode keeps the size alongside the veto", kept_text:find('"enabled": false', 1, true) ~= nil
  and kept_text:find('"width"', 1, true) ~= nil)
M.set_monitor_enabled(true, 4)
check("switching on keeps a block that carries a size", #M.config.monitors == 1 and M.config.monitors[1].enabled == nil)

M.toggle_monitor(4)
check("toggle_monitor switches a display off", M.monitor_enabled(screen) == false)
M.toggle_monitor(4)
check("toggle_monitor switches it back on", M.monitor_enabled(screen) == true)

-- Pause is the wider veto, so it wins wherever the two meet.
M.set_monitor_enabled(false, 4)
M.set_paused(true)
check("pause covers a display that is already off", fake.rules["4"].left == 10 and fake.rules["7"].left == 10)
M.set_paused(false)
check("unpausing leaves the display off", fake.rules["4"].left == 10 and fake.rules["7"].left == inset,
  fake.rules["4"].left .. "/" .. fake.rules["7"].left)
M.set_monitor_enabled(true, 4)

-- A description with a quote in it cannot be a key: the reader does not
-- unescape keys, and with the quote taken out it is no longer part of the
-- description. The connector name is what still finds the display.
local quoted_desc = other_screen.description
other_screen.description = 'Acme "27" Laptop'
M.config.monitors = {}
M.set_monitor_enabled(false, 7)
check("a quoted description keys the block by connector name",
  #M.config.monitors == 1 and M.config.monitors[1].key == "eDP-1", M.config.monitors[1] and M.config.monitors[1].key)
check("and the block it wrote switches that display off", M.monitor_enabled(other_screen) == false
  and fake.rules["7"].left == 10, fake.rules["7"].left)
M.toggle_monitor(7)
M.toggle_monitor(7)
check("toggling it does not pile up blocks", #M.config.monitors == 1, #M.config.monitors)
M.set_monitor_enabled(true, 7)
check("and switching it on drops the block again", #M.config.monitors == 0)
M.adjust(5, 0, 7)
M.adopt_defaults(7, "monitor")
check("adopt monitor keys a quoted description by connector name too",
  #M.config.monitors == 1 and M.config.monitors[1].key == "eDP-1" and M.monitor_block(other_screen) == M.config.monitors[1])
M.config.monitors = {}
other_screen.description = quoted_desc

M.disable(7)
fake.workspaces[7] = nil
fake.windows[7] = nil
M.config.monitors = {}
M.reset(4)
M.disable(4)
check("disable resets the gaps", fake.rules["4"].left == 10)
M.set_defaults(65, 90)

-- The floor: fixed, so nudging stops there and a stored size never moves.
M.config.workspaces["4"] = { mode = "size", width = 15, height = 15 }
M.adjust(-10, 0, 4)
check("nudging stops at the fixed floor", M.config.workspaces["4"].width == 10)
fake.notes = {}
M.set_min_percent(50)
check("set_min_percent changes nothing", M.config.workspaces["4"].width == 10 and M.config.settings.min_percent == nil)
check("set_min_percent says the floor is fixed", #fake.notes == 1 and fake.notes[1]:find("fixed at 10%", 1, true) ~= nil, fake.notes[1])
M.disable(4)

-- max_windows: the inset gives way one window past the limit.
M.enable(4)
fake.windows[4] = { { floating = false, monitor = screen }, { floating = false, monitor = screen }, { floating = true, monitor = screen } }
M.refresh()
check("two tiled windows restore plain gaps at the default limit", fake.rules["4"].left == 10)
M.set_max_windows(2)
check("set_max_windows two keeps the inset for a pair", fake.rules["4"].left ~= 10)
check("set_max_windows persists", M.parse_config(io.open(M.config_path):read("*a")).settings.max_windows == 2)
fake.windows[4][#fake.windows[4] + 1] = { floating = false, monitor = screen }
M.refresh()
check("a third tiled window is one too many", fake.rules["4"].left == 10)
fake.windows[4] = {}
M.refresh()
check("an empty workspace is not inset", fake.rules["4"].left == 10)
M.set_max_windows(1)
fake.windows[4] = { { floating = false, monitor = screen } }
M.disable(4)

-- set_size: an absolute size, which is what a slider hands over.
M.enable(4)
M.set_size(55, 75, 4)
check("set_size sets both outright", M.config.workspaces["4"].width == 55 and M.config.workspaces["4"].height == 75)
M.set_size(1, 500, 4)
check("set_size clamps to the floor and ceiling", M.config.workspaces["4"].width == M.limits.min
  and M.config.workspaces["4"].height == 100)
M.reset(4)
M.set_size(60, 60, 4)
check("set_size fixes a workspace that followed the defaults", M.config.workspaces["4"].mode == "size"
  and M.config.workspaces["4"].width == 60)
M.disable(4)

-- Named workspaces. Hyprland gives these a negative pseudo-id and a
-- "name:foo" config_name, so the key is the name and the rule uses that
-- selector. Shaped exactly as the compositor reports one.
fake.workspaces[-1337] = { id = -1337, name = "code", config_name = "name:code",
  tiled_layout = "dwindle", monitor = screen }
fake.windows[-1337] = { { floating = false, monitor = screen } }
M.enable("code")
check("a named workspace can be enabled", M.config.workspaces["code"] ~= nil)
check("its rule uses the name: selector", fake.rules["name:code"] ~= nil, "no rule under name:code")
check("and it is inset, not left plain", fake.rules["name:code"].left ~= 10, fake.rules["name:code"].left)
check("the negative id is never used as a key", M.config.workspaces["-1337"] == nil)
M.adjust(-10, 0, "code")
check("a named workspace nudges like any other", M.config.workspaces["code"].mode == "size")
local named_text = M.encode_config(M.config)
check("encode writes the name as the key", named_text:find('"code":', 1, true) ~= nil)
check("encode/parse round-trips a named workspace", M.parse_config(named_text).workspaces["code"] ~= nil)
-- Ordering, on a config built for the purpose so it does not depend on what
-- earlier tests left behind.
local mixed = M.parse_config('{ "workspaces": { "mail": true, "2": true, "code": true, "10": true, "1": true } }')
local mixed_text = M.encode_config(mixed)
local order = {}
for key in mixed_text:gmatch('"([^"]+)":%s*true') do
  order[#order + 1] = key
end
check("encode sorts numbers numerically, then names alphabetically",
  table.concat(order, ",") == "1,2,10,code,mail", table.concat(order, ","))
M.disable("code")
check("disabling a named workspace resets its gaps", fake.rules["name:code"].left == 10)
fake.workspaces[-1337] = nil
fake.windows[-1337] = nil

-- A workspace key is whatever Hyprland reports as the workspace's name. Unlike
-- a preset name or a monitor description, it is not a label Ichi gets to
-- sanitise: rewriting it would lose the workspace it points at. One quote in a
-- name used to make the whole document invalid JSON, and the shell side
-- answers that by keeping the last good file -- which looks like the widget
-- freezing rather than like a bad key.
check("json_string escapes a quote", M.json_string('say "hi"') == '"say \\"hi\\""', M.json_string('say "hi"'))
check("json_string escapes a backslash", M.json_string("back\\slash") == '"back\\\\slash"', M.json_string("back\\slash"))
check("json_string escapes a control character", M.json_string("new\nline") == '"new\\u000aline"', M.json_string("new\nline"))
check("json_string leaves utf-8 alone", M.json_string("\195\188mlaut") == '"\195\188mlaut"', M.json_string("\195\188mlaut"))

local hostile = M.parse_config("")
hostile.workspaces['say "hi"'] = { mode = "default" }
hostile.presets[#hostile.presets + 1] = { name = 'quoted"preset', entry = { mode = "default" } }
hostile.monitors[#hostile.monitors + 1] = { key = 'desc:Acme "27', width = 50, height = 50 }
local hostile_text = M.encode_config(hostile)
check("encode escapes a workspace key", hostile_text:find('"say \\"hi\\"": true', 1, true) ~= nil, hostile_text)
check("encode escapes a preset name", hostile_text:find('"quoted\\"preset": true', 1, true) ~= nil, hostile_text)
check("encode escapes a monitor key", hostile_text:find('"desc:Acme \\"27": {', 1, true) ~= nil, hostile_text)

local plain_cfg = M.parse_config("")
plain_cfg.workspaces["3"] = { mode = "default" }
check("encode leaves an ordinary key alone", M.encode_config(plain_cfg):find("\\", 1, true) == nil, M.encode_config(plain_cfg))

-- Escaping keeps the document valid, but this file's own reader matches keys
-- with a plain "([^"]+)" and will not find an escaped one, so the setting does
-- not come back after a reload. That has to be said rather than just happening.
M.set_notify("changes")
local before_notes = #fake.notes
M.enable('say "hi"')
local said = false
for i = before_notes + 1, #fake.notes do
  if fake.notes[i]:find("will not survive a reload", 1, true) then said = true end
end
check("a workspace name that cannot round-trip says so", said, table.concat(fake.notes, " | "))
M.config.workspaces['say "hi"'] = nil

-- Quiet mode: what the panel uses, because it shows its own result in the
-- same corner the notifications appear in.
M.set_notify("always")
M.enable(4)
fake.notes = {}
M.silently(function() M.adjust(-5, 0, 4) end)
check("silently suppresses the notification", #fake.notes == 0)
check("silently still does the work", M.config.workspaces["4"].mode == "size")
M.adjust(-5, 0, 4)
check("and the next call speaks again", #fake.notes == 1)
check("quiet does not stay on", M.quiet == false)
local ok = pcall(function() M.silently(function() error("boom") end) end)
check("silently restores quiet even when the call errors", ok == false and M.quiet == false)
fake.notes = {}
M.adjust(-5, 0, 4)
check("still speaking after an error", #fake.notes == 1)
M.disable(4)
M.set_notify("changes")

-- Global pause: every workspace back to normal gaps, entries untouched.
M.enable(4)
fake.windows[4] = { { floating = false, monitor = screen } }
M.refresh()
local inset_gap = fake.rules["4"].left
check("inset applied before pausing", inset_gap ~= 10, inset_gap)
M.set_paused(true)
check("pausing restores plain gaps", fake.rules["4"].left == 10)
check("pausing leaves the entry alone", M.config.workspaces["4"] ~= nil and M.entry_for(4) ~= nil)
check("pausing persists", M.parse_config(io.open(M.config_path):read("*a")).settings.paused == true)
M.toggle_pause()
check("toggle_pause resumes and the inset returns", M.config.settings.paused == false
  and fake.rules["4"].left == inset_gap)
M.toggle_pause()
check("toggle_pause pauses again", M.config.settings.paused == true and fake.rules["4"].left == 10)
M.set_paused(false)
M.disable(4)

-- Groups: a tabbed group shares one tile, so it counts as one window.
-- Shaped like Hyprland's own report: every member carries the same group
-- table, and that table's `current` names the visible tab.
local next_group_id = 0
local function grouped(n, mon)
  next_group_id = next_group_id + 1
  local group = { size = n, members = {} }
  for i = 1, n do
    -- Addresses are unique across groups, as Hyprland's are.
    local w = { floating = false, monitor = mon, address = string.format("0x%d%03d", next_group_id, i) }
    w.group = group
    group.members[i] = w
  end
  group.current = group.members[n]
  return group.members
end

M.enable(4)
local pair = grouped(2, screen)
fake.windows[4] = { pair[1], pair[2] }
M.refresh()
check("a group of two counts as one window and keeps the inset", fake.rules["4"].left ~= 10, fake.rules["4"].left)
fake.windows[4] = { pair[1], pair[2], { floating = false, monitor = screen, address = "0xfff" } }
M.refresh()
check("a group plus a loose window is two, so the inset gives way", fake.rules["4"].left == 10)
M.set_max_windows(2)
M.refresh()
check("max_windows 2 admits a group beside a loose window", fake.rules["4"].left ~= 10)
M.set_max_windows(1)
local trio = grouped(3, screen)
fake.windows[4] = { trio[1], trio[2], trio[3] }
M.refresh()
check("a group of three is still one window", fake.rules["4"].left ~= 10)
-- Two separate groups are two windows, so one over the limit.
local other = grouped(2, screen)
fake.windows[4] = { pair[1], pair[2], other[1], other[2] }
M.refresh()
check("two groups are two windows", fake.rules["4"].left == 10)
-- A group with no current window should still count once, not once per member.
local headless = grouped(2, screen)
headless[1].group.current = nil
fake.windows[4] = { headless[1], headless[2] }
M.refresh()
check("a group with no current window still counts once", fake.rules["4"].left ~= 10, fake.rules["4"].left)
-- A floating member is not counted, as before.
fake.windows[4] = { pair[1], pair[2], { floating = true, monitor = screen, address = "0xflo" } }
M.refresh()
check("a floating window beside a group is still ignored", fake.rules["4"].left ~= 10)
fake.windows[4] = { { floating = false, monitor = screen } }
M.disable(4)

-- all_workspaces: every existing workspace is managed, false opts one out.
fake.workspaces[6] = { id = 6, name = "6", config_name = "6", tiled_layout = "dwindle", monitor = screen }
fake.windows[6] = { { floating = false, monitor = screen } }
fake.rules = {}
M.set_all_workspaces(true)
check("all on applies to a workspace with no entry", fake.rules["6"] and fake.rules["6"].left ~= 10, fake.rules["6"] and fake.rules["6"].left)
check("all on writes nothing for it", M.config.workspaces["6"] == nil)
M.toggle(6)
check("toggle under all on writes false", M.config.workspaces["6"] == false and fake.rules["6"].left == 10)
M.toggle(6)
check("toggle again removes the false", M.config.workspaces["6"] == nil and fake.rules["6"].left ~= 10)
M.adjust(-10, 0, 6)
check("nudging under all on fixes the size", M.config.workspaces["6"].mode == "size")
M.reset(6)
check("reset under all on removes the entry", M.config.workspaces["6"] == nil)
M.set_all_workspaces(false)
check("all off resets a workspace it had managed", fake.rules["6"].left == 10 and M.entry_for(6) == nil)
fake.workspaces[6] = nil
fake.windows[6] = nil

-- Steps, nudges and notification levels, on a workspace of a known size.
M.set_step(12, 3)
check("set_step stores both", M.config.settings.step == 12 and M.config.settings.fine_step == 3)
M.set_step(0, 0)
check("set_step keeps zeros", M.config.settings.step == 12 and M.config.settings.fine_step == 3)
M.config.workspaces["2"] = { mode = "size", width = 70, height = 80 }
M.nudge(-1, 0, false, 2)
check("nudge scales by the step", M.config.workspaces["2"].width == 58)
M.nudge(0, 1, true, 2)
check("nudge fine scales by the fine step", M.config.workspaces["2"].height == 83)
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
check("notify falls back to libnotify off Omarchy",
  fake.notes[1]:find("command -v omarchy-notification-send", 1, true) ~= nil
    and fake.notes[1]:find("notify-send -u low -a Ichi 'Ichi:", 1, true) ~= nil, fake.notes[1])
check("notify quotes a message containing a quote",
  M.notify_command("it's here"):find("'it'\\''s here'", 1, true) ~= nil, M.notify_command("it's here"))
M.set_notify("loud")
-- The level just above set it to "always"; an unknown one must not change it.
check("set_notify ignores an unknown level", M.config.settings.notify == "always")
M.set_notify("never")
check("set_notify persists", M.parse_config(io.open(M.config_path):read("*a")).settings.notify == "never")
M.set_notify("always")

-- Adopt on a named workspace: its key is not a number, and each "why not"
-- message has to say so without failing.
fake.workspaces[-1338] = { id = -1338, name = "mail", config_name = "name:mail", tiled_layout = "dwindle",
  monitor = { name = "DP-1", width = 2560, height = 1440, reserved = {} } }
fake.notes = {}
check("adopt on a named workspace that is off says why",
  pcall(M.adopt_defaults, "mail") and #fake.notes == 1 and fake.notes[1]:find("workspace mail is off", 1, true) ~= nil,
  fake.notes[1])
M.config.workspaces["mail"] = { mode = "default" }
fake.notes = {}
check("adopt on a named workspace that follows the defaults says why",
  pcall(M.adopt_defaults, "mail") and #fake.notes == 1 and fake.notes[1]:find("workspace mail already", 1, true) ~= nil,
  fake.notes[1])
M.config.workspaces["mail"] = { mode = "aspect", ratio_w = 4, ratio_h = 3 }
fake.notes = {}
check("adopt on a named aspect workspace says why",
  pcall(M.adopt_defaults, "mail") and #fake.notes == 1 and fake.notes[1]:find("workspace mail is an aspect", 1, true) ~= nil,
  fake.notes[1])
M.config.workspaces["mail"] = nil
fake.workspaces[-1338] = nil

-- A state file that does not parse is never overwritten.
check("well_formed accepts what encode writes", M.well_formed(M.encode_config(M.config)))
check("well_formed accepts braces inside a string", M.well_formed('{ "presets": { "a}\\"{": true } }'))
check("well_formed rejects an empty file", not M.well_formed("") and not M.well_formed("  \n"))
check("well_formed rejects a file cut short", not M.well_formed('{ "workspaces": { "1": true,'))
check("well_formed rejects a missing brace", not M.well_formed('{ "workspaces": { "2": { "width": 60 } }'))
check("well_formed rejects mismatched brackets", not M.well_formed('{ "ratio": [4, 3} }'))
check("well_formed rejects an unterminated string", not M.well_formed('{ "wor'))
check("well_formed rejects trailing text", not M.well_formed('{ } }'))

local good = '{ "defaults": { "width": 70, "height": 80 }, "workspaces": { "1": true, "2": { "mode": "size", "width": 60, "height": 80 }, "code": { "mode": "aspect", "ratio": [4, 3] } } }'
local cut = '{ "defaults": { "width": 70, "height": 80 }, "workspaces": { "1": true, "2": { "mode": "size", "width": 60, "height": 80 }, "code": { "mode": "si'
local function write(text)
  local f = io.open(M.config_path, "w")
  f:write(text)
  f:close()
end
local function read()
  return io.open(M.config_path):read("*a")
end
write(good)
M.load()
check("a good file loads", M.config.workspaces["code"] ~= nil and M.blocked == nil)
fake.active = { id = 2, name = "2" }
fake.notes = {}
write(cut)
M.load()
check("a file cut short keeps the last good settings", M.blocked == "does not parse" and M.config.workspaces["2"].width == 60
  and M.config.workspaces["code"] ~= nil)
check("a file cut short is reported once", #fake.notes == 1 and fake.notes[1]:find("does not parse", 1, true) ~= nil, fake.notes[1])
M.load()
check("reloading it does not report again", #fake.notes == 1)
M.nudge(1, 0, false, 2)
-- `good` has no settings block, so loading it put the step back to 5.
check("a nudge still applies while the file does not parse", M.config.workspaces["2"].width == 65,
  tostring(M.config.workspaces["2"].width))
check("a nudge does not overwrite the file", read() == cut)
write("")
M.load()
check("an emptied file is not overwritten either", M.blocked ~= nil and M.config.workspaces["code"] ~= nil)
M.toggle(2)
check("a toggle does not overwrite an emptied file", read() == "")
write(good)
M.load()
check("fixing the file reads it again", M.blocked == nil and M.config.workspaces["2"].width == 60)
M.nudge(1, 0, false, 2)
check("fixing the file lets saves through", M.parse_config(read()).workspaces["2"].width == 65)
fake.active = nil

-- set: one setting by its place in the file.
check("set takes a number as a string", M.set("settings.step", "7") == true and M.config.settings.step == 7)
check("set persists", M.parse_config(read()).settings.step == 7)
check("set clamps as reading the file does", M.set("settings.fine_step", 90) and M.config.settings.fine_step == 25)
check("set takes on and off", M.set("settings.all_workspaces", "on") and M.config.settings.all_workspaces == true
  and M.set("settings.all_workspaces", "off") and M.config.settings.all_workspaces == false)
check("set reaches the defaults", M.set("defaults.width", "55") and M.config.defaults.width == 55)
check("set keeps a size above the floor", M.set("defaults.height", 3) and M.config.defaults.height == 10)
fake.notes = {}
check("set refuses a value that does not fit", M.set("settings.notify", "loudly") == false
  and M.config.settings.notify == "changes")
check("set says what the setting takes", fake.notes[1] and fake.notes[1]:find("never, changes or always", 1, true) ~= nil,
  fake.notes[1])
fake.notes = {}
check("set refuses an unknown key", M.set("settings.min_percent", 20) == false and M.config.settings.min_percent == nil)
check("set names the unknown key", fake.notes[1] and fake.notes[1]:find("min_percent", 1, true) ~= nil, fake.notes[1])
check("set refuses what is not a number", M.set("defaults.max_width", "wide") == false
  and M.set("defaults.max_width", "1e999") == false and M.config.defaults.max_width == 0)

-- The reload the shell asks for after every save does not parse again.
local parses = 0
local real_parse = M.parse_config
M.parse_config = function(...)
  parses = parses + 1
  return real_parse(...)
end
M.set("settings.step", 8)
M.load()
check("reloading what Ichi just saved skips the parse", parses == 0, tostring(parses))
write((read():gsub('"step": 8', '"step": 6')))
M.load()
check("a file someone else changed is parsed", parses == 1 and M.config.settings.step == 6, tostring(parses))
M.parse_config = real_parse

-- Saves replace the file whole, through a link, and leave nothing behind.
local dotfile = tmp .. ".dotfiles.json"
write(good)
os.rename(M.config_path, dotfile)
os.execute("ln -s '" .. dotfile .. "' '" .. M.config_path .. "'")
M.load()
M.set("settings.step", 9)
local link = io.popen("readlink '" .. M.config_path .. "'"):read("*l")
check("a save through a link keeps the link", link == dotfile, link)
check("a save through a link writes where it points", M.parse_config(io.open(dotfile):read("*a")).settings.step == 9)
check("a save leaves no temporary file", io.open(dotfile .. ".tmp", "r") == nil and io.open(M.config_path .. ".tmp", "r") == nil)

-- The temp name used to be fixed (path .. ".tmp"), so a symlink planted at
-- that exact name ahead of time would catch the write. The name is random
-- now: nothing is waiting at the one name a symlink could be planted at.
local victim = tmp .. ".victim"
os.execute("ln -sf '" .. victim .. "' '" .. dotfile .. ".tmp'")
M.set("settings.step", 10)
check("a save does not write through a symlink at the old fixed temp name", io.open(victim, "r") == nil)
check("the save still reached the real file", M.parse_config(io.open(dotfile):read("*a")).settings.step == 10)
os.remove(dotfile .. ".tmp")

os.remove(M.config_path)
os.remove(dotfile)

-- The first save makes the file's directory.
local nested_dir = tmp .. ".dir"
M.config_path = nested_dir .. "/sub/ichi.json"
M.load()
M.set("settings.step", 5)
check("the first save makes the directory", io.open(M.config_path, "r") ~= nil)
os.execute("rm -rf '" .. nested_dir .. "'")
M.config_path = tmp .. ".json"

-- A file from before 0.7 is used where it is, until one exists at config_path.
os.remove(M.config_path)
local previous = io.open(M.previous_config_path, "w")
previous:write('{ "workspaces": { "7": true } }')
previous:close()
M.load()
check("with only the old file, it is the one read", M.state_path() == M.previous_config_path
  and M.config.workspaces["7"] ~= nil)
M.set("settings.step", 11)
check("with only the old file, saves go to it", M.parse_config(io.open(M.previous_config_path):read("*a")).settings.step == 11
  and io.open(M.config_path, "r") == nil)
write('{ "workspaces": { "8": true } }')
M.load()
check("a file at config_path wins", M.state_path() == M.config_path and M.config.workspaces["8"] ~= nil
  and M.config.workspaces["7"] == nil)
check("the old file is left alone", M.parse_config(io.open(M.previous_config_path):read("*a")).settings.step == 11)

-- Saving and loading fail safe, and say so whatever settings.notify says.
os.remove(M.previous_config_path)
local function slurp(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end
local function noted(text)
  for _, note in ipairs(fake.notes) do
    if note:find(text, 1, true) then
      return true
    end
  end
  return false
end
local safe_dir = tmp .. ".safe"
os.execute("rm -rf '" .. safe_dir .. "' && mkdir -p '" .. safe_dir .. "'")
M.config_path = safe_dir .. "/ichi.json"
write(good)
M.load()

-- Permission tests mean nothing as root, which reads and writes regardless.
if io.popen("id -u"):read("*l") ~= "0" then
  os.execute("chmod 555 '" .. safe_dir .. "'")
  M.config.settings.notify = "never"
  fake.notes = {}
  M.set("settings.step", 13)
  check("a save that cannot write leaves the file as it was", slurp(M.config_path) == good)
  check("a failed save is reported even with notify never", noted("could not save"), fake.notes[1])
  M.set("settings.step", 14)
  check("a failed save is reported once while it keeps failing", #fake.notes == 1, tostring(#fake.notes))
  os.execute("chmod 755 '" .. safe_dir .. "'")
  M.set("settings.step", 15)
  check("the next save that can write does", M.parse_config(slurp(M.config_path)).settings.step == 15)

  write(good)
  M.load()
  os.execute("chmod 000 '" .. M.config_path .. "'")
  M.config.settings.notify = "never"
  fake.notes = {}
  M.load()
  check("a file that cannot be read blocks saves", M.blocked == "cannot be read" and M.config.workspaces["code"] ~= nil)
  check("a file that cannot be read is reported even with notify never", noted("cannot be read"), fake.notes[1])
  M.set("settings.step", 16)
  os.execute("chmod 644 '" .. M.config_path .. "'")
  check("a file that cannot be read is never replaced", slurp(M.config_path) == good)
  M.load()
  check("once it can be read again, it is", M.blocked == nil and M.config.settings.step == 5)
else
  -- Said in run.sh's own words, so CI can fail on it rather than pass without them.
  print("skip: the permission tests, which mean nothing when run as root")
end

-- An emptied file says nothing until a save is refused.
write(good)
M.load()
fake.notes = {}
write("")
M.load()
check("an emptied file is not reported on load", #fake.notes == 0 and M.blocked == "does not parse")
M.set("settings.step", 17)
check("a save refused while it is empty is reported", noted("not saved"), fake.notes[1])
write(good)
M.load()

-- A link whose target is not there yet stays a link.
local linked = safe_dir .. "/linked.json"
local repo_file = safe_dir .. "/repo/omarchy/ichi.json"
os.execute("ln -s '" .. repo_file .. "' '" .. linked .. "'")
M.config_path = linked
M.load()
M.set("settings.step", 18)
local function link_of(path)
  local pipe = io.popen("readlink '" .. path .. "'")
  local out = pipe:read("*l")
  pipe:close()
  return out
end
check("a save through a dangling link keeps the link", link_of(linked) == repo_file, link_of(linked))
check("a save through a dangling link writes where it points", M.parse_config(slurp(repo_file) or "").settings.step == 18)

-- Without io.popen links cannot be resolved, so the save writes through the
-- link in place rather than renaming over it.
local real_popen = io.popen
write((slurp(linked):gsub('"step": 18', '"step": 20')))
M.load()
io.popen = nil
M.set("settings.step", 19)
io.popen = real_popen
check("without io.popen a save keeps the link", link_of(linked) == repo_file, link_of(linked))
check("without io.popen a save writes through the link", M.parse_config(slurp(repo_file)).settings.step == 19)

-- Links are resolved by a save that needs them, not by every load.
local popens = 0
io.popen = function(...)
  popens = popens + 1
  return real_popen(...)
end
write((slurp(linked):gsub('"step": 19', '"step": 21')))
M.load()
check("a load does not resolve links", popens == 0, tostring(popens))
M.set("settings.step", 22)
M.set("settings.step", 23)
check("saves resolve links once", popens == 1, tostring(popens))
io.popen = real_popen

os.execute("rm -rf '" .. safe_dir .. "'")
M.config_path = tmp .. ".json"
M.load()

-- The hl.on example in docs/reference.md runs as written.
local reference = io.open(root .. "/docs/reference.md"):read("*a")
local snippet = reference:match("```lua\n(%-%- ~/%.config/hypr/hyprland%.lua, after the line that loads Ichi.-)```")
check("the reference's hl.on example is there to run", snippet ~= nil)
if snippet then
  local handlers = {}
  hl.on = function(event, fn)
    handlers[event] = fn
  end
  fake.workspaces[-1400] = { id = -1400, name = "notes-a", config_name = "name:notes-a", tiled_layout = "dwindle", monitor = screen }
  fake.workspaces[-1401] = { id = -1401, name = "mail", config_name = "name:mail", tiled_layout = "dwindle", monitor = screen }
  assert((loadstring or load)(snippet))()
  handlers["workspace.created"]()
  check("the example turns a notes workspace on", M.entry_for("notes-a") ~= nil and M.entry_for("mail") == nil)
  M.disable("notes-a")
  handlers["workspace.created"]()
  check("the example leaves a notes workspace turned off alone", M.entry_for("notes-a") == nil)
  hl.on = nil
  fake.workspaces[-1400], fake.workspaces[-1401] = nil, nil
end

os.remove(M.config_path)
os.remove(M.previous_config_path)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")

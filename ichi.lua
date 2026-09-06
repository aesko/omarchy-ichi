-- Ichi: the Hyprland side of the aesko.ichi plugin.
--
-- On an opted-in workspace holding exactly one tiled window, widen that
-- workspace's outer gaps so the window occupies a percentage of the usable
-- area (size mode) or the largest box of a given aspect ratio (aspect mode).
-- A second tiled window restores normal gaps. Floating windows are neither
-- counted nor touched. Nothing here floats or moves a window: a tiled window
-- reflows on its own after a monitor teardown, which is the point.
--
-- Loaded by a guarded dofile line in ~/.config/hypr/hyprland.lua that the
-- shell plugin installs. Everything hangs off the global `ichi` table so
-- keybinds and `hyprctl eval` can drive it. Lua is the only writer of the
-- state file; the shell plugin reads it.

ichi = ichi or {}
local M = ichi

local HOME = os.getenv("HOME") or ""
local CONFIG_DIR = os.getenv("XDG_CONFIG_HOME") or (HOME .. "/.config")
local STATE_DIR = os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")

M.config_path = CONFIG_DIR .. "/omarchy/ichi.json"
-- Earlier state files, imported once if the JSON does not exist yet: the
-- plugin's pre-rename JSON, then the original "<id> <width> <height>" lines.
M.legacy_json_path = CONFIG_DIR .. "/omarchy/workspace-inset.json"
M.legacy_lines_path = STATE_DIR .. "/omarchy/workspace-inset"

M.limits = { min = 30, max = 100 }
-- Hyprland's own layouts. Anything else is a plugin-registered layout that
-- owns how its workspace tiles, and Ichi yields to it.
M.builtin_layouts = { dwindle = true, master = true, scrolling = true, monocle = true }

M.config = { defaults = { width = 70, height = 80, step = 5 }, workspaces = {} }

-- Workspaces enabled at some point this session, so disabling one still gets
-- its gaps reset instead of keeping the last inset that was applied.
local touched = {}
local warned = { builtin = false, layouts = {} }

-- ------------------------------------------------------------------ pure --

local function clamp(value, lo, hi)
  return math.max(lo, math.min(hi, value))
end

function M.normalize_entry(entry, defaults)
  defaults = defaults or M.config.defaults
  if type(entry) ~= "table" then
    return nil
  end

  if entry.mode == "aspect" then
    local rw, rh = tonumber(entry.ratio_w), tonumber(entry.ratio_h)
    if not rw or not rh or rw <= 0 or rh <= 0 then
      return nil
    end
    return { mode = "aspect", ratio_w = rw, ratio_h = rh }
  end

  return {
    mode = "size",
    width = clamp(math.floor(tonumber(entry.width) or defaults.width), M.limits.min, M.limits.max),
    height = clamp(math.floor(tonumber(entry.height) or defaults.height), M.limits.min, M.limits.max),
  }
end

-- Outer gaps that leave a centred box of the requested shape in a usable area.
-- Never smaller than the base gaps, so an inset of 100% is exactly normal.
function M.gaps_for(usable_w, usable_h, entry, base)
  local box_w, box_h
  if entry.mode == "aspect" then
    if usable_w * entry.ratio_h > usable_h * entry.ratio_w then
      box_h = usable_h
      box_w = usable_h * entry.ratio_w / entry.ratio_h
    else
      box_w = usable_w
      box_h = usable_w * entry.ratio_h / entry.ratio_w
    end
  else
    box_w = usable_w * entry.width / 100
    box_h = usable_h * entry.height / 100
  end

  local gap_h = math.floor((usable_w - box_w) / 2)
  local gap_v = math.floor((usable_h - box_h) / 2)
  return {
    left = math.max(gap_h, base.left or 0),
    right = math.max(gap_h, base.right or 0),
    top = math.max(gap_v, base.top or 0),
    bottom = math.max(gap_v, base.bottom or 0),
  }
end

-- The config is a fixed, flat shape, so a real JSON parser is not needed; a
-- hand-edit that gets something wrong loses that entry, not the file.
local function find_object(text, key)
  local start = text:find('"' .. key .. '"%s*:%s*{')
  if not start then
    return nil
  end
  local open = text:find("{", start, true)
  local depth = 0
  for i = open, #text do
    local c = text:sub(i, i)
    if c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then
        return text:sub(open + 1, i - 1)
      end
    end
  end
  return nil
end

local function number_field(body, key)
  return tonumber(body:match('"' .. key .. '"%s*:%s*(-?%d+%.?%d*)'))
end

function M.parse_config(text)
  local cfg = { defaults = { width = 70, height = 80, step = 5 }, workspaces = {} }
  if type(text) ~= "string" then
    return cfg
  end

  local defaults = find_object(text, "defaults")
  if defaults then
    cfg.defaults.width = clamp(math.floor(number_field(defaults, "width") or 70), M.limits.min, M.limits.max)
    cfg.defaults.height = clamp(math.floor(number_field(defaults, "height") or 80), M.limits.min, M.limits.max)
    cfg.defaults.step = clamp(math.floor(number_field(defaults, "step") or 5), 1, 25)
  end

  local workspaces = find_object(text, "workspaces")
  if workspaces then
    for id, body in workspaces:gmatch('"(%d+)"%s*:%s*{(.-)}') do
      local rw, rh = body:match('"ratio"%s*:%s*%[%s*(%d+%.?%d*)%s*,%s*(%d+%.?%d*)%s*%]')
      cfg.workspaces[tonumber(id)] = M.normalize_entry({
        mode = body:match('"mode"%s*:%s*"(%a+)"'),
        width = number_field(body, "width"),
        height = number_field(body, "height"),
        ratio_w = rw,
        ratio_h = rh,
      }, cfg.defaults)
    end
  end

  return cfg
end

function M.encode_config(cfg)
  local ids = {}
  for id in pairs(cfg.workspaces) do
    ids[#ids + 1] = id
  end
  table.sort(ids)

  local lines = {}
  for _, id in ipairs(ids) do
    local e = cfg.workspaces[id]
    if e.mode == "aspect" then
      lines[#lines + 1] = string.format('    "%d": { "mode": "aspect", "ratio": [%g, %g] }', id, e.ratio_w, e.ratio_h)
    else
      lines[#lines + 1] = string.format('    "%d": { "mode": "size", "width": %d, "height": %d }', id, e.width, e.height)
    end
  end

  return string.format(
    '{\n  "defaults": { "width": %d, "height": %d, "step": %d },\n  "workspaces": {\n%s\n  }\n}\n',
    cfg.defaults.width,
    cfg.defaults.height,
    cfg.defaults.step,
    table.concat(lines, ",\n")
  )
end

-- ----------------------------------------------------------------- files --

local function read_file(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

local function write_file(path, text)
  os.execute("mkdir -p '" .. path:match("^(.*)/") .. "'")
  local file = io.open(path, "w")
  if not file then
    return false
  end
  file:write(text)
  file:close()
  return true
end

function M.save()
  write_file(M.config_path, M.encode_config(M.config))
end

function M.load()
  local text = read_file(M.config_path)
  if text then
    M.config = M.parse_config(text)
    return
  end

  local legacy_json = read_file(M.legacy_json_path)
  if legacy_json then
    M.config = M.parse_config(legacy_json)
    M.save()
    return
  end

  M.config = M.parse_config("")
  local legacy_lines = read_file(M.legacy_lines_path)
  if legacy_lines then
    for id, width, height in legacy_lines:gmatch("(%d+)%s+(%d+)%s+(%d+)") do
      M.config.workspaces[tonumber(id)] = M.normalize_entry({ width = tonumber(width), height = tonumber(height) })
    end
    M.save()
  end
end

-- -------------------------------------------------------------- hyprland --

local function shell_quote(value)
  return "'" .. (tostring(value):gsub("'", "'\\''")) .. "'"
end

local function notify(message)
  if not (hl and hl.exec_cmd) then
    return
  end
  hl.exec_cmd("omarchy-notification-send -u low " .. shell_quote(message))
end

local function base_gaps()
  local gaps = hl.get_config("general.gaps_out")
  if type(gaps) == "table" then
    return gaps
  end
  return { top = 10, right = 10, bottom = 10, left = 10 }
end

local function builtin_aspect_active()
  local value = hl.get_config("layout.single_window_aspect_ratio")
  if type(value) ~= "table" then
    return false
  end
  local x = tonumber(value.x or value[1]) or 0
  local y = tonumber(value.y or value[2]) or 0
  return x > 0 and y > 0
end

local function describe(id, entry)
  if entry.mode == "aspect" then
    return string.format("Ichi: workspace %d at %g:%g", id, entry.ratio_w, entry.ratio_h)
  end
  return string.format("Ichi: workspace %d at %d%% x %d%%", id, entry.width, entry.height)
end

function M.apply(id)
  local ws = hl.get_workspace(id)
  if ws == nil or ws.special then
    return
  end

  local base = base_gaps()
  local entry = M.config.workspaces[id]
  local function plain()
    hl.workspace_rule({ workspace = tostring(id), gaps_out = base })
  end

  if entry == nil then
    plain()
    return
  end

  local layout = ws.tiled_layout or ""
  if not M.builtin_layouts[layout] then
    if not warned.layouts[id] then
      warned.layouts[id] = true
      notify(string.format("Ichi: yielding to the '%s' layout on workspace %d", layout, id))
    end
    plain()
    return
  end

  local tiled, count = nil, 0
  for _, w in ipairs(hl.get_workspace_windows(id) or {}) do
    if not w.floating then
      count = count + 1
      tiled = w
    end
  end
  if count ~= 1 or tiled.monitor == nil then
    plain()
    return
  end

  if builtin_aspect_active() and not warned.builtin then
    warned.builtin = true
    notify("Ichi: Hyprland's 1-Window Ratio is also on and the two compound. Turn it off and use Ichi's aspect mode instead.")
  end

  -- Percentages are of the usable area, so the bar's reserved strip does not
  -- push the window off-centre and the proportion holds on any monitor.
  local mon = tiled.monitor
  local reserved = mon.reserved or {}
  local usable_w = mon.width - (reserved.left or 0) - (reserved.right or 0)
  local usable_h = mon.height - (reserved.top or 0) - (reserved.bottom or 0)

  -- Named keys are mandatory here: a positional array is silently misparsed.
  hl.workspace_rule({ workspace = tostring(id), gaps_out = M.gaps_for(usable_w, usable_h, entry, base) })
end

function M.refresh()
  for id in pairs(M.config.workspaces) do
    touched[id] = true
  end
  for id in pairs(touched) do
    M.apply(id)
  end
end

local function current_id()
  local ws = hl.get_active_workspace()
  return ws and ws.id or nil
end

local function commit(id, entry, message)
  M.config.workspaces[id] = entry
  M.save()
  M.refresh()
  notify(message)
end

function M.enable(id, entry)
  id = id or current_id()
  if id == nil then
    return
  end
  entry = M.normalize_entry(entry or M.config.defaults) or M.normalize_entry(M.config.defaults)
  commit(id, entry, describe(id, entry))
end

function M.disable(id)
  id = id or current_id()
  if id == nil then
    return
  end
  commit(id, nil, string.format("Ichi: workspace %d off", id))
end

function M.toggle(id)
  id = id or current_id()
  if id == nil then
    return
  end
  if M.config.workspaces[id] then
    M.disable(id)
  else
    M.enable(id)
  end
end

-- Nudging an aspect-mode or disabled workspace turns it into size mode from
-- the defaults, so the arrow keys always do something visible.
function M.adjust(delta_width, delta_height, id)
  id = id or current_id()
  if id == nil then
    return
  end
  local entry = M.config.workspaces[id]
  if entry == nil or entry.mode ~= "size" then
    entry = M.normalize_entry(M.config.defaults)
  end
  entry.width = clamp(entry.width + (delta_width or 0), M.limits.min, M.limits.max)
  entry.height = clamp(entry.height + (delta_height or 0), M.limits.min, M.limits.max)
  commit(id, entry, describe(id, entry))
end

function M.set_aspect(ratio_w, ratio_h, id)
  id = id or current_id()
  if id == nil then
    return
  end
  local entry = M.normalize_entry({ mode = "aspect", ratio_w = ratio_w, ratio_h = ratio_h })
  if entry == nil then
    return
  end
  commit(id, entry, describe(id, entry))
end

function M.reset(id)
  id = id or current_id()
  if id == nil or M.config.workspaces[id] == nil then
    return
  end
  local entry = M.normalize_entry(M.config.defaults)
  commit(id, entry, describe(id, entry) .. " (reset)")
end

local function positive(value, fallback)
  value = tonumber(value)
  if value and value > 0 then
    return value
  end
  return fallback
end

-- What a workspace gets when toggled on or reset. Workspaces already on keep
-- their own sizes. Zero or nil leaves a value as it is.
function M.set_defaults(width, height, step)
  local d = M.config.defaults
  d.width = clamp(math.floor(positive(width, d.width)), M.limits.min, M.limits.max)
  d.height = clamp(math.floor(positive(height, d.height)), M.limits.min, M.limits.max)
  d.step = clamp(math.floor(positive(step, d.step)), 1, 25)
  M.save()
  notify(string.format("Ichi: defaults %d%% x %d%%, step %d", d.width, d.height, d.step))
end

-- Tune a workspace with the arrows, then make that the default for the rest.
function M.adopt_defaults(id)
  id = id or current_id()
  local entry = id and M.config.workspaces[id]
  if not entry or entry.mode ~= "size" then
    return
  end
  M.set_defaults(entry.width, entry.height)
end

-- Tests load this file with a fake `hl`; only wire events into a real one.
if hl and hl.on then
  M.load()

  hl.on("hyprland.start", function()
    M.refresh()
  end)
  hl.on("config.reloaded", function()
    M.load()
    M.refresh()
  end)
  hl.on("window.open", function()
    M.refresh()
  end)
  hl.on("window.destroy", function()
    M.refresh()
  end)
  hl.on("window.move_to_workspace", function()
    M.refresh()
  end)
  -- There is no float/tile event; rules are re-evaluated when `floating`
  -- changes, so this catches a window being tiled or floated by hand.
  hl.on("window.update_rules", function()
    M.refresh()
  end)
  hl.on("monitor.layout_changed", function()
    M.refresh()
  end)
end

return M

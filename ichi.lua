-- Ichi: the Hyprland side of the io.github.aesko.ichi plugin.
--
-- On an opted-in workspace holding one tiled window (or up to
-- settings.max_windows of them), widen that workspace's outer gaps so the
-- window occupies a percentage of the usable area (size mode) or the largest
-- box of a given aspect ratio (aspect mode). One tiled window more than that
-- restores normal gaps. A tabbed group counts as one, since it occupies one
-- tile however many windows it holds. Floating windows are neither
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

-- The range settings.min_percent may take; sizes are clamped between that
-- setting and 100.
M.limits = { min = 5, max = 100 }
-- Hyprland's own layouts. Anything else is a plugin-registered layout that
-- owns how its workspace tiles, and Ichi yields to it.
M.builtin_layouts = { dwindle = true, master = true, scrolling = true, monocle = true }

-- Notification levels: "never" is silent, "changes" reports toggles, resets
-- and setting changes, "always" also reports every arrow-key nudge.
M.notify_levels = { never = 0, changes = 1, always = 2 }

local function default_config()
  return {
    settings = { step = 5, fine_step = 1, notify = "always", all_workspaces = false, max_windows = 1, min_percent = 20, paused = false },
    defaults = { width = 70, height = 80, step = 5, max_width = 0, max_height = 0, align_x = 50, align_y = 50 },
    -- Ordered, first match wins: { key = "desc:..." or "DP-1", width?, height?, max_width?, max_height?, align_x?, align_y? }
    monitors = {},
    -- Ordered, for cycling: { name = "reading", entry = <normalized entry> }
    presets = {},
    workspaces = {},
  }
end

M.config = default_config()

-- Workspaces enabled at some point this session, so disabling one still gets
-- its gaps reset instead of keeping the last inset that was applied.
local touched = {}
local warned = { builtin = false, layouts = {} }

-- ------------------------------------------------------------------ pure --

local function clamp(value, lo, hi)
  return math.max(lo, math.min(hi, value))
end

-- Entry shapes: { mode = "default" } follows the defaults (JSON `true`),
-- "size" is a share of the usable area, "aspect" a ratio.
-- The smallest share a size may be, per the config being built or the live one.
local function floor_percent(cfg)
  return (cfg or M.config).settings.min_percent
end

function M.normalize_entry(entry, defaults, min)
  defaults = defaults or M.config.defaults
  min = min or floor_percent()
  if entry == true then
    return { mode = "default" }
  end
  if type(entry) ~= "table" then
    return nil
  end

  if entry.mode == "default" then
    return { mode = "default" }
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
    width = clamp(math.floor(tonumber(entry.width) or defaults.width), min, M.limits.max),
    height = clamp(math.floor(tonumber(entry.height) or defaults.height), min, M.limits.max),
  }
end

-- A monitor block matches by connector name exactly, or, with a "desc:"
-- prefix, by any part of the description Hyprland reports. Names change when
-- a dock is replugged; descriptions do not.
function M.monitor_block(mon)
  if mon == nil then
    return nil
  end
  for _, block in ipairs(M.config.monitors) do
    local desc = block.key:match("^desc:(.*)$")
    if desc then
      if desc ~= "" and (mon.description or ""):find(desc, 1, true) then
        return block
      end
    elseif block.key == mon.name then
      return block
    end
  end
  return nil
end

-- The defaults as seen from one monitor: its block overrides field by field.
function M.defaults_for(mon)
  local out = {}
  for k, v in pairs(M.config.defaults) do
    out[k] = v
  end
  local block = M.monitor_block(mon)
  if block then
    for _, k in ipairs({ "width", "height", "max_width", "max_height", "align_x", "align_y" }) do
      if block[k] ~= nil then
        out[k] = block[k]
      end
    end
  end
  return out
end

-- The concrete size or aspect an entry stands for on a monitor, plus the pixel
-- caps that apply to it: a default entry becomes whatever the defaults, and
-- the monitor's overrides, say right now.
function M.resolve(entry, mon)
  if entry == nil then
    return nil
  end
  local defaults = M.defaults_for(mon)
  local out
  if entry.mode == "default" then
    out = M.normalize_entry({ mode = "size" }, defaults)
  else
    out = {}
    for k, v in pairs(entry) do
      out[k] = v
    end
  end
  out.max_width = defaults.max_width or 0
  out.max_height = defaults.max_height or 0
  out.align_x = defaults.align_x or 50
  out.align_y = defaults.align_y or 50
  return out
end

-- Outer gaps that leave a box of the requested shape in a usable area, centred
-- unless align_x or align_y on the entry say otherwise (0 is the left or top
-- edge, 100 the right or bottom). Never smaller than the base gaps, so an
-- inset of 100% is exactly normal. A positive max_width or max_height caps
-- the box in pixels; an aspect box shrinks on both sides to keep its ratio.
function M.gaps_for(usable_w, usable_h, entry, base)
  local box_w, box_h
  local max_w, max_h = entry.max_width or 0, entry.max_height or 0
  if entry.mode == "aspect" then
    local fit_w, fit_h = usable_w, usable_h
    if max_w > 0 then
      fit_w = math.min(fit_w, max_w)
    end
    if max_h > 0 then
      fit_h = math.min(fit_h, max_h)
    end
    if fit_w * entry.ratio_h > fit_h * entry.ratio_w then
      box_h = fit_h
      box_w = fit_h * entry.ratio_w / entry.ratio_h
    else
      box_w = fit_w
      box_h = fit_w * entry.ratio_h / entry.ratio_w
    end
  else
    box_w = usable_w * entry.width / 100
    box_h = usable_h * entry.height / 100
    if max_w > 0 then
      box_w = math.min(box_w, max_w)
    end
    if max_h > 0 then
      box_h = math.min(box_h, max_h)
    end
  end

  local slack_w, slack_h = usable_w - box_w, usable_h - box_h
  local left = math.floor(slack_w * (entry.align_x or 50) / 100)
  local top = math.floor(slack_h * (entry.align_y or 50) / 100)
  return {
    left = math.max(left, base.left or 0),
    right = math.max(math.floor(slack_w) - left, base.right or 0),
    top = math.max(top, base.top or 0),
    bottom = math.max(math.floor(slack_h) - top, base.bottom or 0),
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

local function string_field(body, key)
  return body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
end

-- One "{ ... }" entry body, or nil when it does not describe anything usable.
local function parse_entry(body, defaults, min)
  local rw, rh = body:match('"ratio"%s*:%s*%[%s*(%d+%.?%d*)%s*,%s*(%d+%.?%d*)%s*%]')
  return M.normalize_entry({
    mode = body:match('"mode"%s*:%s*"(%a+)"'),
    width = number_field(body, "width"),
    height = number_field(body, "height"),
    ratio_w = rw,
    ratio_h = rh,
  }, defaults, min)
end

function M.parse_config(text)
  local cfg = default_config()
  if type(text) ~= "string" then
    return cfg
  end

  local defaults = find_object(text, "defaults") or ""
  local settings = find_object(text, "settings") or ""
  -- Read first: every size below is clamped against it.
  cfg.settings.min_percent = clamp(math.floor(number_field(settings, "min_percent") or 20), M.limits.min, M.limits.max)
  local min = cfg.settings.min_percent
  cfg.defaults.width = clamp(math.floor(number_field(defaults, "width") or 70), min, M.limits.max)
  cfg.defaults.height = clamp(math.floor(number_field(defaults, "height") or 80), min, M.limits.max)
  cfg.defaults.max_width = math.max(0, math.floor(number_field(defaults, "max_width") or 0))
  cfg.defaults.max_height = math.max(0, math.floor(number_field(defaults, "max_height") or 0))
  cfg.defaults.align_x = clamp(math.floor(number_field(defaults, "align_x") or 50), 0, 100)
  cfg.defaults.align_y = clamp(math.floor(number_field(defaults, "align_y") or 50), 0, 100)
  -- `step` moved from defaults to settings in 0.2; the old place is still read.
  cfg.settings.step = clamp(math.floor(number_field(settings, "step") or number_field(defaults, "step") or 5), 1, 25)
  cfg.defaults.step = cfg.settings.step
  cfg.settings.fine_step = clamp(math.floor(number_field(settings, "fine_step") or 1), 1, 25)
  local notify = string_field(settings, "notify")
  if M.notify_levels[notify] then
    cfg.settings.notify = notify
  end
  cfg.settings.all_workspaces = settings:match('"all_workspaces"%s*:%s*(%a+)') == "true"
  cfg.settings.paused = settings:match('"paused"%s*:%s*(%a+)') == "true"
  cfg.settings.max_windows = clamp(math.floor(number_field(settings, "max_windows") or 1), 1, 10)

  local monitors = find_object(text, "monitors")
  if monitors then
    for key, body in monitors:gmatch('"([^"]+)"%s*:%s*{(.-)}') do
      local block = { key = key }
      for _, field in ipairs({ "width", "height" }) do
        local v = number_field(body, field)
        if v then
          block[field] = clamp(math.floor(v), min, M.limits.max)
        end
      end
      for _, field in ipairs({ "max_width", "max_height" }) do
        local v = number_field(body, field)
        if v then
          block[field] = math.max(0, math.floor(v))
        end
      end
      for _, field in ipairs({ "align_x", "align_y" }) do
        local v = number_field(body, field)
        if v then
          block[field] = clamp(math.floor(v), 0, 100)
        end
      end
      cfg.monitors[#cfg.monitors + 1] = block
    end
  end

  -- Presets keep file order, which is the cycling order; `true` entries and
  -- object entries are collected in one pass so the order holds.
  local presets = find_object(text, "presets")
  if presets then
    local pos = 1
    while true do
      local _, colon, name = presets:find('"([^"]+)"%s*:%s*', pos)
      if colon == nil then
        break
      end
      local entry
      pos = colon + 1
      if presets:sub(pos, pos + 3) == "true" then
        entry = { mode = "default" }
        pos = pos + 4
      elseif presets:sub(pos, pos) == "{" then
        local _, close = presets:find("%b{}", pos)
        entry = close and parse_entry(presets:sub(pos + 1, close - 1), cfg.defaults, min)
        pos = (close or pos) + 1
      end
      if entry then
        cfg.presets[#cfg.presets + 1] = { name = name, entry = entry }
      end
    end
  end

  local workspaces = find_object(text, "workspaces")
  if workspaces then
    for id in workspaces:gmatch('"(%d+)"%s*:%s*true') do
      cfg.workspaces[tonumber(id)] = { mode = "default" }
    end
    -- An explicit off, which only means something with all_workspaces on.
    for id in workspaces:gmatch('"(%d+)"%s*:%s*false') do
      cfg.workspaces[tonumber(id)] = false
    end
    for id, body in workspaces:gmatch('"(%d+)"%s*:%s*{(.-)}') do
      cfg.workspaces[tonumber(id)] = parse_entry(body, cfg.defaults, min)
    end
  end

  return cfg
end

-- The fields of a defaults-like table: width and height when present, caps
-- only when set.
function M.encode_size(d)
  local parts = {}
  for _, k in ipairs({ "width", "height" }) do
    if d[k] ~= nil then
      parts[#parts + 1] = string.format('"%s": %d', k, d[k])
    end
  end
  for _, k in ipairs({ "max_width", "max_height" }) do
    if (d[k] or 0) > 0 then
      parts[#parts + 1] = string.format('"%s": %d', k, d[k])
    end
  end
  -- Alignment only when it is not the centre, which is what an absent field means.
  for _, k in ipairs({ "align_x", "align_y" }) do
    if d[k] ~= nil and d[k] ~= 50 then
      parts[#parts + 1] = string.format('"%s": %d', k, d[k])
    end
  end
  return table.concat(parts, ", ")
end

local function encode_monitors(monitors)
  if #monitors == 0 then
    return ""
  end
  local lines = {}
  for _, block in ipairs(monitors) do
    lines[#lines + 1] = string.format('    "%s": { %s }', block.key, M.encode_size(block))
  end
  return '  "monitors": {\n' .. table.concat(lines, ",\n") .. "\n  },\n"
end

function M.encode_entry(e)
  if e == false then
    return "false"
  elseif e.mode == "default" then
    return "true"
  elseif e.mode == "aspect" then
    return string.format('{ "mode": "aspect", "ratio": [%g, %g] }', e.ratio_w, e.ratio_h)
  end
  return string.format('{ "mode": "size", "width": %d, "height": %d }', e.width, e.height)
end

local function encode_presets(presets)
  if #presets == 0 then
    return ""
  end
  local lines = {}
  for _, p in ipairs(presets) do
    lines[#lines + 1] = string.format('    "%s": %s', p.name, M.encode_entry(p.entry))
  end
  return '  "presets": {\n' .. table.concat(lines, ",\n") .. "\n  },\n"
end

function M.encode_config(cfg)
  local ids = {}
  for id in pairs(cfg.workspaces) do
    ids[#ids + 1] = id
  end
  table.sort(ids)

  local lines = {}
  for _, id in ipairs(ids) do
    lines[#lines + 1] = string.format('    "%d": %s', id, M.encode_entry(cfg.workspaces[id]))
  end

  return string.format(
    '{\n  "settings": { "step": %d, "fine_step": %d, "notify": "%s", "all_workspaces": %s, "max_windows": %d, "min_percent": %d, "paused": %s },\n  "defaults": { %s },\n%s%s  "workspaces": {\n%s\n  }\n}\n',
    cfg.settings.step,
    cfg.settings.fine_step,
    cfg.settings.notify,
    tostring(cfg.settings.all_workspaces),
    cfg.settings.max_windows,
    cfg.settings.min_percent,
    tostring(cfg.settings.paused),
    M.encode_size(cfg.defaults),
    encode_monitors(cfg.monitors),
    encode_presets(cfg.presets),
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

-- `level` is the least chatty setting that still shows this message.
local function notify(message, level)
  if not (hl and hl.exec_cmd) then
    return
  end
  local wanted = M.notify_levels[level or "changes"] or 1
  if (M.notify_levels[M.config.settings.notify] or 2) < wanted then
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

-- What a workspace is set to once all_workspaces is taken into account: an
-- explicit entry wins, false is off, and with nothing written the workspace
-- follows the defaults when all_workspaces is on.
function M.entry_for(id)
  local entry = M.config.workspaces[id]
  if entry == false then
    return nil
  end
  if entry == nil and M.config.settings.all_workspaces then
    return { mode = "default" }
  end
  return entry
end

local function workspace_monitor(id)
  local ws = hl.get_workspace(id)
  return ws and ws.monitor or nil
end

local function describe(id, entry)
  local suffix = entry.mode == "default" and " (default)" or ""
  entry = M.resolve(entry, workspace_monitor(id))
  if entry.mode == "aspect" then
    return string.format("Ichi: workspace %d at %g:%g%s", id, entry.ratio_w, entry.ratio_h, suffix)
  end
  return string.format("Ichi: workspace %d at %d%% x %d%%%s", id, entry.width, entry.height, suffix)
end

-- A tabbed group occupies one tile however many windows it holds, so Ichi
-- counts it once. Every member reports the same `current` window, which makes
-- that window's address a stable name for the group. Returns nil for a window
-- that is in no group.
local function group_key(w)
  local group = w.group
  if group == nil then
    return nil
  end
  if group.current then
    return group.current.address
  end
  -- A group with no current window is not something Hyprland normally
  -- reports; fall back to its first member so the group still counts once.
  local members = group.members
  if type(members) == "table" and members[1] then
    return members[1].address
  end
  return w.address
end

function M.apply(id)
  local ws = hl.get_workspace(id)
  if ws == nil or ws.special then
    return
  end

  local base = base_gaps()
  local entry = M.entry_for(id)
  local function plain()
    hl.workspace_rule({ workspace = tostring(id), gaps_out = base })
  end

  -- Paused is a runtime veto, not a config change: every workspace goes back
  -- to normal gaps and keeps its entry, so resuming restores the lot.
  if M.config.settings.paused then
    plain()
    return
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
  local seen_groups = {}
  for _, w in ipairs(hl.get_workspace_windows(id) or {}) do
    if not w.floating then
      local key = group_key(w)
      if key == nil then
        count = count + 1
        tiled = w
      elseif not seen_groups[key] then
        -- First member of this group: the group is one window from here on.
        seen_groups[key] = true
        count = count + 1
        tiled = w
      end
    end
  end
  if count == 0 or count > M.config.settings.max_windows or tiled.monitor == nil then
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
  hl.workspace_rule({ workspace = tostring(id), gaps_out = M.gaps_for(usable_w, usable_h, M.resolve(entry, mon), base) })
end

function M.refresh()
  for id in pairs(M.config.workspaces) do
    touched[id] = true
  end
  -- With all_workspaces on, every workspace is Ichi's to manage; they stay in
  -- `touched` afterwards so turning the setting off resets their gaps.
  if M.config.settings.all_workspaces and hl.get_workspaces then
    for _, ws in ipairs(hl.get_workspaces() or {}) do
      if not ws.special then
        touched[ws.id] = true
      end
    end
  end
  for id in pairs(touched) do
    M.apply(id)
  end
end

local function current_id()
  local ws = hl.get_active_workspace()
  return ws and ws.id or nil
end

local function commit(id, entry, message, level)
  M.config.workspaces[id] = entry
  M.save()
  M.refresh()
  notify(message, level)
end

-- Without an explicit entry the workspace follows the defaults, now and
-- whenever they change. With all_workspaces on that is what an absent entry
-- already means, so the file stays clean.
function M.enable(id, entry)
  id = id or current_id()
  if id == nil then
    return
  end
  entry = M.normalize_entry(entry)
  local message = describe(id, entry or { mode = "default" })
  if entry == nil and not M.config.settings.all_workspaces then
    entry = { mode = "default" }
  end
  commit(id, entry, message)
end

-- Off; written as false when all_workspaces would otherwise turn it on.
function M.disable(id)
  id = id or current_id()
  if id == nil then
    return
  end
  local entry = nil
  if M.config.settings.all_workspaces then
    entry = false
  end
  commit(id, entry, string.format("Ichi: workspace %d off", id))
end

function M.toggle(id)
  id = id or current_id()
  if id == nil then
    return
  end
  if M.entry_for(id) then
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
  local mon = workspace_monitor(id)
  local entry = M.resolve(M.entry_for(id), mon)
  if entry == nil or entry.mode ~= "size" then
    entry = M.resolve({ mode = "default" }, mon)
  end
  entry.width = clamp(entry.width + (delta_width or 0), floor_percent(), M.limits.max)
  entry.height = clamp(entry.height + (delta_height or 0), floor_percent(), M.limits.max)
  commit(id, entry, describe(id, entry), "always")
end

-- What a binding calls: directions as -1, 0 or 1, scaled by the configured
-- step, or by the fine step when `fine` is set.
function M.nudge(dir_width, dir_height, fine, id)
  local step = fine and M.config.settings.fine_step or M.config.settings.step
  M.adjust((dir_width or 0) * step, (dir_height or 0) * step, id)
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

-- Back to following the defaults.
function M.reset(id)
  id = id or current_id()
  if id == nil or M.entry_for(id) == nil then
    return
  end
  local entry = { mode = "default" }
  local written = entry
  if M.config.settings.all_workspaces then
    written = nil
  end
  commit(id, written, describe(id, entry))
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
  local d, s = M.config.defaults, M.config.settings
  d.width = clamp(math.floor(positive(width, d.width)), floor_percent(), M.limits.max)
  d.height = clamp(math.floor(positive(height, d.height)), floor_percent(), M.limits.max)
  s.step = clamp(math.floor(positive(step, s.step)), 1, 25)
  d.step = s.step -- kept in sync so bindings written against 0.1 still work
  M.save()
  M.refresh() -- workspaces that follow the defaults pick the change up
  notify(string.format("Ichi: defaults %d%% x %d%%", d.width, d.height))
end

-- Pixel caps on the box, whatever the percentage works out to. Zero is none.
function M.set_max(width, height)
  local d = M.config.defaults
  d.max_width = math.max(0, math.floor(tonumber(width) or 0))
  d.max_height = math.max(0, math.floor(tonumber(height) or 0))
  M.save()
  M.refresh()
  local function show(v)
    return v > 0 and (v .. "px") or "none"
  end
  notify(string.format("Ichi: max width %s, max height %s", show(d.max_width), show(d.max_height)))
end

-- Where the box sits in the slack: 0 is the left or top edge, 50 the centre,
-- 100 the right or bottom. Nil keeps a value.
function M.set_align(x, y)
  local d = M.config.defaults
  if tonumber(x) then
    d.align_x = clamp(math.floor(tonumber(x)), 0, 100)
  end
  if tonumber(y) then
    d.align_y = clamp(math.floor(tonumber(y)), 0, 100)
  end
  M.save()
  M.refresh()
  notify(string.format("Ichi: aligned at %d%% across, %d%% down", d.align_x, d.align_y))
end

-- Arrow-key increments in percentage points. Zero or nil keeps a value.
function M.set_step(step, fine)
  local s = M.config.settings
  s.step = clamp(math.floor(positive(step, s.step)), 1, 25)
  s.fine_step = clamp(math.floor(positive(fine, s.fine_step)), 1, 25)
  M.config.defaults.step = s.step
  M.save()
  notify(string.format("Ichi: step %d, fine step %d", s.step, s.fine_step))
end

-- The smallest share of the screen a size may be. Sizes already below the
-- new floor are left as they are until they are next touched.
function M.set_min_percent(n)
  M.config.settings.min_percent = clamp(math.floor(tonumber(n) or 20), M.limits.min, M.limits.max)
  M.save()
  notify(string.format("Ichi: sizes go down to %d%%", M.config.settings.min_percent))
end

-- How many tiled windows may share the box before the inset gives way.
function M.set_max_windows(n)
  M.config.settings.max_windows = clamp(math.floor(tonumber(n) or 1), 1, 10)
  M.save()
  M.refresh()
  notify(string.format("Ichi: inset holds up to %d window%s", M.config.settings.max_windows,
    M.config.settings.max_windows == 1 and "" or "s"))
end

-- Suspend Ichi everywhere without touching a single workspace entry, for
-- screen sharing or a presentation. Resuming puts every inset back.
function M.set_paused(on)
  M.config.settings.paused = on == true or on == "true" or on == "on"
  M.save()
  M.refresh()
  notify(M.config.settings.paused and "Ichi: paused everywhere" or "Ichi: resumed")
end

function M.toggle_pause()
  M.set_paused(not M.config.settings.paused)
end

-- Every workspace on unless it opts out with a false entry.
function M.set_all_workspaces(on)
  M.config.settings.all_workspaces = on == true or on == "true" or on == "on"
  M.save()
  M.refresh()
  notify("Ichi: all workspaces " .. (M.config.settings.all_workspaces and "on" or "off"))
end

-- "never", "changes" or "always"; see M.notify_levels.
function M.set_notify(level)
  if not M.notify_levels[level] then
    return
  end
  M.config.settings.notify = level
  M.save()
  notify("Ichi: notifications " .. level)
end

-- ---------------------------------------------------------------- presets --

local function same_entry(a, b)
  if a == nil or b == nil or a.mode ~= b.mode then
    return false
  end
  if a.mode == "aspect" then
    return a.ratio_w == b.ratio_w and a.ratio_h == b.ratio_h
  end
  return a.mode == "default" or (a.width == b.width and a.height == b.height)
end

local function preset_index(name_or_entry)
  for i, p in ipairs(M.config.presets) do
    if p.name == name_or_entry or same_entry(p.entry, name_or_entry) then
      return i
    end
  end
  return nil
end

local function apply_preset(id, preset)
  local entry = M.normalize_entry(preset.entry)
  commit(id, entry, describe(id, entry) .. string.format(" (%s)", preset.name))
end

-- Give the workspace a preset by name.
function M.preset(name, id)
  id = id or current_id()
  local i = id and preset_index(name)
  if i == nil then
    notify(string.format("Ichi: no preset called '%s'", tostring(name)))
    return
  end
  apply_preset(id, M.config.presets[i])
end

-- Step through the presets in file order; a workspace on none of them starts
-- at the first (or, going backwards, the last).
function M.cycle(delta, id)
  id = id or current_id()
  if id == nil then
    return
  end
  local n = #M.config.presets
  if n == 0 then
    notify("Ichi: no presets yet; save one with ichi.save_preset('name')")
    return
  end
  delta = tonumber(delta) or 1
  local i = preset_index(M.entry_for(id))
  if i == nil then
    i = delta < 0 and n or 1
  else
    i = (i - 1 + delta) % n + 1
  end
  apply_preset(id, M.config.presets[i])
end

-- Keep the workspace's current entry as a preset, replacing one of that name.
function M.save_preset(name, id)
  id = id or current_id()
  local entry = id and M.entry_for(id)
  name = tostring(name or ""):gsub('[\\"]', "")
  if entry == nil or name == "" then
    return
  end
  local i = preset_index(name)
  local preset = { name = name, entry = M.normalize_entry(entry) }
  if i then
    M.config.presets[i] = preset
  else
    M.config.presets[#M.config.presets + 1] = preset
  end
  M.save()
  notify(string.format("Ichi: preset '%s' saved", name))
end

function M.remove_preset(name)
  local i = preset_index(name)
  if i == nil then
    return
  end
  table.remove(M.config.presets, i)
  M.save()
  notify(string.format("Ichi: preset '%s' removed", tostring(name)))
end

-- The key a monitor gets in the monitors block: its description when it has
-- one, since that survives replugging, else its connector name.
local function monitor_key(mon)
  local desc = (mon.description or ""):gsub('[\\"]', "")
  if desc ~= "" then
    return "desc:" .. desc
  end
  return mon.name
end

-- Tune a workspace with the arrows, then make that the default for the rest.
-- The workspace itself goes back to following the defaults, so a later
-- change to them reaches it too. With scope "monitor" the size goes into the
-- block for the workspace's monitor instead, and only displays matching it
-- follow.
function M.adopt_defaults(id, scope)
  id = id or current_id()
  if id == nil then
    return
  end
  -- Adopt copies a concrete size out of a workspace, so there has to be one.
  -- Reachable from a key and a menu row now, where silence reads as broken.
  local entry = M.entry_for(id)
  if entry == nil then
    notify(string.format("Ichi: workspace %d is off, so there is no size to adopt", id))
    return
  elseif entry.mode == "default" then
    notify(string.format("Ichi: workspace %d already follows the defaults; nudge it first", id))
    return
  elseif entry.mode ~= "size" then
    notify(string.format("Ichi: workspace %d is an aspect ratio, and adopt takes a size", id))
    return
  end
  if scope == "monitor" then
    local mon = workspace_monitor(id)
    if mon == nil then
      return
    end
    local block = M.monitor_block(mon)
    if block == nil then
      block = { key = monitor_key(mon) }
      M.config.monitors[#M.config.monitors + 1] = block
    end
    block.width, block.height = entry.width, entry.height
    M.config.workspaces[id] = { mode = "default" }
    M.save()
    M.refresh()
    notify(string.format("Ichi: %s at %d%% x %d%%", block.key, entry.width, entry.height))
    return
  end
  M.config.workspaces[id] = { mode = "default" }
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
  hl.on("workspace.created", function()
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
  -- A workspace's monitor decides which overrides apply, so follow moves.
  for _, event in ipairs({ "monitor.layout_changed", "monitor.added", "monitor.removed", "workspace.move_to_monitor" }) do
    hl.on(event, function()
      M.refresh()
    end)
  end
end

return M

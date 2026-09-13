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

-- The state file. To keep it somewhere else, set this after the dofile line
-- and call ichi.load().
M.config_path = CONFIG_DIR .. "/ichi/ichi.json"
-- Where it lived before 0.7, under Omarchy's directory. While nothing exists
-- at config_path, a file here is read and written where it is, never moved,
-- so a link into a dotfiles repo keeps working.
M.previous_config_path = CONFIG_DIR .. "/omarchy/ichi.json"

-- Every size is clamped between these, in percent of the usable area. The
-- floor was a setting, min_percent, until 0.7; lowering it later breaks
-- nothing, raising it would clamp sizes people have stored.
M.limits = { min = 10, max = 100 }
-- Hyprland's own layouts. Anything else is a plugin-registered layout that
-- owns how its workspace tiles, and Ichi yields to it.
M.builtin_layouts = { dwindle = true, master = true, scrolling = true, monocle = true }

-- Notification levels: "never" is silent, "changes" reports toggles, resets
-- and setting changes, "always" also reports every arrow-key nudge.
M.notify_levels = { never = 0, changes = 1, always = 2 }

local function default_config()
  return {
    settings = { step = 5, fine_step = 1, notify = "changes", all_workspaces = false, max_windows = 1, paused = false },
    defaults = { width = 70, height = 80, max_width = 0, max_height = 0, align_x = 50, align_y = 50 },
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
function M.normalize_entry(entry, defaults)
  defaults = defaults or M.config.defaults
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
    width = clamp(math.floor(tonumber(entry.width) or defaults.width), M.limits.min, M.limits.max),
    height = clamp(math.floor(tonumber(entry.height) or defaults.height), M.limits.min, M.limits.max),
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
local function parse_entry(body, defaults)
  local rw, rh = body:match('"ratio"%s*:%s*%[%s*(%d+%.?%d*)%s*,%s*(%d+%.?%d*)%s*%]')
  return M.normalize_entry({
    mode = body:match('"mode"%s*:%s*"(%a+)"'),
    width = number_field(body, "width"),
    height = number_field(body, "height"),
    ratio_w = rw,
    ratio_h = rh,
  }, defaults)
end

function M.parse_config(text)
  local cfg = default_config()
  if type(text) ~= "string" then
    return cfg
  end

  local defaults = find_object(text, "defaults") or ""
  local settings = find_object(text, "settings") or ""
  local min = M.limits.min
  cfg.defaults.width = clamp(math.floor(number_field(defaults, "width") or 70), min, M.limits.max)
  cfg.defaults.height = clamp(math.floor(number_field(defaults, "height") or 80), min, M.limits.max)
  cfg.defaults.max_width = math.max(0, math.floor(number_field(defaults, "max_width") or 0))
  cfg.defaults.max_height = math.max(0, math.floor(number_field(defaults, "max_height") or 0))
  cfg.defaults.align_x = clamp(math.floor(number_field(defaults, "align_x") or 50), 0, 100)
  cfg.defaults.align_y = clamp(math.floor(number_field(defaults, "align_y") or 50), 0, 100)
  cfg.settings.step = clamp(math.floor(number_field(settings, "step") or 5), 1, 25)
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
        entry = close and parse_entry(presets:sub(pos + 1, close - 1), cfg.defaults)
        pos = (close or pos) + 1
      end
      if entry then
        cfg.presets[#cfg.presets + 1] = { name = name, entry = entry }
      end
    end
  end

  local workspaces = find_object(text, "workspaces")
  if workspaces then
    -- Keys are workspace names. Hyprland names a numeric workspace by its
    -- number, so "2" keeps meaning workspace 2 and a 0.3 config still loads.
    for key in workspaces:gmatch('"([^"]+)"%s*:%s*true') do
      cfg.workspaces[key] = { mode = "default" }
    end
    -- An explicit off, which only means something with all_workspaces on.
    for key in workspaces:gmatch('"([^"]+)"%s*:%s*false') do
      cfg.workspaces[key] = false
    end
    for key, body in workspaces:gmatch('"([^"]+)"%s*:%s*{(.-)}') do
      cfg.workspaces[key] = parse_entry(body, cfg.defaults)
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
  -- Numeric workspaces in numeric order, then named ones alphabetically, so
  -- the file reads the way a person would write it.
  table.sort(ids, function(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then
      return na < nb
    elseif na then
      return true
    elseif nb then
      return false
    end
    return a < b
  end)

  local lines = {}
  for _, id in ipairs(ids) do
    lines[#lines + 1] = string.format('    "%s": %s', id, M.encode_entry(cfg.workspaces[id]))
  end

  return string.format(
    '{\n  "settings": { "step": %d, "fine_step": %d, "notify": "%s", "all_workspaces": %s, "max_windows": %d, "paused": %s },\n  "defaults": { %s },\n%s%s  "workspaces": {\n%s\n  }\n}\n',
    cfg.settings.step,
    cfg.settings.fine_step,
    cfg.settings.notify,
    tostring(cfg.settings.all_workspaces),
    cfg.settings.max_windows,
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

local function shell_quote(value)
  return "'" .. (tostring(value):gsub("'", "'\\''")) .. "'"
end

local function exists(path)
  local file = io.open(path, "r")
  if file then
    file:close()
  end
  return file ~= nil
end

-- Where a path really points once every link is followed, or the path itself
-- when that cannot be worked out, as for a file not written yet.
local function real_path(path)
  local pipe = io.popen("readlink -f -- " .. shell_quote(path) .. " 2>/dev/null")
  local out = pipe and pipe:read("*l")
  if pipe then
    pipe:close()
  end
  if out == nil or out == "" then
    return path
  end
  return out
end

-- Replace the file whole: write a sibling, then rename it over, so a crash or
-- a full disk mid-write leaves the old file rather than half of the new one.
-- `path` is already resolved, so a link into a dotfiles repo is kept and the
-- file it points to is replaced. Anything that stops the sibling being
-- written falls back to writing in place.
local function write_file(path, text)
  local tmp = path .. ".tmp"
  local file = io.open(tmp, "w")
  if file then
    local written = file:write(text)
    local closed = file:close()
    if written and closed and os.rename(tmp, path) then
      return true
    end
    os.remove(tmp)
  end
  file = io.open(path, "w")
  if not file then
    return false
  end
  local written = file:write(text)
  return file:close() and written ~= nil
end

-- Whether text is shaped like a whole JSON object: it opens with a brace, and
-- its braces and brackets pair up, outside strings, to close exactly at the
-- end. parse_config forgives a bad entry, which is right for a typo, but a
-- file cut short reads as a block with nothing in it, and saving that would
-- delete every workspace the lost half held.
function M.well_formed(text)
  local pos = text:match("^%s*(){")
  if pos == nil then
    return false
  end
  local closer = { ["{"] = "}", ["["] = "]" }
  local stack = {}
  while true do
    pos = text:find('[{}%[%]"]', pos)
    if pos == nil then
      return false
    end
    local c = text:sub(pos, pos)
    if c == '"' then
      -- Skip the string, escapes included, so a brace in a name is not counted.
      repeat
        pos = text:find('[\\"]', pos + 1)
        if pos == nil then
          return false
        end
        local escape = text:sub(pos, pos) == "\\"
        if escape then
          pos = pos + 1
        end
      until not escape
    elseif closer[c] then
      stack[#stack + 1] = closer[c]
    elseif table.remove(stack) ~= c then
      return false
    elseif #stack == 0 then
      return text:find("^%s*$", pos + 1) ~= nil
    end
    pos = pos + 1
  end
end

-- Defined with the rest of the Hyprland side below; load() reports through it.
local notify

-- Set while the state file does not parse. Ichi keeps running on the last
-- good settings and writes nothing, so whatever is in the file, a hand-edit
-- in progress or a write cut short, is still there to fix.
M.unreadable = false

-- The file in use: config_path, unless nothing is there and a file from
-- before 0.7 is.
function M.state_path()
  if M.previous_config_path and not exists(M.config_path) and exists(M.previous_config_path) then
    return M.previous_config_path
  end
  return M.config_path
end

-- The file load() and save() last agreed on: its path, where that path really
-- points, and the text it holds. The shell asks for a load after every save,
-- so an unchanged file costs a comparison rather than a parse, and links are
-- only followed again when something other than Ichi changed the file.
local in_use = { path = nil, target = nil, text = nil }

function M.save()
  if M.unreadable then
    return
  end
  if in_use.path == nil then
    in_use.path = M.state_path()
    in_use.target = real_path(in_use.path)
  end
  if not exists(in_use.target) then
    -- The first save, or the file was deleted: make sure its directory exists.
    local dir = in_use.target:match("^(.*)/")
    if dir then
      os.execute("mkdir -p " .. shell_quote(dir))
    end
  end
  local text = M.encode_config(M.config)
  if write_file(in_use.target, text) then
    in_use.text = text
  end
end

function M.load()
  local path = M.state_path()
  local text = read_file(path)
  if text ~= nil and text == in_use.text and path == in_use.path and not M.unreadable then
    return
  end
  in_use.path, in_use.target, in_use.text = path, real_path(path), nil

  if text == nil then
    M.unreadable = false
    M.config = M.parse_config("")
    return
  end
  if not M.well_formed(text) then
    if not M.unreadable then
      M.unreadable = true
      local shown = path
      if HOME ~= "" and shown:sub(1, #HOME + 1) == HOME .. "/" then
        shown = "~" .. shown:sub(#HOME + 1)
      end
      notify(string.format("Ichi: %s does not parse, so nothing is saved until it does. Fix it, or delete it to start over.", shown))
    end
    return
  end
  M.unreadable = false
  in_use.text = text
  M.config = M.parse_config(text)
end

-- -------------------------------------------------------------- hyprland --

-- Omarchy's notifier when it is installed, libnotify when it is not, so this
-- file runs on a plain Hyprland session. Resolved per call rather than once at
-- load: nothing here is hot, and a session that gains either one is covered.
function M.notify_command(message)
  local quoted = shell_quote(message)
  return "if command -v omarchy-notification-send >/dev/null 2>&1; then"
    .. " omarchy-notification-send -u low " .. quoted .. ";"
    .. " else notify-send -u low -a Ichi " .. quoted .. "; fi"
end

-- `level` is the least chatty setting that still shows this message.
function notify(message, level)
  if not (hl and hl.exec_cmd) or M.quiet then
    return
  end
  local wanted = M.notify_levels[level or "changes"] or 1
  if (M.notify_levels[M.config.settings.notify] or 2) < wanted then
    return
  end
  hl.exec_cmd(M.notify_command(message))
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
  if id == nil then
    return nil
  end
  -- Callers may hand this a number; keys are strings.
  local entry = M.config.workspaces[tostring(id)]
  if entry == false then
    return nil
  end
  if entry == nil and M.config.settings.all_workspaces then
    return { mode = "default" }
  end
  return entry
end

-- The live workspace a config key names. Keys are names, because a named
-- workspace's id is a negative pseudo-id that says nothing about which
-- workspace it is; its name is the stable handle, and a numeric workspace's
-- name is its number.
local function workspace_for(key)
  if not (hl and hl.get_workspaces) then
    return nil
  end
  for _, ws in ipairs(hl.get_workspaces() or {}) do
    if not ws.special and tostring(ws.name) == key then
      return ws
    end
  end
  return nil
end

local function workspace_monitor(key)
  local ws = workspace_for(key)
  return ws and ws.monitor or nil
end

local function describe(id, entry)
  local suffix = entry.mode == "default" and " (default)" or ""
  entry = M.resolve(entry, workspace_monitor(id))
  if entry.mode == "aspect" then
    return string.format("Ichi: workspace %s at %g:%g%s", id, entry.ratio_w, entry.ratio_h, suffix)
  end
  return string.format("Ichi: workspace %s at %d%% x %d%%%s", id, entry.width, entry.height, suffix)
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
  local ws = workspace_for(id)
  if ws == nil then
    return
  end
  -- config_name is the selector the compositor understands: the number for a
  -- numeric workspace, "name:foo" for a named one.
  local selector = tostring(ws.config_name or ws.name)

  local base = base_gaps()
  local entry = M.entry_for(id)
  local function plain()
    hl.workspace_rule({ workspace = selector, gaps_out = base })
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
      notify(string.format("Ichi: yielding to the '%s' layout on workspace %s", layout, id))
    end
    plain()
    return
  end

  local tiled, count = nil, 0
  local seen_groups = {}
  for _, w in ipairs(hl.get_workspace_windows(ws.id) or {}) do
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
  hl.workspace_rule({ workspace = selector, gaps_out = M.gaps_for(usable_w, usable_h, M.resolve(entry, mon), base) })
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
        touched[tostring(ws.name)] = true
      end
    end
  end
  for id in pairs(touched) do
    M.apply(id)
  end
end

-- The focused workspace's key, or nil when there is nothing to act on.
local function current_id()
  local ws = hl.get_active_workspace()
  if ws == nil or ws.special then
    return nil
  end
  return tostring(ws.name)
end

-- Callers may pass a number, a name, or nothing at all. Keys are strings.
local function key_of(id)
  if id == nil then
    return current_id()
  end
  return tostring(id)
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
  id = key_of(id)
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
  id = key_of(id)
  if id == nil then
    return
  end
  local entry = nil
  if M.config.settings.all_workspaces then
    entry = false
  end
  commit(id, entry, string.format("Ichi: workspace %s off", id))
end

function M.toggle(id)
  id = key_of(id)
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
  id = key_of(id)
  if id == nil then
    return
  end
  local mon = workspace_monitor(id)
  local entry = M.resolve(M.entry_for(id), mon)
  if entry == nil or entry.mode ~= "size" then
    entry = M.resolve({ mode = "default" }, mon)
  end
  entry.width = clamp(entry.width + (delta_width or 0), M.limits.min, M.limits.max)
  entry.height = clamp(entry.height + (delta_height or 0), M.limits.min, M.limits.max)
  commit(id, entry, describe(id, entry), "always")
end

-- Set a workspace's size outright. The arrows work in deltas, but a slider
-- knows the number it wants, and rounding a delta from a moving value drifts.
function M.set_size(width, height, id)
  id = key_of(id)
  if id == nil then
    return
  end
  local mon = workspace_monitor(id)
  local entry = M.resolve(M.entry_for(id), mon)
  if entry == nil or entry.mode ~= "size" then
    entry = M.resolve({ mode = "default" }, mon)
  end
  entry.width = clamp(math.floor(tonumber(width) or entry.width), M.limits.min, M.limits.max)
  entry.height = clamp(math.floor(tonumber(height) or entry.height), M.limits.min, M.limits.max)
  commit(id, M.normalize_entry(entry), describe(id, entry), "always")
end

-- What a binding calls: directions as -1, 0 or 1, scaled by the configured
-- step, or by the fine step when `fine` is set.
function M.nudge(dir_width, dir_height, fine, id)
  local step = fine and M.config.settings.fine_step or M.config.settings.step
  M.adjust((dir_width or 0) * step, (dir_height or 0) * step, id)
end

function M.set_aspect(ratio_w, ratio_h, id)
  id = key_of(id)
  if id == nil then
    return
  end
  local entry = M.normalize_entry({ mode = "aspect", ratio_w = ratio_w, ratio_h = ratio_h })
  if entry == nil then
    return
  end
  commit(id, entry, describe(id, entry))
end

-- Back to following the defaults. Unlike reset(), this works on a workspace
-- that is off, turning it on: the panel offers "Default" as one of the sizes
-- whether or not Ichi is running there.
function M.reset(id)
  id = key_of(id)
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

-- --------------------------------------------------------------- settings --

local function parse_bool(value)
  if value == true or value == "true" or value == "on" then
    return true
  elseif value == false or value == "false" or value == "off" then
    return false
  end
  return nil
end

-- A whole number clamped to a range, as the file's own values are when read.
local function parse_int(lo, hi)
  return function(value)
    local n = tonumber(value)
    if n == nil or n ~= n or math.abs(n) == math.huge then
      return nil
    end
    return clamp(math.floor(n), lo, hi)
  end
end

-- Everything `ichi set` can change, keyed by its place in the file. `about`
-- is what a bad value is told; `apply` marks the ones that move a window.
M.settable = {
  ["settings.step"] = { parse = parse_int(1, 25), about = "a number of points from 1 to 25" },
  ["settings.fine_step"] = { parse = parse_int(1, 25), about = "a number of points from 1 to 25" },
  ["settings.notify"] = {
    parse = function(v)
      return M.notify_levels[v] and v or nil
    end,
    about = "never, changes or always",
  },
  ["settings.all_workspaces"] = { parse = parse_bool, about = "on or off", apply = true },
  ["settings.max_windows"] = { parse = parse_int(1, 10), about = "a number of windows from 1 to 10", apply = true },
  ["settings.paused"] = { parse = parse_bool, about = "on or off", apply = true },
  ["defaults.width"] = { parse = parse_int(M.limits.min, M.limits.max), about = "a percentage from 10 to 100", apply = true },
  ["defaults.height"] = { parse = parse_int(M.limits.min, M.limits.max), about = "a percentage from 10 to 100", apply = true },
  ["defaults.max_width"] = { parse = parse_int(0, 100000), about = "a number of pixels, 0 for no cap", apply = true },
  ["defaults.max_height"] = { parse = parse_int(0, 100000), about = "a number of pixels, 0 for no cap", apply = true },
  ["defaults.align_x"] = { parse = parse_int(0, 100), about = "0 to 100, with 50 the centre", apply = true },
  ["defaults.align_y"] = { parse = parse_int(0, 100), about = "0 to 100, with 50 the centre", apply = true },
}

-- Store one setting without saving or saying anything. Nil when the key is
-- unknown or the value does not fit it.
local function assign(key, value)
  local spec = M.settable[key]
  local parsed = spec and spec.parse(value)
  if parsed == nil then
    return nil
  end
  local section, field = key:match("^(%a+)%.(.+)$")
  M.config[section][field] = parsed
  return parsed
end

-- Change one setting by its place in the file: set("settings.step", 10),
-- set("defaults.width", "65"). Values may be strings, as they arrive from the
-- command line. Returns true when the setting took the value.
function M.set(key, value)
  local spec = M.settable[key]
  if spec == nil then
    notify(string.format("Ichi: there is no setting called '%s'", tostring(key)))
    return false
  end
  local parsed = assign(key, value)
  if parsed == nil then
    notify(string.format("Ichi: %s takes %s", key, spec.about))
    return false
  end
  M.save()
  if spec.apply then
    M.refresh()
  end
  notify(string.format("Ichi: %s is %s", key, tostring(parsed)))
  return true
end

-- The setters set() replaces. Deprecated in 0.7 and gone in 1.0; each still
-- does what it did, including zero or nil leaving a value alone.
local function settle(message)
  M.save()
  M.refresh()
  notify(message)
end

local function positive(value)
  return (tonumber(value) or 0) > 0
end

function M.set_defaults(width, height, step)
  if positive(width) then
    assign("defaults.width", width)
  end
  if positive(height) then
    assign("defaults.height", height)
  end
  if positive(step) then
    assign("settings.step", step)
  end
  settle(string.format("Ichi: defaults %d%% x %d%%", M.config.defaults.width, M.config.defaults.height))
end

function M.set_max(width, height)
  assign("defaults.max_width", tonumber(width) or 0)
  assign("defaults.max_height", tonumber(height) or 0)
  settle(string.format("Ichi: max width %dpx, max height %dpx (0 is no cap)", M.config.defaults.max_width, M.config.defaults.max_height))
end

function M.set_align(x, y)
  assign("defaults.align_x", x)
  assign("defaults.align_y", y)
  settle(string.format("Ichi: aligned at %d%% across, %d%% down", M.config.defaults.align_x, M.config.defaults.align_y))
end

function M.set_step(step, fine)
  if positive(step) then
    assign("settings.step", step)
  end
  if positive(fine) then
    assign("settings.fine_step", fine)
  end
  settle(string.format("Ichi: step %d, fine step %d", M.config.settings.step, M.config.settings.fine_step))
end

-- The floor is fixed now, so there is nothing left to set.
function M.set_min_percent()
  notify(string.format("Ichi: the smallest size is fixed at %d%%", M.limits.min))
end

function M.set_max_windows(n)
  assign("settings.max_windows", tonumber(n) or 1)
  settle(string.format("Ichi: inset holds up to %d window%s", M.config.settings.max_windows,
    M.config.settings.max_windows == 1 and "" or "s"))
end

-- Run something without notifying, whatever the configured level. For a
-- caller that already shows what it did: the bar widget's panel sits in the
-- same corner as the notifications, so its own messages cover it up.
M.quiet = false

function M.silently(fn)
  local was = M.quiet
  M.quiet = true
  local ok, err = pcall(fn)
  M.quiet = was
  if not ok then
    error(err, 0)
  end
end

-- Suspend Ichi everywhere without touching a single workspace entry, for
-- screen sharing or a presentation. Resuming puts every inset back.
function M.set_paused(on)
  assign("settings.paused", parse_bool(on) == true)
  settle(M.config.settings.paused and "Ichi: paused everywhere" or "Ichi: resumed")
end

function M.toggle_pause()
  M.set_paused(not M.config.settings.paused)
end

-- Deprecated in 0.7 for set("settings.all_workspaces", ...); gone in 1.0.
function M.set_all_workspaces(on)
  assign("settings.all_workspaces", parse_bool(on) == true)
  settle("Ichi: all workspaces " .. (M.config.settings.all_workspaces and "on" or "off"))
end

-- Deprecated in 0.7 for set("settings.notify", ...); gone in 1.0.
function M.set_notify(level)
  if assign("settings.notify", level) then
    settle("Ichi: notifications " .. level)
  end
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
  id = key_of(id)
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
  id = key_of(id)
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
  id = key_of(id)
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
  id = key_of(id)
  if id == nil then
    return
  end
  -- Adopt copies a concrete size out of a workspace, so there has to be one.
  -- Reachable from a key and a menu row now, where silence reads as broken.
  local entry = M.entry_for(id)
  if entry == nil then
    notify(string.format("Ichi: workspace %s is off, so there is no size to adopt", id))
    return
  elseif entry.mode == "default" then
    notify(string.format("Ichi: workspace %s already follows the defaults; nudge it first", id))
    return
  elseif entry.mode ~= "size" then
    notify(string.format("Ichi: workspace %s is an aspect ratio, and adopt takes a size", id))
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
  assign("defaults.width", entry.width)
  assign("defaults.height", entry.height)
  settle(string.format("Ichi: defaults %d%% x %d%%", M.config.defaults.width, M.config.defaults.height))
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

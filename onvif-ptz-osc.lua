-- Minimal PTZ overlay for the Tapo Cameras Omarchy plugin's tiled mpv
-- stream view. Draws four small directional buttons in the bottom-right
-- corner of the video and calls onvif-ptz.sh (ContinuousMove/Stop) on
-- press/release.
--
-- Runs entirely inside mpv's own render/input loop -- no separate window,
-- no polling another process's geometry to stay in sync with it. That's
-- deliberate: an earlier overlay drawn *on top of* the small grid preview
-- (in Panel.qml, since removed) sat directly over the live video decode
-- and was laggy/flickery. A synced-via-hyprctl floating window for this
-- tiled view would have the same problem, just relocated. This avoids it
-- by not being a separate window at all.
--
-- Enabled per-launch (see Panel.qml's openStream()) via:
--   ONVIF_PASSWORD=<p> mpv --script=onvif-ptz-osc.lua
--       --script-opts=onvifptz-script=<path to onvif-ptz.sh>,
--                      onvifptz-host=<ip>,onvifptz-user=<u>
-- Only passed when the camera's "Pan/tilt" setting is on. If host/script
-- aren't set (script loaded standalone, or ptz off), the overlay just
-- doesn't activate.
--
-- The password is read from mpv's own environment (ONVIF_PASSWORD), not a
-- script-opt: script-opts end up in mpv's own /proc/<pid>/cmdline, which is
-- world-readable, for as long as the stream window stays open. The
-- environment is still per-process, but only readable by the same user (or
-- root).

local mp = require 'mp'
local msg = require 'mp.msg'

local opts = {
  script = "",
  host = "",
  user = "",
}
require('mp.options').read_options(opts, "onvifptz")
local pass = os.getenv("ONVIF_PASSWORD") or ""

if opts.script == "" or opts.host == "" then
  msg.verbose("onvif-ptz-osc: no host/script configured, overlay disabled")
  return
end

local BTN = 26     -- button size, OSD pixels
local GAP = 4
local MARGIN = 18

local overlay = mp.create_osd_overlay("ass-events")
local buttons = {}   -- dir -> {x0,y0,x1,y1,cx,cy}
local pressed_dir = nil

local GLYPH = { up = "\226\150\178", down = "\226\150\188", left = "\226\151\128", right = "\226\150\182" } -- ▲ ▼ ◀ ▶

local function layout()
  -- Multiple return values, not a table: (width, height, aspect).
  local w, h = mp.get_osd_size()
  if not w or w <= 0 or not h or h <= 0 then return end

  -- Top-right, not bottom-right: mpv's own on-screen controller (seek bar,
  -- title) lives along the bottom edge and was eating clicks meant for
  -- these buttons.
  local cell = BTN + GAP
  local ox = w - MARGIN - cell * 3
  local oy = MARGIN

  local function rect(gx, gy)
    local x0 = ox + gx * cell
    local y0 = oy + gy * cell
    return { x0 = x0, y0 = y0, x1 = x0 + BTN, y1 = y0 + BTN,
             cx = x0 + BTN / 2, cy = y0 + BTN / 2 }
  end

  -- Cross layout in a 3x3 cell grid: up/down/left/right, center empty.
  buttons = {
    up    = rect(1, 0),
    left  = rect(0, 1),
    right = rect(2, 1),
    down  = rect(1, 2),
  }
end

local function redraw()
  local w, h = mp.get_osd_size()
  if not w or w <= 0 then return end
  overlay.res_x = w
  overlay.res_y = h

  local parts = {}
  for dir, b in pairs(buttons) do
    local held = pressed_dir == dir
    local fill = held and "444444" or "000000"
    local alpha = held and "20" or "60"
    -- Filled square, then the glyph centered on top. Kept to plain
    -- rectangles (no bezier/rounded-corner path math) to minimize the
    -- chance of a malformed ASS draw command silently failing to render.
    table.insert(parts, string.format(
      "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H%s&\\1a&H%s&\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
      b.x0, b.y0, fill, alpha, BTN, BTN, BTN, BTN))
    table.insert(parts, string.format(
      "{\\an5\\pos(%d,%d)\\bord1\\shad0\\1c&HFFFFFF&\\3c&H000000&\\fs%d}%s",
      b.cx, b.cy, math.floor(BTN * 0.7), GLYPH[dir]))
  end
  overlay.data = table.concat(parts, "\n")
  overlay:update()
end

local function dir_at(x, y)
  if not x or not y then return nil end
  for dir, b in pairs(buttons) do
    if x >= b.x0 and x <= b.x1 and y >= b.y0 and y <= b.y1 then
      return dir
    end
  end
  return nil
end

-- The password travels as a subprocess environment variable (env), never
-- as one of args -- args end up in onvif-ptz.sh's own /proc/<pid>/cmdline,
-- which is world-readable; env is not.
local function run_async(args)
  mp.command_native_async({ name = "subprocess", args = args, playback_only = false,
    env = { "ONVIF_PASSWORD=" .. pass } }, function() end)
end

local function stop_ptz()
  if not pressed_dir then return end
  pressed_dir = nil
  redraw()
  run_async({ "bash", opts.script, "stop", opts.host, opts.user })
end

local function start_ptz(dir)
  pressed_dir = dir
  redraw()
  run_async({ "bash", opts.script, "move", opts.host, opts.user, dir })
end

-- Forced, not a plain binding, since it needs first look at every left
-- click to hit-test our buttons -- clicks that miss are handed back to
-- mpv's normal click-to-pause via the explicit "cycle pause" below, so
-- the rest of the window keeps behaving like any other mpv playback.
mp.add_forced_key_binding("MBTN_LEFT", "onvifptz-click", function(e)
  local pos = mp.get_property_native("mouse-pos")
  if e.event == "down" then
    local dir = dir_at(pos and pos.x, pos and pos.y)
    if dir then
      start_ptz(dir)
    else
      mp.command("cycle pause")
    end
  elseif e.event == "up" or e.event == "repeat" then
    stop_ptz()
  end
end, { complex = true })

-- Held past the button's edge (a slightly sloppy drag) should stop the
-- camera rather than leave it panning until the next click lands cleanly.
mp.observe_property("mouse-pos", "native", function(_, pos)
  if pressed_dir and dir_at(pos and pos.x, pos and pos.y) ~= pressed_dir then
    stop_ptz()
  end
end)

mp.observe_property("osd-dimensions", "native", function()
  layout()
  redraw()
end)

-- Never leave the camera mid-pan if the window closes while a button is
-- still held.
mp.register_event("shutdown", stop_ptz)

layout()
redraw()

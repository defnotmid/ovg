-- Left: the word MASK as a luminance mask over a pattern and a focal
-- radial gradient. Right: a star clip path spinning over a reflected focal
-- gradient whose focus orbits.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local prog, snap, soft, pulse = beat.prog, beat.snap, beat.soft, beat.pulse

local STAR = {}
for i = 0, 9 do
  local r = i % 2 == 0 and 300 or 130
  local a = math.pi * i / 5 - math.pi / 2
  STAR[#STAR + 1] = { math.cos(a) * r, math.sin(a) * r }
end

local function star_d(rot, cx, cy)
  local c, s = math.cos(math.rad(rot)), math.sin(math.rad(rot))
  local parts = {}
  for i, p in ipairs(STAR) do
    parts[#parts + 1] = string.format("%s%.2f %.2f", i == 1 and "M" or "L", cx + p[1] * c - p[2] * s, cy + p[1] * s + p[2] * c)
  end
  return table.concat(parts, " ") .. " Z"
end

local function render(f, lb)
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.BG }
  local kick = pulse(lb, 6)

  -- left: MASK
  local s = snap(lb)
  group({ transform = { translate = { 0, (1 - s) * 200 } },
    mask = function()
      text { "MASK", x = 500, y = 640, align = "center", font = ui.DISPLAY, size = 380 + 20 * kick, fill = "#ffffff" }
    end }, function()
    rect { x = 80, y = 260, w = 840, h = 480, fill = radial_gradient { cx = 500, cy = 500, r = 420,
      fx = 500 + math.cos(lb * 1.3) * 300, fy = 500 + math.sin(lb * 1.3) * 160,
      stops = { { 0, ui.C }, { 0.45, ui.B }, { 1, "#2a0b4d" } } } }
    rect { x = 80, y = 260, w = 840, h = 480, fill = pattern { x = lb * 40, y = 0, w = 36, h = 36, content = function()
      circle { cx = 18, cy = 18, r = 6, fill = "#ffffff", fill_opacity = 0.35 }
    end } }
  end)
  -- under the word, sliding up with it
  group({ transform = { translate = { 0, (1 - s) * 200 } } }, function()
    text { "mask = function() text{…} end", x = 500, y = 800, align = "center", font = ui.MONO, size = 24, fill = ui.DIM }
  end)

  -- right: the star clip path
  local rot = lb * 22 + (1 - soft(lb - 2)) * 90
  local fx = 1420 + math.cos(lb * 1.7) * 220
  local fy = 520 + math.sin(lb * 1.7) * 220
  local in2 = snap(lb - 1)
  group({ opacity = prog(lb, 1, 1.15), clip_path = star_d(rot, 1420, 520), transform = { scale = 0.6 + 0.4 * in2 + 0.04 * kick, origin = { 1420, 520 } } }, function()
    rect { x = 1080, y = 180, w = 680, h = 680, fill = radial_gradient { cx = 1420, cy = 520, r = 140,
      fx = fx, fy = fy, spread = "reflect",
      stops = { { 0, ui.A }, { 0.5, "#1b2a8a" }, { 1, ui.B } } } }
  end)
  group({ opacity = prog(lb, 2, 2.2) }, function()
    text { "clip_path · radial_gradient{ fx, fy, spread = \"reflect\" }", x = 1420, y = 900, align = "center",
      font = ui.MONO, size = 22, fill = ui.DIM }
  end)
  ui.label(lb, 4, "masks · clip paths · focal gradients · patterns")
end

return { name = "Masks", start = T.MASKS, stop = T.TEXT, render = render }

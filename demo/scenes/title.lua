-- Primitives draw themselves on (dashes with path_length) for a bar, then
-- the wordmark slams in: gradient fill, a stacked drop shadow, a glow.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local prog, snap, soft, pulse, expo_out = beat.prog, beat.snap, beat.soft, beat.pulse, beat.expo_out

local STAR = {}
for i = 0, 9 do
  local r = i % 2 == 0 and 120 or 52
  local a = math.pi * i / 5 - math.pi / 2
  STAR[#STAR + 1] = string.format("%s%.1f %.1f", i == 0 and "M" or "L", math.cos(a) * r, math.sin(a) * r)
end
STAR = table.concat(STAR, " ") .. " Z"

local SHAPES = {
  function(s) circle { cx = 0, cy = 0, r = 110, fill = "none", stroke = ui.A, stroke_width = 10, path_length = 1,
    stroke_dasharray = { 1, 1 }, stroke_dashoffset = 1 - s, line_cap = "round" } end,
  function(s) rect { x = -100, y = -100, w = 200, h = 200, rx = 36, fill = "none", stroke = ui.B, stroke_width = 10,
    path_length = 1, stroke_dasharray = { 1, 1 }, stroke_dashoffset = 1 - s, line_cap = "round" } end,
  function(s) path { d = STAR, fill = "none", stroke = ui.C, stroke_width = 10, path_length = 1,
    stroke_dasharray = { 1, 1 }, stroke_dashoffset = 1 - s, line_cap = "round", line_join = "round" } end,
}

local WORD = { "OVG", font = ui.DISPLAY, size = 400 }
local WORD_W = text_width(WORD)

local function render(f, lb)
  local slam = T.TITLE_SLAM
  -- a focal radial glow whose focus circles the frame
  local a = lb * 0.6
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = radial_gradient { cx = 960, cy = 540, r = 900,
    fx = 960 + math.cos(a) * 380, fy = 540 + math.sin(a) * 220,
    stops = { { 0, "#1b1f5c" }, { 0.5, "#0b0d2a" }, { 1, ui.BG } } } }

  if lb < slam + 0.5 then
    local out = expo_out(prog(lb, slam - 0.25, slam + 0.5))
    for i, draw in ipairs(SHAPES) do
      local s = expo_out(prog(lb, i - 1, i + 0.5))
      local x = 960 + (i - 2) * 420
      group({ opacity = 1 - out, transform = { translate = { x, 520 }, rotate = (1 - s) * -90 + out * 180,
        scale = 1 - out * 0.6 } }, function() draw(s) end)
    end
  end

  if lb >= slam then
    local s = 1 + 0.35 * (1 - soft(lb - slam)) + 0.02 * pulse(lb, 8)
    group({ transform = { scale = s, origin = { 960, 470 } },
      filter = {
        { "drop_shadow", dx = 0, dy = 18, std = 14, color = "#000000", opacity = 0.7, result = "d" },
        { "blur", std = 26, input = "SourceGraphic", result = "g" },
        { "color_matrix", type = "hueRotate", values = lb * 40, input = "g", result = "h" },
        { "merge", "h", "d" },
      } }, function()
      text { WORD[1], x = 960, y = 610, align = "center", font = WORD.font, size = WORD.size,
        fill = linear_gradient { x1 = 960 - WORD_W / 2, y1 = 0, x2 = 960 + WORD_W / 2, y2 = 0,
          spread = "reflect", transform = translate(math.sin(lb * 0.8) * 300, 0),
          stops = { { 0, ui.A }, { 0.5, ui.B }, { 1, ui.C } } } }
    end)
    local p = snap(lb - slam - 1)
    group({ opacity = prog(lb, slam + 1, slam + 1.2), transform = translate(0, (1 - p) * 30) }, function()
      text { "the 2D vector canvas onimite draws with", x = 960, y = 720, align = "center",
        font = ui.SANS, size = 46, fill = ui.TEXT }
    end)
    if lb >= slam + 2 then
      local label = "Odin · femtovg lineage · software + SDL_GPU (Vulkan / Metal / D3D12)"
      local w = text_width { label, font = ui.MONO, size = 22 } + 31
      ui.chip(960 - w / 2, 790, label, ui.LINE, ui.A, 22, snap(lb - slam - 2))
    end
  end
end

return { name = "Title", start = T.TITLE, stop = T.SVG, render = render }

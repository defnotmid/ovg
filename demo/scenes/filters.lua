-- Bar 1: three cards, each a group with a filter list (blur; drop shadow;
-- blur + hue rotate + drop shadow stacked). Bar 2: three discs composited
-- with a blend mode that changes on every beat.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local facts = require("facts")
local prog, snap, soft, pulse = beat.prog, beat.snap, beat.soft, beat.pulse

local MODES = { "screen", "difference", "hard-light", "exclusion" }

local function blob(lb)
  -- a rounded star: the thing each card filters
  local pts = {}
  for i = 0, 11 do
    local r = i % 2 == 0 and 130 or 80
    local a = math.pi * i / 6 + lb * 0.4
    pts[#pts + 1] = { math.cos(a) * r, math.sin(a) * r }
  end
  polygon { points = pts, fill = linear_gradient { x1 = -130, y1 = -130, x2 = 130, y2 = 130,
    stops = { { 0, ui.A }, { 1, ui.B } } }, stroke = ui.TEXT, stroke_width = 6, line_join = "round" }
end

local function cards(lb)
  local CARDS = {
    { "blur", { { "blur", std = 2 + 10 * (0.5 + 0.5 * math.sin(lb * math.pi)) } } },
    { "drop shadow", { { "drop_shadow", dx = math.cos(lb * 1.6) * 30, dy = 30, std = 12, color = "#000000",
      opacity = 0.85 } } },
    { "blur → hue rotate → shadow", {
      { "blur", std = 3, result = "b" },
      { "color_matrix", type = "hueRotate", values = lb * 90, input = "b", result = "c" },
      { "drop_shadow", dx = 0, dy = 24, std = 14, color = ui.A, opacity = 0.9, input = "c" } } },
  }
  for i, c in ipairs(CARDS) do
    local at = i - 1
    if lb >= at then
      local s = snap(lb - at)
      local x = 360 + (i - 1) * 600
      group({ transform = { translate = { x, 540 + (1 - s) * 200 } } }, function()
        rect { x = -250, y = -250, w = 500, h = 560, rx = 28, fill = ui.PANEL, stroke = ui.LINE, stroke_width = 2 }
        group({ filter = c[2] }, function() blob(lb) end)
        text { c[1], x = 0, y = 270, align = "center", font = ui.MONO, size = 26, fill = ui.TEXT }
      end)
    end
  end
end

local function blends(lb)
  local k = math.min(math.floor(lb - T.BLEND) + 1, #MODES)
  local mode = MODES[k]
  -- a striped backdrop so the modes have something to mix with
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = pattern { x = 0, y = 0, w = 80, h = 80,
    transform = rotate(30), content = function()
      rect { x = 0, y = 0, w = 80, h = 80, fill = "#141938" }
      rect { x = 0, y = 0, w = 40, h = 80, fill = "#2c3470" }
    end } }
  local kick = 1 + 0.06 * pulse(lb, 7)
  local spin = lb * 25
  for i, col in ipairs({ ui.A, ui.B, ui.C }) do
    local a = math.rad(spin + i * 120)
    group({ blend = mode }, function()
      circle { cx = 960 + math.cos(a) * 140 * kick, cy = 520 + math.sin(a) * 140 * kick, r = 250, fill = col }
    end)
  end
  local p = snap(lb - T.BLEND - (k - 1))
  group({ transform = { scale = 1 + 0.2 * (1 - p), origin = { 960, 930 } } }, function()
    text { "blend = \"" .. mode .. "\"", x = 960, y = 950, align = "center", font = ui.MONO, size = 48, fill = ui.TEXT }
  end)
  text { string.format("one of %d CSS blend modes · ovg README", facts.BLEND_MODES), x = 960, y = 1000,
    align = "center", font = ui.MONO, size = 20, fill = ui.DIM }
end

local function render(f, lb)
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.BG }
  if lb < T.BLEND then
    cards(lb)
    ui.label(lb, 2, "SVG filter primitives · stacked")
  else
    blends(lb)
    ui.label(lb - T.BLEND, 3, "blend modes")
  end
end

return { name = "Filters", start = T.FILTERS, stop = T.MASKS, render = render }

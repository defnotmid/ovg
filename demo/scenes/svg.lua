-- rocket.svg (drawn for this demo) imported with svg{} and animated by
-- element id: the flame, the window, the fins and the stars switch on one
-- a beat. The document's own gradients, pattern, clip path and filters
-- render through ovg's SVG importer.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local facts = require("facts")
local prog, snap, pulse = beat.prog, beat.snap, beat.pulse

local IDS = {
  { "#flame", "transform: scale" },
  { "#window_glass", "fill" },
  { "#fin_l  #fin_r", "transform: rotate" },
  { "#star1..3", "opacity" },
}

local function render(f, lb)
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = 1080,
    stops = { { 0, "#0b1033" }, { 1, ui.BG } } } }
  local on = function(k) return lb >= T.SVG_POPS[k] end
  local flick = on(1) and (1 + 0.25 * math.sin(lb * 21) + 0.35 * pulse(lb, 6)) or 0.3
  local wiggle = on(3) and math.sin(lb * math.pi) * 12 or 0
  local windows = { ui.A, ui.B, ui.C, "#7cff6b" }
  local enter = snap(lb)
  svg(f, { src = "rocket.svg", x = 180, y = 120 + (1 - enter) * 600, w = 840, h = 840,
    overrides = {
      rocket = { transform = { translate = { 0, math.sin(lb * math.pi / 2) * 10 }, rotate = math.sin(lb * 0.9) * 4,
        origin = { 200, 200 } } },
      flame = { transform = scale(1, flick, 200, 262) },
      flame_core = { opacity = on(1) and 1 or 0.4 },
      window_glass = on(2) and { fill = windows[math.floor(lb) % 4 + 1] } or {},
      fin_l = { transform = rotate(wiggle, 150, 200) },
      fin_r = { transform = rotate(-wiggle, 250, 200) },
      star1 = { opacity = on(4) and 0.3 + 0.7 * pulse(lb, 3) or 0 },
      star2 = { opacity = on(4) and 0.3 + 0.7 * pulse(lb + 0.33, 3) or 0 },
      star3 = { opacity = on(4) and 0.3 + 0.7 * pulse(lb + 0.66, 3) or 0 },
    } })

  text { "svg{ src = \"rocket.svg\", overrides = { … } }", x = 1080, y = 330, font = ui.MONO, size = 26, fill = ui.DIM }
  for k, row in ipairs(IDS) do
    local at = T.SVG_POPS[k]
    if lb >= at then
      local p = snap(lb - at)
      local y = 410 + (k - 1) * 96
      group({ opacity = prog(lb, at, at + 0.15), transform = translate((1 - p) * 60, 0) }, function()
        text { row[1], x = 1080, y = y, font = ui.MONO, size = 40, fill = ui.A }
        text { row[2], x = 1080, y = y + 36, font = ui.MONO, size = 22, fill = ui.TEXT }
      end)
    end
  end
  ui.label(lb, 1, "svg{} · animated by element id")
  ui.fact(lb, 6, string.format("resvg test suite: %s curated · %s of %d files", facts.SVG_CURATED, facts.SVG_FULL,
    facts.SVG_FULL_FILES), "ovg README · tools/svg_suite")
end

return { name = "SVG", start = T.SVG, stop = T.FILTERS, render = render }

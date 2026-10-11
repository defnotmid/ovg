-- One scene in two halves, labelled with the two backends, and the parity
-- ovg measures between them. Both halves of this video come from one
-- render; the numbers are tools/sdlgpu_parity's (facts.lua).

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local facts = require("facts")
local prog, snap, soft, pulse, expo_out = beat.prog, beat.snap, beat.soft, beat.pulse, beat.expo_out

local function scene(lb)
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = linear_gradient { x1 = 0, y1 = 0, x2 = 1920, y2 = 1080,
    stops = { { 0, "#101640" }, { 1, "#2a0b3d" } } } }
  for i = 0, 5 do
    local a = lb * 0.7 + i * math.pi / 3
    circle { cx = 960 + math.cos(a) * 320, cy = 470 + math.sin(a) * 220, r = 70 + 20 * pulse(lb + i / 6, 5),
      fill = radial_gradient { cx = 0.35, cy = 0.35, r = 0.7, units = "bbox",
        stops = { { 0, "#ffffff" }, { 0.3, i % 2 == 0 and ui.A or ui.B }, { 1, "#120a30" } } } }
  end
  path { d = "M560 470 C 760 220, 1160 720, 1360 470", fill = "none", stroke = ui.C, stroke_width = 14,
    line_cap = "round", stroke_dasharray = { 40, 26 }, stroke_dashoffset = -lb * 66 }
  text { "same scene", x = 960, y = 490, align = "center", font = ui.DISPLAY, size = 120, fill = ui.TEXT }
end

local function render(f, lb)
  scene(lb)
  local split = expo_out(prog(lb, 0, 0.6))
  -- the divider and the two labels
  if split > 0 then
    rect { x = 958, y = 540 - 540 * split, w = 4, h = 1080 * split, fill = ui.TEXT,
      opacity = 1 - 0.85 * prog(lb, T.PARITY_POPS[1], T.PARITY_POPS[1] + 0.5) }
  end
  local l = snap(lb - 0.5)
  group({ opacity = prog(lb, 0.5, 0.7) }, function()
    ui.chip(960 - 40 - (1 - l) * 40 - text_width { "SDL_GPU · Vulkan", font = ui.MONO, size = 30 } - 42, 150,
      "SDL_GPU · Vulkan", ui.A, ui.BG, 30)
    ui.chip(1000 + (1 - l) * 40, 150, "software rasterizer", ui.B, ui.BG, 30)
  end)
  if lb >= T.PARITY_POPS[1] then
    local p = snap(lb - T.PARITY_POPS[1])
    group({ transform = { scale = 0.6 + 0.4 * p, origin = { 960, 780 } } }, function()
      rect { x = 460, y = 680, w = 1000, h = 190, rx = 30, fill = ui.BG, fill_opacity = 0.85 }
      text { "GPU = software " .. facts.PARITY, x = 960, y = 800, align = "center", font = ui.DISPLAY, size = 110,
        fill = ui.TEXT }
    end)
  end
  if lb >= T.PARITY_POPS[2] then
    group({ opacity = prog(lb, T.PARITY_POPS[2], T.PARITY_POPS[2] + 0.2) }, function()
      text { "parity checks match · mean difference under 0.1 / 255 · " .. facts.PARITY_GPU, x = 960, y = 920, align = "center",
        font = ui.SANS, size = 34, fill = ui.TEXT }
      text { "ovg README · tools/sdlgpu_parity · the software backend is the GPU's pixel reference", x = 960,
        y = 964, align = "center", font = ui.MONO, size = 20, fill = ui.DIM }
    end)
  end
  ui.label(lb, 6, "two backends, one picture")
end

return { name = "Parity", start = T.PARITY, stop = T.OUTRO, render = render }

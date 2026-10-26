-- Shaped text: ligatures in Instrument Serif marked as they form, then an
-- Arabic line joining as it wipes in right to left (Noto Sans Arabic).

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local facts = require("facts")
local prog, snap, soft, expo_out = beat.prog, beat.snap, beat.soft, beat.expo_out

-- Ligatures: where "ffi" and "fl" sit in the shaped line, measured at load.
local LIGA = { text = "the official flow", size = 190 }
local function width(s) return text_width { s, font = ui.SERIF, size = LIGA.size, italic = true } end
LIGA.x = 960 - width(LIGA.text) / 2
LIGA.marks = {
  { "ffi", LIGA.x + width("the o"), width("the offi") - width("the o"), 1 },
  { "fl", LIGA.x + width("the official "), width("the official fl") - width("the official "), 2 },
}

local WORD = "مرحبا بالعالم" -- "hello, world"
local WORD_W = text_width { WORD, font = ui.ARABIC, size = 170 }

local function render(f, lb)
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.BG }
  local s = 1 + 0.1 * (1 - soft(lb))
  group({ opacity = prog(lb, 0, 0.15), transform = { scale = s, origin = { 960, 380 } } }, function()
    text { LIGA.text, x = LIGA.x, y = 420, font = ui.SERIF, size = LIGA.size, italic = true, fill = ui.TEXT }
  end)
  for _, m in ipairs(LIGA.marks) do
    local p = expo_out(prog(lb, m[4], m[4] + 0.5))
    if p > 0 then
      rect { x = m[2], y = 455, w = m[3] * p, h = 8, rx = 4, fill = ui.A }
      group({ opacity = p }, function()
        text { m[1], x = m[2] + m[3] / 2, y = 505, align = "center", font = ui.MONO, size = 28, fill = ui.A }
      end)
    end
  end

  -- the joined line wipes in right to left, the way it reads
  local p = expo_out(prog(lb, T.ARABIC, T.ARABIC + 1))
  local x1 = 960 + WORD_W / 2 + 40
  group({ clip = { x = x1 - (WORD_W + 80) * p, y = 560, w = (WORD_W + 80) * p + 1, h = 320 } }, function()
    text { WORD, x = 960, y = 790, align = "center", font = ui.ARABIC, size = 170, fill = ui.B }
  end)
  group({ opacity = prog(lb, T.ARABIC + 1, T.ARABIC + 1.3) }, function()
    text { "Arabic joining, right-to-left runs · oglyph", x = 960, y = 888, align = "center",
      font = ui.MONO, size = 24, fill = ui.DIM }
  end)
  ui.label(lb, 5, "shaped text · ligatures · Arabic")
  ui.fact(lb, 6, string.format("a variable font at a new weight: %s, from %s", facts.TEXT_WEIGHT,
    facts.TEXT_WEIGHT_BEFORE), "ovg README · Text layout")
end

return { name = "Text", start = T.TEXT, stop = T.PARITY, render = render }

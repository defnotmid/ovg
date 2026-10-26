-- The soundtrack: an odawg song after Steve Reich's Music for 18 Musicians
-- (1976). Why: ovg draws exact shapes, and Reich's music is built of exact
-- ones: an even pulse on mallets and pianos, interlocking patterns that
-- fill in note by note, and chords that change at the end of a breath. Its
-- decisions, followed: no drums (the pulse is the beat: sixteenths at
-- 104 BPM, the reference's quick even pulse); two marimbas in canon, a
-- three-note cell against the bar, the second a sixteenth behind,
-- filling their rests in each scene's second bar; pianos pulsing the chord
-- in eighths and swelling like a breath; clarinets, violins and cellos
-- swelling and fading on each chord, one chord a scene; the calls that cue
-- a change on a xylophone and a tubular bell. E major, the chords walking
-- down from the tonic and back: E C#m A B G#m F#m B E. The picture answers
-- the notes (timeline.lua, video.lua): the glockenspiel's notes are its
-- pops, the xylophone's ratchets its stutters, the timpani its impacts and
-- the piano's bass on the beats its pulse.
--
-- Instruments: VS Chamber Orchestra 2's own SFZ files (CC0), fetched from
-- its repository at a pinned commit and checked against media/pins/vsco.pins
-- (`onimite audio pin demo/video.lua`), and odawg's Yamaha upright piano set
-- (VCSL, CC0). Levels by measurement: each part in its role's band of LU
-- under the mix (`onimite audio parts demo/video.lua`).

local VSCO = {
  url = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/6dd651d55dde97fd4028699be9d4481f26917891/",
  page = "https://github.com/sgossner/VSCO-2-CE/tree/SFZ",
  licence = "CC0-1.0",
  credit = "VS Chamber Orchestra 2: Community Edition by Versilian Studios LLC (Sam Gossner, Simon Dalzell, Elan Hickler), CC0 1.0",
  pins = "pins/vsco.pins",
}

local function at(bar, quarter, sixteenth) return string.format("%d:%d:%d", bar, quarter, sixteenth) end

-- A bar of sixteenths: the cell `a . b` from step `shift`, three against
-- the bar's four beats.
local function cell(a, b, shift)
  local out = {}
  for i = 0, 15 do
    local k = (i + shift) % 3
    out[#out + 1] = k == 0 and a or (k == 2 and b or ".")
  end
  return table.concat(out, " ")
end

-- `chord`'s notes in eighths over `bars` bars, swelling from `lo` to `hi`
-- and back like a breath, the beats a little stronger.
local function breath(chord, bars, lo, hi)
  local ev, n = {}, bars * 8
  for i = 0, n - 1 do
    local v = lo + (hi - lo) * math.sin(math.pi * (i + 0.5) / n) + (i % 2 == 0 and 0.05 or 0)
    for _, note in ipairs(chord) do
      ev[#ev + 1] = { time = at(i // 8, (i // 2) % 4, (i % 2) * 2), note = note, duration = "8n", velocity = v }
    end
  end
  return ev
end

-- The bass, `notes` (an octave) on the beats, the bar's first the
-- strongest.
local function beats(notes, bars, v)
  local ev = {}
  for i = 0, bars * 4 - 1 do
    local accent = i % 4 == 0 and 0.12 or (i % 2 == 0 and 0.04 or 0)
    for _, note in ipairs(notes) do
      ev[#ev + 1] = { time = at(i // 4, i % 4, 0), note = note, duration = "8n", velocity = v + accent }
    end
  end
  return ev
end

-- A ratchet: a note repeated in 32nds over a beat, dying away.
local function ratchet(note)
  local ev = {}
  for i = 0, 7 do
    ev[#ev + 1] = { time = i * 60 / 104 / 8, note = note, duration = "32n", velocity = 0.9 - 0.075 * i }
  end
  return ev
end

-- A breath on a held part's gain lane (relative to the part's gain_db,
-- odawg v0.0.31 on): up from `depth` dB under to its level through each
-- section's first bar, back down by its end.
local function swells(sections, depth)
  local pts = {}
  for _, s in ipairs(sections) do
    pts[#pts + 1] = { s[1], -depth }
    pts[#pts + 1] = { s[1] .. "@1m", 0 }
    pts[#pts + 1] = { s[2] .. "@-8n", -depth }
  end
  return pts
end

return song { "score", key = "E major", bpm = 104, seed = 18, gain_db = -12,
  sources = { vsco = VSCO },
  sections = {
    { "title", duration = "1m", chords = "Esus2" },
    { "slam", duration = "1m", chords = "C#m9" },
    { "svg", duration = "2m", chords = "Amaj9" },
    { "filters", duration = "2m", chords = "B11" },
    { "masks", duration = "2m", chords = "G#m7" },
    { "text", duration = "2m", chords = "F#m11" },
    { "parity", duration = "2m", chords = "Bsus4 B" },
    { "outro", duration = "2m", chords = "Emaj9" },
    { "tail", duration = "1m", chords = "Emaj9" },
  },
  returns = {
    hall = { { "Reverb", decay = 2.4, pre_delay = 0.025 }, { "Filter", type = "highpass", frequency = 250 } },
  },
  parts = {
    -- The pulse: the first marimba alone in the title, the second joining
    -- on the slam a sixteenth behind; the rests filled in each second bar.
    marimba = { role = "melody", instrument = "vsco/Marimba.sfz", gain_db = 16.2, pan = -0.35, sends = { hall = -14 },
      play = {
        { "title", notes = cell("E5", "B4", 0), subdivision = "16n", velocity = 0.42, humanize = 0.005 },
        { "slam", notes = cell("E5", "G#4", 0), subdivision = "16n", velocity = 0.5, humanize = 0.005 },
        { "svg", notes = cell("E5", "A4", 0), subdivision = "16n", velocity = 0.56, humanize = 0.005, vary = { {}, { fill = true } } },
        { "filters", notes = cell("F#5", "C#5", 0), subdivision = "16n", velocity = 0.58, humanize = 0.005, vary = { {}, { fill = true } } },
        { "masks", notes = cell("D#5", "G#4", 0), subdivision = "16n", velocity = 0.58, humanize = 0.005, vary = { {}, { fill = true } } },
        { "text", notes = cell("C#5", "A4", 0), subdivision = "16n", velocity = 0.4, humanize = 0.006 },
        { "parity..parity@1m", notes = cell("E5", "B4", 0), subdivision = "16n", velocity = 0.62, humanize = 0.005 },
        { "parity@1m..", notes = cell("D#5", "F#4", 0), subdivision = "16n", velocity = 0.66, humanize = 0.005, vary = { { fill = true } } },
        { "outro", notes = cell("G#5", "D#5", 0), subdivision = "16n", velocity = 0.66, humanize = 0.005, vary = { {}, { fill = true } } },
        { "tail", events = { { time = 0, note = "E5", duration = "1m", velocity = 0.5 } } },
      } },
    marimba2 = { role = "counter", instrument = "vsco/Marimba.sfz", gain_db = 19.5, pan = 0.35, sends = { hall = -14 },
      play = {
        { "slam", notes = cell("D#5", "B4", 2), subdivision = "16n", velocity = 0.46, humanize = 0.005 },
        { "svg", notes = cell("G#5", "C#5", 2), subdivision = "16n", velocity = 0.52, humanize = 0.005, vary = { {}, { fill = true } } },
        { "filters", notes = cell("E5", "A4", 2), subdivision = "16n", velocity = 0.54, humanize = 0.005, vary = { {}, { fill = true } } },
        { "masks", notes = cell("F#5", "B4", 2), subdivision = "16n", velocity = 0.54, humanize = 0.005, vary = { {}, { fill = true } } },
        { "text", notes = cell("E5", "B4", 2), subdivision = "16n", velocity = 0.36, humanize = 0.006 },
        { "parity..parity@1m", notes = cell("F#5", "E5", 2), subdivision = "16n", velocity = 0.58, humanize = 0.005 },
        { "parity@1m..", notes = cell("F#5", "B4", 2), subdivision = "16n", velocity = 0.62, humanize = 0.005, vary = { { fill = true } } },
        { "outro", notes = cell("B5", "F#5", 2), subdivision = "16n", velocity = 0.62, humanize = 0.005, vary = { {}, { fill = true } } },
      } },
    -- The pianos: the chord in eighths, a breath a scene.
    piano = { role = "comp", instrument = { "Sampler", set = "vcsl/upright_piano", release = 0.5 }, gain_db = -3, sends = { hall = -16 },
      play = {
        { "title", events = breath({ "E4", "F#4", "B4" }, 1, 0.22, 0.42), humanize = 0.004 },
        { "slam", events = breath({ "E4", "G#4", "B4", "D#5" }, 1, 0.3, 0.5), humanize = 0.004 },
        { "svg", events = breath({ "E4", "G#4", "B4", "C#5" }, 2, 0.3, 0.55), humanize = 0.004 },
        { "filters", events = breath({ "E4", "A4", "C#5", "F#5" }, 2, 0.3, 0.55), humanize = 0.004 },
        { "masks", events = breath({ "D#4", "F#4", "B4", "D#5" }, 2, 0.3, 0.55), humanize = 0.004 },
        { "text", events = breath({ "E4", "A4", "B4", "C#5" }, 2, 0.18, 0.36), humanize = 0.005 },
        { "parity..parity@1m", events = breath({ "E4", "F#4", "B4" }, 1, 0.38, 0.6), humanize = 0.004 },
        { "parity@1m..", events = breath({ "D#4", "F#4", "B4" }, 1, 0.42, 0.66), humanize = 0.004 },
        { "outro", events = breath({ "D#4", "F#4", "G#4", "B4" }, 2, 0.38, 0.66), humanize = 0.004 },
        { "tail", events = { { time = 0, note = "E3", duration = "1m", velocity = 0.42 }, { time = 0, note = "B3", duration = "1m", velocity = 0.4 },
          { time = 0, note = "D#4", duration = "1m", velocity = 0.38 }, { time = 0, note = "G#4", duration = "1m", velocity = 0.38 } } },
      } },
    -- The pianos' left hand: the root in octaves on the beats (the
    -- picture's pulse), resting under the text.
    bass = { role = "bass", instrument = { "Sampler", set = "vcsl/upright_piano", release = 0.4 }, gain_db = 6.2, sends = { hall = -20 },
      play = {
        { "title", events = beats({ "E2", "E3" }, 1, 0.4) },
        { "slam", events = beats({ "C#2", "C#3" }, 1, 0.48) },
        { "svg", events = beats({ "A1", "A2" }, 2, 0.5) },
        { "filters", events = beats({ "B1", "B2" }, 2, 0.5) },
        { "masks", events = beats({ "G#1", "G#2" }, 2, 0.5) },
        { "parity", events = beats({ "B1", "B2" }, 2, 0.56) },
        { "outro", events = beats({ "E2", "E3" }, 2, 0.58) },
      } },
    -- Held chord tones, swelling with each chord (the lanes below).
    clarinets = { role = "pad", instrument = { "vsco/ClarinetSus.sfz", ampeg_attack = 0.15, ampeg_release = 0.8 }, gain_db = 4, pan = -0.15,
      sends = { hall = -10 },
      play = {
        { "svg", notes = { { "C#5", "B5" } }, subdivision = "2m", velocity = 0.55 },
        { "filters", notes = { { "C#5", "E5" } }, subdivision = "2m", velocity = 0.55 },
        { "masks", notes = { { "B4", "D#5" } }, subdivision = "2m", velocity = 0.55 },
        { "text", notes = { { "A4", "B4" } }, subdivision = "2m", velocity = 0.45 },
        { "parity..parity@1m", notes = { { "B4", "E5" } }, subdivision = "1m", velocity = 0.6 },
        { "parity@1m..", notes = { { "B4", "D#5" } }, subdivision = "1m", velocity = 0.6 },
        { "outro", notes = { { "G#4", "D#5", "F#5" } }, subdivision = "2m", velocity = 0.62 },
      } },
    violins = { role = "pad", instrument = { "vsco/ViolinEnsSusVib.sfz", ampeg_attack = 0.35, ampeg_release = 1.2 }, gain_db = 11.5, pan = 0.25,
      sends = { hall = -9 },
      play = {
        { "svg", notes = { { "G#5", "C#6" } }, subdivision = "2m", velocity = 0.5 },
        { "filters", notes = { { "F#5", "C#6" } }, subdivision = "2m", velocity = 0.5 },
        { "masks", notes = { { "F#5", "B5" } }, subdivision = "2m", velocity = 0.5 },
        { "parity", notes = { { "F#5", "B5" } }, subdivision = "2m", velocity = 0.7 },
        { "outro", notes = { { "G#5", "B5" } }, subdivision = "2m", velocity = 0.7 },
      } },
    cellos = { role = "pad", instrument = { "vsco/CelloEnsSusVib.sfz", ampeg_attack = 0.3, ampeg_release = 1.2 }, gain_db = 4, pan = -0.1,
      sends = { hall = -12 },
      play = {
        { "svg", notes = "A2", subdivision = "2m", velocity = 0.55 },
        { "filters", notes = "B2", subdivision = "2m", velocity = 0.55 },
        { "masks", notes = "G#2", subdivision = "2m", velocity = 0.55 },
        { "text", notes = "F#2", subdivision = "2m", velocity = 0.45 },
        { "parity", notes = "B2", subdivision = "2m", velocity = 0.7 },
        { "outro", notes = "E2", subdivision = "2m", velocity = 0.7 },
        { "tail", notes = "E2", subdivision = "1m", velocity = 0.5 },
      } },
    -- The pops (timeline.lua reads them): the rocket's parts one a beat,
    -- the blend modes one a beat, the parity's two numbers.
    blips = { role = "fx", instrument = "vsco/Glockenspiel.sfz", gain_db = 23, pan = 0.1, sends = { hall = -8 }, octave = 5,
      play = {
        { "svg", degrees = ". . 1 3 5 8 . .", subdivision = "4n", velocity = 0.62, humanize = 0.003 },
        { "filters@1m..", degrees = "1 2 3 5", subdivision = "4n", velocity = 0.6, humanize = 0.003 },
        { "parity", degrees = ". . . . . . . . 1 5 . . . . . . | 1 5 . . . . . . . . . . . . . .", subdivision = "16n", velocity = 0.66 },
      } },
    -- The stutters (timeline.lua reads the text's): a xylophone's ratchet
    -- on the title's first beat, the masks' cut and the Arabic line.
    glitch = { role = "fx", instrument = "vsco/Xylophone.sfz", gain_db = 3, pan = 0.2, sends = { hall = -12 },
      play = {
        { "title", events = ratchet("E6") },
        { "masks", events = ratchet("D#6") },
        { "text@1m", events = ratchet("C#6") },
      } },
    -- A call on the SVG's, the text's and the wordmark's downbeats.
    bells = { role = "fx", instrument = "vsco/TubularBells.sfz", gain_db = 11.5, sends = { hall = -6 },
      play = {
        { "svg", events = { { time = 0, note = "E5", duration = "1m", velocity = 0.6 } } },
        { "text", events = { { time = 0, note = "C#5", duration = "1m", velocity = 0.5 } } },
        { "outro@1m", events = { { time = 0, note = "E5", duration = "1m", velocity = 0.7 } } },
      } },
    -- The impacts (the picture flashes on them): the slam and the outro.
    fx = { role = "fx", instrument = "vsco/Timpani.sfz", gain_db = 15, sends = { hall = -12 },
      play = {
        { "slam", events = { { time = 0, note = "C#2", duration = "2n", velocity = 0.95 } } },
        { "outro", events = { { time = 0, note = "E2", duration = "2n", velocity = 0.9 } } },
      } },
    -- A timpani roll swelling into the parity (its lane below).
    roll = { role = "fx", instrument = "vsco/TimpaniRolls.sfz", gain_db = 13, sends = { hall = -12 },
      play = { { "text@1m", events = { { time = 0, note = "F#2", duration = "1m", velocity = 0.8 } } } } },
  },
  automation = {
    ["parts/clarinets/gain_db"] = swells({ { "svg", "filters" }, { "filters", "masks" }, { "masks", "text" }, { "text", "parity" },
      { "parity", "outro" }, { "outro", "tail" } }, 12),
    ["parts/violins/gain_db"] = swells({ { "svg", "filters" }, { "filters", "masks" }, { "masks", "text" }, { "parity", "outro" },
      { "outro", "tail" } }, 10),
    ["parts/roll/gain_db"] = { { "text@1m", -26 }, { "parity@-16n", 0 } },
    -- The piano up 2 dB in the quiet title and text, where it breathes
    -- softest, and 3 for its closing chord in the tail.
    ["parts/piano/gain_db"] = { { "title", 2 }, { "slam", 0, "step" }, { "text", 2, "step" }, { "parity", 0, "step" },
      { "tail", 3, "step" } },
    ["returns/hall/Reverb/wet"] = { { "masks", 0.3 }, { "text", 0.5 }, { "parity", 0.3, "step" }, { "tail", 0.55 } },
  },
}

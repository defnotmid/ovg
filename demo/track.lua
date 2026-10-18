-- The soundtrack: an odawg song, 128 BPM house in D minor (Dm Bb F C, a
-- chord a bar), 15 bars, its sections named after the scenes (the title has
-- two: the intro bar and the slam). The style plays the drums, the
-- off-beat bass ducking under the kick, the stabs, the pad in the quiet
-- parts and the pluck arpeggio at full energy; a breakdown under the text,
-- an ambient tail. The transitions make the risers and the impacts on the
-- slam and the outro; the parts below add what the picture answers to: the
-- SVG's and the parity's pops, the blend modes' beats, the glitch
-- stutters, a crash on each scene's downbeat. timeline.lua reads them back.

local MACHINE = { "DrumMachine", machine = "909" }

return song { "score", key = "D minor", bpm = 128, seed = 128,
  sections = {
    { "title", duration = "1m", style = "house", energy = 0.3, chords = "Dm" },
    { "slam", duration = "1m", energy = 0.5, chords = "Bb", transition = "impact" },
    { "svg", duration = "2m", energy = 0.8, chords = "F C", transition = "none" },
    { "filters", duration = "2m", energy = 0.8, chords = "Dm Bb", transition = "none" },
    { "masks", duration = "2m", energy = 0.8, chords = "F C", transition = "none" },
    { "text", duration = "2m", energy = 0.35, chords = "Dm Bb", transition = "riser" },
    { "parity", duration = "2m", energy = 0.95, chords = "F C", transition = "riser" },
    { "outro", duration = "2m", energy = 1, chords = "Dm Bb", transition = "impact" },
    { "tail", duration = "1m", style = "ambient", energy = 0.3, chords = "Dm", transition = "cut" },
  },
  parts = {
    drums = { gain_db = 1, play = { { "tail", steps = { kick = "X..............." } } } },
    pad = { gain_db = -16 },
    keys = { mute = { "filters" } },                              -- the blend modes groove without the stabs
    arp = { play = { { "filters@1m..", arpeggio = { pattern = "upDown", interval = "16n", octaves = 2 }, velocity = 0.8 },
                     { "text", arpeggio = { pattern = "upDown", interval = "16n", octaves = 2 }, velocity = 0.8 } } },
    -- a crash on the SVG's, the filters', the text's and the parity's
    -- downbeats, on the wordmark and on the last kick
    crash = { instrument = MACHINE, gain_db = -2,
      play = { { "svg..filters", steps = { crash = { "X...............", "" } } },
               { "text..parity", steps = { crash = { "X...............", "" } } },
               { "outro", steps = { crash = { "", "X..............." } } },
               { "tail", steps = { crash = "X..............." } } } },
    -- a stutter on the title's first beat, the masks' cut and the Arabic line
    glitch = { instrument = "glitch", gain_db = -10,
      play = { { "title", steps = "x...............", note = "1", duration = "4n" },
               { "masks", steps = { "x...............", "" }, note = "1", duration = "4n" },
               { "text", steps = { "", "x..............." }, note = "1", duration = "4n" } } },
    -- the pops: the rocket's parts one a beat, the blend modes one a beat,
    -- the parity's two numbers (each a blip and its fifth)
    blips = { instrument = "blip", gain_db = -2, octave = 5,
      play = { { "svg", degrees = ". . 1 3 5 8 . .", subdivision = "4n" },
               { "filters@1m..", degrees = "1 2 3 5", subdivision = "4n" },
               { "parity", degrees = ". . . . . . . . 1 5 . . . . . . | 1 5 . . . . . . . . . . . . . .",
                 subdivision = "16n", octave = 6 } } },
  },
}

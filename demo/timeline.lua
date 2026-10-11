-- Where things happen, in beats from the start of the video (4 beats a
-- bar). The scenes animate from these numbers and track.lua puts its hits
-- on them, so picture and sound share one list.

local T = {}

-- Sections: 2 bars each; the outro has a bar of tail.
T.TITLE, T.SVG, T.FILTERS, T.MASKS, T.TEXT, T.PARITY, T.OUTRO, T.TOTAL = 0, 8, 16, 24, 32, 40, 48, 60
T.END = 56 -- the last hit

T.TITLE_SLAM = 4                -- the wordmark lands
T.SVG_POPS = { 2, 3, 4, 5 }     -- the id overrides switch on, one a beat
T.BLEND = 4                     -- filters: the blend modes, one a beat
T.ARABIC = 4                    -- text: the Arabic line
T.PARITY_POPS = { 2, 4 }        -- parity: the two numbers
T.WORDMARK = 4

return T

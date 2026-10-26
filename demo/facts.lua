-- Every number on screen, with where it comes from (all ../README.md, the
-- ovg README).

local M = {}

-- "The software backend is the pixel reference for the GPU backend":
-- tools/sdlgpu_parity on an RX 9070 XT (Vulkan, RADV), 2026-10-26: 35 / 35
-- checks match, the mean difference under 0.1 / 255 in each (at most
-- 0.066; most within one or two 8-bit steps; a few edge pixels of text
-- effects, SVG and filters differ more).
M.PARITY = "35 / 35"
M.PARITY_GPU = "RX 9070 XT · Vulkan (RADV)"

-- "SVG import": tools/svg_suite, the curated resvg subset all passing, and
-- the pass rate over the full suite's categories for these features.
M.SVG_CURATED = "64 / 64"
M.SVG_FULL = "88.5 %"
M.SVG_FULL_FILES = 1037

-- "Text layout": Adwaita Sans's 14 glyphs at a new weight, laid out with
-- their shapes built, 54 us where it took 357 with its own tables (the
-- file's tables and plans shared by every instance, Font_Files).
M.TEXT_WEIGHT, M.TEXT_WEIGHT_BEFORE = "54 µs", "357 µs"

-- "Filters and paint extras": the 16 W3C blend modes.
M.BLEND_MODES = 16

return M

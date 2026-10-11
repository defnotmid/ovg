-- Every number on screen, with where it comes from (all ../README.md, the
-- ovg README).

local M = {}

-- "The software backend is the pixel reference for the GPU backend":
-- tools/sdlgpu_parity on an RX 9070 XT (Vulkan, RADV), 2026-10-11: 28 / 28
-- checks match, the mean difference under 0.1 / 255 in each (most within
-- one or two 8-bit steps; a few edge pixels of text, emoji and filters
-- differ more).
M.PARITY = "28 / 28"
M.PARITY_GPU = "RX 9070 XT · Vulkan (RADV)"

-- "SVG import": tools/svg_suite, the curated resvg subset all passing, and
-- the pass rate over the full suite's categories for these features.
M.SVG_CURATED = "64 / 64"
M.SVG_FULL = "88.5 %"
M.SVG_FULL_FILES = 1037

-- "Text layout": a 42 character line costs 1.1 us cached, 4.8 us shaped
-- from scratch.
M.TEXT_CACHED, M.TEXT_COLD = "1.1 µs", "4.8 µs"

-- "Filters and paint extras": the 16 W3C blend modes.
M.BLEND_MODES = 16

return M

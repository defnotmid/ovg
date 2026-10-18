# ovg demo

A 28 second showcase of ovg, music included: 1920x1080, 60 fps,
128 BPM. It is an [onimite](https://github.com/defnotmid/onimite) script
(Odin + Lua video framework, which draws every frame with ovg), not part
of ovg's build. The render, `demo.mp4`, is not in the repository: make it
with onimite cloned next to ovg (`git clone
https://github.com/defnotmid/onimite` beside `ovg/`):

```sh
cd ../../onimite
odin build . -collection:deps=.. -o:speed -out:build/onimite_speed
build/onimite_speed render ../ovg/demo/video.lua -o ../ovg/demo/demo.mp4   # re-render
build/onimite_speed preview ../ovg/demo/video.lua                            # play, hot reload on save
```

| bars | scene | what |
| --- | --- | --- |
| 1-2 | Title | a circle, a rounded rect and a star draw themselves on (dashes, `path_length`), then the wordmark slams in: gradient fill, drop shadow + blur + hue rotate stacked in one filter list |
| 3-4 | SVG | `rocket.svg` through `svg{}`, animated by element id (flame scale, window fill, fins, stars) one a beat; the document's own gradients, pattern, clip path and filters |
| 5-6 | Filters | three filter cards (blur; drop shadow; blur → hue rotate → shadow), then three discs whose blend mode changes on every beat |
| 7-8 | Masks | MASK as a luminance mask over a focal radial gradient and a dot pattern; a spinning star clip path over a reflected focal gradient |
| 9-10 | Text | ligatures (Instrument Serif "the official flow", ffi and fl marked) and Arabic joining, right to left (Noto Sans Arabic) |
| 11-12 | Parity | one scene split under "SDL_GPU · Vulkan" and "software rasterizer" labels, with ovg's measured parity |
| 13-15 | Outro | the wordmark over the soundtrack's spectrum, the lineage nanovg → femtovg → ovg |

Both halves of the parity scene come from the one backend that rendered
the video; the parity itself is the number ovg measures with
`tools/sdlgpu_parity`, shown as a fact.

## Facts on screen

Every number is in `facts.lua` with its source:

| on screen | source |
| --- | --- |
| GPU = software 28 / 28: parity checks match, mean difference under 0.1 / 255, RX 9070 XT, Vulkan (RADV) | ovg README, Design: "The software backend is the pixel reference for the GPU backend" (`tools/sdlgpu_parity`, 2026-10-11) |
| resvg test suite: 64 / 64 curated, 88.5 % of 1037 files | ovg README, SVG import (`tools/svg_suite`) |
| a 42-character line: 1.1 µs cached, 4.8 µs shaped from scratch | ovg README, Design: Text layout |
| one of 16 CSS blend modes | ovg README, Filters and paint extras |

## Files

`video.lua` sets up the video, the beat-synced glitch cuts and the HUD;
`scenes/` holds one file per scene; `track.lua` is the soundtrack, an
odawg `song{}` (D minor house, its sections named after the scenes, its
parts the pops and stutters the picture answers to); `timeline.lua` reads
from it on which beat everything happens; `beat.lua` is the clock and
easing on the song's beat.

Mix (`onimite audio analyze`): -14.8 LUFS integrated, -1.5 dBTP true
peak. Render: 1688 frames in 3.9 s wall, 154 MB peak RSS.

## Media

- `rocket.svg`: drawn for this demo (CC0).
- Fonts (OFL), copied from onimite's `examples/why_onimite/media`: Bebas
  Neue, Space Grotesk, JetBrains Mono, Instrument Serif, Noto Sans Arabic
  Bold.
- The soundtrack is composed by odawg from `track.lua`; there are no other media.

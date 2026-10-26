# ovg demo

A 35 second showcase of ovg, music included: 1920x1080, 60 fps,
104 BPM. It is an [onimite](https://github.com/defnotmid/onimite) script
(Odin + Lua video framework, which draws every frame with ovg), not part
of ovg's build. The render, `demo.mp4`, is not in the repository: make it with the
onimite release binary
([releases](https://github.com/defnotmid/onimite/releases); `onimite
update` keeps it current), from ovg's folder:

```sh
onimite render demo/video.lua -o demo/demo.mp4 --qp 22   # the render
onimite preview demo/video.lua                           # play, hot reload on save
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
| GPU = software 35 / 35: parity checks match, mean difference under 0.1 / 255, RX 9070 XT, Vulkan (RADV) | ovg README, Design: "The software backend is the pixel reference for the GPU backend" (`tools/sdlgpu_parity`, 2026-10-26) |
| resvg test suite: 64 / 64 curated, 88.5 % of 1037 files | ovg README, SVG import (`tools/svg_suite`) |
| a variable font at a new weight: 54 µs, from 357 µs | ovg README, Design: Text layout |
| one of 16 CSS blend modes | ovg README, Filters and paint extras |

## Files

`video.lua` sets up the video, the beat-synced glitch cuts and the HUD;
`scenes/` holds one file per scene; `track.lua` is the soundtrack, an
odawg `song{}` after Steve Reich's *Music for 18 Musicians* (E major,
104 BPM, no drums: marimbas in canon on an even sixteenth pulse, pianos
pulsing each chord, clarinets and strings swelling on it, one chord a
scene; its sections named after the scenes, its glockenspiel notes,
xylophone ratchets and timpani the pops, stutters and impacts the picture
answers to, the piano's bass on the beats its pulse); `timeline.lua` reads
from it on which beat everything happens; `beat.lua` is the clock and
easing on the song's beat.

Mix (`onimite audio analyze`, onimite v0.0.59): -14.3 LUFS integrated,
-2.0 dBTP true peak, the scenes from -19.5 LUFS (text) and -18.7 (title)
to -12.3 (outro). Each part sits in its role's band of LU under the mix
(`onimite audio parts`; `inspect` finds no `role_balance`): the marimba 8
to 9 LU under, the second marimba (the canon's counter) 7 to 10, the bass
5 to 8, the piano 7 to 13, the held strings and clarinets 9 to 16 (the
cellos 1.4 in the tail, the last chord, with the piano and one marimba
note).

## Media

- `rocket.svg`: drawn for this demo (CC0).
- Fonts (SIL Open Font License 1.1, `media/OFL.txt` with each one's
  copyright), copied from onimite's `examples/why_onimite/media`: Bebas
  Neue, Space Grotesk, JetBrains Mono, Instrument Serif, Noto Sans Arabic
  Bold.
- The soundtrack is composed by odawg from `track.lua`, on recorded
  instruments fetched when it plays, never kept here: VS Chamber
  Orchestra 2: Community Edition's own SFZ files (marimba, glockenspiel,
  xylophone, tubular bells, timpani, clarinet, violin and cello sections;
  Versilian Studios, CC0 1.0) at a pinned commit, each file checked
  against `media/pins/vsco.pins` (`onimite audio pin demo/video.lua`), and
  odawg's Yamaha upright piano set (VCSL, CC0).

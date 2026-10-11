# Lottie suite

Small Lottie files with reference renders: `name.json` next to
`name_<frame>.png`, each a frame of the composition drawn by
[lottie-web](https://github.com/airbnb/lottie-web) 5.12.2 (SVG renderer)
over white in headless Chromium at the composition's size
(`../make_refs.py lottie.min.js name.json name frame...`).

| file | source | license |
| --- | --- | --- |
| `skottie-*.json` | Skia, `resources/skottie/` ([google/skia](https://github.com/google/skia/tree/main/resources/skottie)) | BSD-3-Clause |
| `ripple.json` | lottie-web, `test/animations/ripple.json` ([airbnb/lottie-web](https://github.com/airbnb/lottie-web/tree/master/test/animations)) | MIT |
| `ovg-*.json` | written for ovg (effects, text layers) | MIT (ovg's) |

What they cover: trim paths (simultaneous and individual), luma mattes, a
matte with a blend mode, the repeater (copy order, start / end opacity),
gradient opacity stops and coincident stops, radial gradients with a
highlight, nested precomps, time remapping played backwards, and parented
layers with masks (ripple), layer effects (fill, tint, tritone, gaussian
blur both ways and horizontal, drop shadow; animated parameters) and text
layers (justification, stroke, tracking, baseline shift, line breaks, box
text wrapping, a document keyframe; character and word animators with
square, ramp, triangle and smooth selectors, offsets in percent and
indices, ease, position, scale, rotation, opacity, fill colour, tracking).

The text files use Bitstream Vera Sans (ovg's bundled `assets/Vera.ttf`,
the fallback ovg draws them with), embedded for lottie-web by
`make_refs.py` with `LW_FONTS="Bitstream Vera Sans=../../../assets/Vera.ttf"`.
Their glyph edges differ from Chromium's rasterizer (hinting, subpixel
placement) and ovg places glyphs by the shaped layout rather than
lottie-web's per-character measuring, so they pass with up to 6% of pixels
off (`TEXT_FRAC` in `main.odin`); compare them by eye with `-dump:`.
`ovg-effects-blur.json`'s drop shadow sets lottie-web's `fs` (filter
size): lottie-web otherwise clips the shadow to the layer's box, which
After Effects doesn't. All caps (`ca`) is left out: lottie-web's SVG
renderer ignores it.

Left out on purpose (the reference is not a ground truth there): luma
inverted mattes (lottie-web's SVG renderer has none), negative eased
progress along a motion path (lottie-web jumps to the end; ovg holds
the start) and skewed strokes (ovg strokes with the transform's average
scale, as nanovg does).

`./run.sh` (or `odin run tools/lottie_suite -o:speed -- -v tools/lottie_suite/tests`)
passes a frame when at most 2% (text files: 6%) of its pixels differ by
more than 32/255.

# Third-party notices

ovg is MIT licensed ([LICENSE](LICENSE)). Every license it carries is a
separate file in [LICENSES/](LICENSES).

| Component | Where | License file |
| --- | --- | --- |
| femtovg | ovg is a port of it (dual MIT OR Apache-2.0, used under MIT) | `LICENSES/femtovg-MIT.txt` |
| nanovg | femtovg's origin: the canvas API, paint and shader design ovg inherits through it | `LICENSES/nanovg-Zlib.txt` |
| HarfBuzz 14.6 | `shape/`: the shapers, lookup application and fallbacks follow its code, and `shape/syllable_data.odin` and the Indic and USE categories in `shape/unicode_data.odin` are generated from its tables | `LICENSES/HarfBuzz-MIT.txt` |
| Unicode Character Database 17.0.0 | `shape/unicode_data.odin`: generated from its data files (`tools/shape_unicode/gen.pl`) | `LICENSES/Unicode-3.0.txt` |
| resvg test suite | `tools/svg_suite/tests` (dual MIT OR Apache-2.0, used under MIT) | `LICENSES/resvg-MIT.txt` |
| Skia skottie resources | `tools/lottie_suite/tests` | `LICENSES/Skia-BSD-3-Clause.txt` |
| lottie-web test animations | `tools/lottie_suite/tests` | `LICENSES/lottie-web-MIT.txt` |
| Bitstream Vera Sans | `assets/Vera.ttf`, `DEFAULT_FONT_DATA`: the tests' font and the fallback face a `Font_Collection` gets when none is passed (linked only when used) | `LICENSES/Bitstream-Vera.txt` |
| demo fonts | `demo/media` (SIL Open Font License 1.1) | `LICENSES/OFL-1.1.txt` |
| Noto Color Emoji (COLRv1 build, v2.057, Copyright 2022 Google Inc.) | `assets/Noto-COLRv1.ttf`, `EMOJI_FONT_DATA`; linked only when used (SIL Open Font License 1.1) | `LICENSES/OFL-1.1.txt` |

ovg is an altered source version of femtovg and nanovg: an Odin port,
substantially changed and extended, and not the original software.

The demo's rocket (`demo/media/rocket.svg`) is CC0, drawn for ovg. The
suite's `tools/lottie_suite/tests/ovg-*.json` (effects and text layers)
were written for ovg and are MIT like it, as are `assets/colr_test.ttf`
(made by `tools/colr_test_font/build.py`) and the mascot (`assets/logo*`,
drawn by `tools/mascot`).

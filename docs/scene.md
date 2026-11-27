# The Scene: ovg's boundary as data (design draft)

Status: reviewed 2026-11-26, after ovg v0.1.11, and revised the same day
after a native CPU renderer prototype was measured and set aside (see
Backends). Nothing here is built yet. Each step in "Staging" lands on its
own, measured, as a release.

## Why

ovg's boundary today is a stateful `Canvas` whose frame (`Frame`, backend.odin)
is flat tables, but tables in the GPU's shape:

- Paints are packed fragment uniforms (`Params`, 14 vec4s from
  `pack_frag_uniforms`), made per canvas state. Reusing one is `Paint_Slot`
  and `paint_gen`, whose invalidation follows the canvas's transform and the
  image store.
- A fill is an ocurves record (pieces since v0.1.9), an instance with a
  transform from shape units, and a command per run of instances that share
  an image, blend and scissor.
- Layers, masks, clips and filters are resolved on the canvas side
  (`Layer_Stack`, layers.odin): offscreen images from a pool, render-target
  switches, filter passes, a group fold. A backend sees only render targets and
  commands.
- The software backend runs that frame as a GPU would: the same GLSL, as
  oksl's JIT fragment programs, over quads of pixels. Since v0.1.5 it bypasses
  the JIT for coverage, solid fills and 1:1 blits, recognising those cases in
  the GPU's shape (`sw_fill_solid`, `sw_match_blit_image`).

The cost, measured by odpdf over the 233 PDFs it draws whole (one pass,
ovg v0.1.9): 23.3 G instructions against hayro's 8.6 G.

| | odpdf on ovg | hayro |
| --- | --- | --- |
| image drawing (decode, resample, sample) | 10.2 G | about 1.1 G |
| paths and glyphs | 8.9 G | 2.1 G |
| parse and interpret | 1.8 G | 1.9 G |

Images are resampled twice: once by odpdf while decoding, then again by ovg,
per device pixel through the JIT. A page of vector paths with no text (the
coat of arms) is 3.4 times slower than hayro. On that page 10.8% of the time is
the heap allocator, growing the band lists one shape at a time. Each glyph sets
up, clears and blends its own coverage.

Per page, most of that is milliseconds: a page of dense text costs ovg 5 to
10 ms of one core, the coat of arms 20 ms. The multiples that a reader of
a PDF would notice are in transparency, which odpdf draws today with one
`Layer_Stack` layer per masked or blending draw, each masked draw rendering
its mask again:
- tile_clamp_bug.pdf (8 masked draws, 4 blending, 5 groups) takes 10.6 G
  instructions against 4.6 G drawn without transparency, and hayro's 1.5 G;
- one masked fill under a one-fill luminosity mask (mask_bc.pdf) adds about
  700 M, about 1,450 per device pixel;
- fireworks.pdf's 64 masked draws share 4 masks and render them 64 times.

Patching that pipeline case by case is what v0.1.5 to v0.1.11 did. The
proposal is to move the boundary instead: hand ovg a scene as data, and let
each backend compile it the way its hardware works.

## Goals

- One description of a frame, the Scene: plain tables, read-only while it
  renders, buildable on any thread, the same whichever backend draws it (as
  v0.1.9 made fills).
- Each backend compiles the Scene for itself. The GPU keeps ocurves grids,
  LOD levels, uniform rows and oksl shaders. The CPU keeps today's software
  backend: its exact coverage, its direct solid fills and 1:1 blits, and the
  same oksl shaders for every other paint.
- Data with the meaning of what it describes: image formats that say what
  they mean, paints as a small tagged union, and borrowed pixel views for
  one-shot frames.
- No flag day. `Canvas` stays, as a builder of Scenes, so the apps on it
  (a video tool, a design tool, UI libraries, the site's demos) and ovg's own
  svg and lottie packages move when they're ready.

Non-goals for now: replacing the GPU backend's shaders; a second CPU
renderer (measured, see Backends); text layout (oglyph and ovg's fonts stay
producers of outlines). Filters, custom programs and motion blur keep
today's code at first (see "What stays").

## The Scene

A Scene is a set of tables and a list of draws that refer to them by index.
Indices are `u32`, ranges are `Range{start, count}`, as in `Frame` today.

```odin
Scene :: struct {
	// Geometry
	transforms: [dynamic]Transform2D,   // draws and glyphs refer to these
	verbs:      [dynamic]Path_Verb,     // move, line, quad, cubic, close
	points:     [dynamic]Vec2,
	paths:      [dynamic]Scene_Path,    // a range of verbs and of points, its bounds
	strokes:    [dynamic]Stroke_Style,  // width, caps, join, miter, dash range
	dashes:     [dynamic]f32,

	// Paint
	paints:     [dynamic]Scene_Paint,   // small tagged union, below
	stops:      [dynamic]Gradient_Stop, // gradients refer to a range
	images:     [dynamic]Scene_Image,   // a persistent Image_Id or a borrowed view

	// Text
	runs:       [dynamic]Glyph_Run,     // a range of glyphs
	glyphs:     [dynamic]Glyph,         // outline path + transform index

	// Structure
	draws:      [dynamic]Draw,          // every draw: painted ones and referenced ones
	main:       Range,                  // the draws painted, in order
	masks:      [dynamic]Scene_Mask,    // a draw range rendered to a mask once
	patterns:   [dynamic]Pattern_Cell,  // a draw range drawn per lattice cell
	luts:       [dynamic][256]u8,       // masks' transfer functions
	filters:    [dynamic]Image_Filter,  // as today
	motions:    [dynamic]Shape_Motion,  // empty without motion blur
}
```

Only `main` is painted. A mask's or a pattern cell's draws are elsewhere in
`draws`, referred to by range, and drawn only when what names them is: so a
scene keeps one draw table, and nothing outside `main` is ever painted by
accident.

### Paths

Raw verbs and points in the units the caller drew them, with no ocurves
words and no flattening. A path is referred to by every draw that uses it, so
5,000 copies of a glyph or a map symbol are one path. Bounds are computed
once, when the path is added; they're what culling and band binning need.

Kept shapes (`Shape`, `shape_build`: prebuilt with LOD levels, held by the
caller across frames, used for maps and font glyphs) stay caller-owned
objects. A path can name one instead of points (`Scene_Path.shape`), so the
GPU uses its uploaded grid and levels, and the CPU uses its pieces. That isn't a
cache: the caller makes and destroys the shape, as today.

### Paints

```odin
Scene_Paint :: union {
	Solid,            // premultiplied RGBA
	Linear,           // start, end, stops range, spread, clip bits
	Radial,           // two circles (focal), stops range, spread, clip bits
	Conic,            // center, angle, stops range
	Image_Paint,      // image index, image-to-paint transform, sampling, tint
	Pattern,          // a pattern cell index (below)
}
```

A pattern cell (`Pattern_Cell`) is a draw range outside `main`, a cell
transform, the lattice steps (x step, y step), the cell's clip rectangle (PDF's
BBox) and whether it's uncoloured: an uncoloured cell's draws are coverage,
painted in the colour the use site gives (PDF tiling PaintType 2).

A paint is drawing-space data plus a transform index. Nothing depends on the
canvas's state, so 5,000 glyphs in one colour are one paint row, and
`Paint_Slot` and `paint_gen` go: nothing is made stale when a transform
changes. Each backend turns paints into what it needs, once per paint: a
colour for a solid fill or the CPU's direct cases, otherwise a uniform row
for the shaders, on either backend.

`Image_Paint.sampling` says what to do, not how: nearest, linear, or
area-averaged when minified (today's mipmaps). The interpolate hint PDF
carries maps to it.

### Images

```odin
Scene_Image :: union {
	Image_Id,          // persistent: in the backend's store, for UI assets and GPU textures
	Pixel_View,        // borrowed for this render: format, data, width, height, stride
}
```

Formats say what they mean (today's Gray8 samples as an alpha mask, and a
caller with an opaque grey scan stores it as RGBA, 4 times larger):

| format | samples as |
| --- | --- |
| `RGBA8_Premul` | as stored |
| `RGBA8_Straight` | premultiplied after sampling. Level 0 is filtered as stored, as a GPU sampler does; mip levels are built with colour weighted by alpha, so minified edges have no fringes |
| `Luma8` | (g, g, g, 1): a texture-type branch, as Gray8's mask is today |
| `Alpha8` | (1, 1, 1, a), so a stencil takes the paint's colour, as Gray8 does today |
| `RGBA16F` | as stored (layers, HDR) |

A `Pixel_View` is valid until the render that reads it returns. The caller
doesn't write it in between, and nothing is copied into a store. The GPU
backend uploads what a scene's views refer to as part of compiling it; the
CPU reads them in place. That is the frame-scoped borrow onimite didn't need
and odpdf does: its images are decoded per page, drawn, then dropped.

### Draws

Every painting draw (Fill, Stroke, Glyphs) carries, besides its geometry and
paint:

- an opacity (PDF's ca and CA, SVG's fill- and stroke-opacity, the canvas's
  global alpha), applied to any paint, gradients and images included;
- a blend: one of the 11 Porter-Duff composite operations the canvas has
  today (Copy, Source_In, Destination_Out, Xor, Lighter...), or source-over
  with one of the 16 blend modes, so the canvas maps onto it without loss;
- an optional mask index, read by that draw alone.

That's PDF's graphics state, where a soft mask, a blend mode and an opacity
apply to each painting operation separately (ISO 32000 11.6.3, 11.6.5).
Grouping consecutive draws into one masked layer would differ wherever they
overlap. A mask is rendered once per scene and read by every draw and layer
that names it.

```odin
Draw :: union {
	Fill,        // path, transform, paint, rule, edge (exact, aliased, feather)
	Stroke,      // path, transform, stroke style, paint; hairline: device width
	Glyphs,      // run, paint, mode: fill, stroke style, or clip
	Clear,       // rectangle, colour
	Clip_Push,   // path or glyph run, transform, rule; intersects the current clip
	Clip_Pop,
	Layer_Push,  // opacity, blend mode, isolated, knockout, filter range, mask index
	Layer_Pop,
	Program,     // a custom program run into an image (today's run_program)
	External,    // the host's callback (today's run_external, 3D interop)
}
```

Structure is nesting in the draw list, not render targets:

- **Clips** are a stack of coverage. A clip by path or by glyph run (PDF
  text clip modes) intersects the current clip until its pop. Today's
  scissor is the rectangle case.
- **Layers** are a range of draws composited as one: opacity, a blend as a
  draw's, isolated or not, knockout or not (PDF transparency groups and
  SVG's group opacity, mix-blend-mode and filters), and an optional mask.
- **Masks** (`Scene_Mask`) are a draw range outside `main`, read as alpha or
  as luminance (Rec.709 or PDF weights). A luminance mask's group is first
  composited over its backdrop colour (PDF's /BC, black by default). An
  optional 256-entry transfer table (PDF's /TR, sampled by the caller) maps
  the value. It subsumes inversion (a track matte's invert is a reversed
  table). A mask is drawn in device space, once, whatever the clips of the
  draws that read it: those clip what the draw paints, not the mask. It
  covers the union of its readers' clipped bounds, at most the target.
- **Patterns** are draw ranges a paint refers to, drawn per lattice cell.

How a layer materialises is the backend's choice. Both backends start from
today's offscreen images: `Layer_Stack`'s planning, pooling and group fold
move from the canvas into the compile step, as shared code that a backend
may call, with layers and masks bounded tightly. The CPU could instead
composite a layer band by band, in a band-sized buffer (a filter that needs
neighbouring pixels, such as blur, lighting or morphology, would still need a
full image), but only if the transparency profile in step 4 still shows the
layer passes dominating once masks render once.

### Strokes

A stroke is expanded in its path's units, then transformed, as ovg does
today: width, dashes (with their phase) and joins are measured before the
transform, so a non-uniform transform gives an elliptical pen (PDF 8.5.3,
SVG). A hairline stroke is the exception: its width is in device pixels, for
PDF's line width 0 and for UI rules.

### Glyphs

A run is a list of glyphs, each an outline path and a transform from the
glyph's units (font units) to the run's space (PDF's user space). The run
has its own transform from that space to the device. A stroked run (PDF text
render mode 1, SVG stroked text) is outlined between the two: in the run's
space, after the glyph's transform and before the run's, so its pen behaves
like any stroke's. A run may mix fonts and sizes. A clip by run is the union of
every glyph in it, so PDF's text clip over a whole BT/ET object, across
several fonts and Tj calls, is one run. A run refers to one paint, and to one
stroke style if stroked.

A run's coverage is the union of its glyphs' coverages, `1 - (1 - c1)(1 - c2)...`
per pixel, each glyph's coverage read through its own winding (non-zero) first.
It is not one winding summed across glyphs: two overlapping glyphs with
opposite contour orientations (mixed fonts) would cancel, and even-odd would
punch holes. A translucent run then paints once, so overlapping glyphs don't
darken twice, as ovg's grouped runs do today. Fonts stay out
of the Scene: the caller prepares outlines. odpdf would do that once per
document, from oglyph. ovg's `Font` and `Text_Layout` become one producer
of runs, with their outlines kept as paths (or kept shapes) for the font's
life. Hairline glyph outlines are a stroke mode of the run.

### Motion blur

As today: per-draw motion, held in `motions` row for row with the draws that
have it. Only the GPU backend and its CPU reference implement velocity
twins.

### Contract

- The result doesn't depend on the band count, the thread count or the work
  pool: same scene, same pixels. Parity tests and odpdf's render jury rely
  on it.
- Aliased edges (`edge = .Aliased`) take each pixel's centre, nudged a 64th
  of a pixel right and down, as today, so an edge through the centre falls
  on the same side in every shape. Every aliased fill uses this one rule,
  image fills included, so aliased shapes sharing an edge (images tiled as
  strips, a map's adjacent regions) partition the pixels between them: no
  gap and no overlap. Tests hold both backends to it.
- A backend renders one scene at a time. Scenes render in parallel on
  separate backends, one per thread. Persistent images belong to a backend;
  borrowed views belong to the scene, so separate backends can draw the same
  borrowed pixels.

### Lifetimes and threads

- A Scene is built on any thread and owns its tables. Clearing it keeps their
  capacity, so a builder reused frame to frame allocates nothing once it's
  warm.
- `render(backend, &scene, target)` reads it and nothing else. Borrowed views
  and caller-kept shapes must live until it returns.
- Recording canvases and `Player` become unnecessary: a Scene *is* a
  recorded frame. Build it on one thread and render it on another, with the
  same ordering rule a player has today. `Shared_Images` becomes persistent
  `Image_Id`s that the renderer's thread creates.

## Canvas as a builder

`Canvas` keeps its API where callers rely on it (save, restore, transforms,
scissor, global alpha, composite operations, `fill_path`, `stroke_path`, the
image calls, `Layer_Stack`) and appends to a Scene instead of a `Frame`:

- the current transform is added as a transform row when a draw uses it, and
  deduplicated against the last one;
- a `Paint` becomes a `Scene_Paint` row, with the current transform's index
  and the global alpha folded in;
- a scissor becomes a rectangular `Clip_Push`;
- `layer_push` and `layer_pop` become `Layer_Push` and `Layer_Pop`, and
  the draws between `layer_mask_begin` and the pop move to a mask range
  outside `main`, which the layer names;
- `flush` renders the Scene through the canvas's backend, then clears it.

Callers that build Scenes themselves (odpdf, whose display list is already
this shape) skip the canvas. The svg and lottie packages can move to the
Scene directly, which removes their use of `Layer_Stack`'s targets.

## Backends

**GPU (SDL_GPU).** Compiling a Scene builds:

- paths into ocurves grids, grouped by index, so a path drawn 5,000 times
  is built once (today's frame glyphs, generalised), and kept shapes as
  today;
- paints into uniform rows;
- layers into offscreen passes, through `Layer_Stack`'s logic moved behind
  the boundary;
- views into texture uploads;
- draws into rows, as the planner does today.

Today's shaders carry over, plus what the new semantics need, shared by
both backends. Reading a mask per draw (a mask texture in the shape shader)
belongs to step 4; the rest to step 5:

- the non-separable and separable blend modes per draw, which need the
  backdrop: a draw with one becomes a small layer, copying the backdrop under
  its bounds, as layers with a blend mode do today;
- non-isolated groups, which start from the backdrop and remove it when
  compositing;
- knockout groups, which track each element's shape apart from the group's
  opacity.

Parity holds the CPU backend to the result.

**CPU (the software backend).** It compiles the Scene onto what it runs
today, per band of rows on the work pool:
- coverage by its exact quadratic accumulation (`sw_build_pieces`,
  `sw_accumulate_cells`);
- a solid colour, or an image drawn 1:1 at a whole-pixel offset, written
  directly (`sw_fill_solid`, `sw_blit_image`), now read from the Scene's
  paints and transforms rather than matched in the GPU's shape;
- every other paint and blend through the GPU's shaders on oksl's JIT;
- a glyph run as a group, so a translucent run paints once;
- each mask rendered once per mask index, and read per draw by the shared
  shaders, as on the GPU.

**Measured and set aside: a native CPU renderer.** A prototype (steps 3 and
4) compiled fills, strokes and glyph runs into one flat edge table per scene
and resolved them per band in Odin, with no binning, against today's backend
drawing the same scenes captured from odpdf (one core):

| page | today | native |
| --- | --- | --- |
| font_type1_10 (text) | 5.4 ms | 3.9 ms |
| font_truetype_slow_post_lookup (text) | 9.9 ms | 8.1 ms |
| integration_coat_of_arms (849 vector draws) | 19.8 ms | 18.4 ms |
| stream_flate_bpc_1, image_inline_8 (images) | 18.3, 7.0 ms | no gain |

It was within 1 level of today, and of exact areas. It took about 750
lines for fills, strokes and glyph runs alone, and clips, layers, masks and
blends would have added to them, for 1 to 2 ms a page. Along the way:
- exact edges beat chords: chords shifted by two-thirds of their deviation
  lose no area (bias within ±0.08 levels), but at a one-level accuracy bar
  (1/128 to 1/256 px) they cost 8 to 13% more instructions than solving each
  row once;
- an Odin image sampler reproducing oksl's sampling exactly gave identical
  pixels and was 37 to 49% slower than the JIT on image-heavy pages, as the
  native shading ovg had before v0.0.75 lost to the JIT. On those pages the
  shader itself is 63 to 70% of the time; oksl v0.1.5's faster bound-image
  sampling took 5 to 13% off their cycles with no change in ovg;
- glyph edges need no per-edge boxes: a glyph is small, and accumulation
  skips an edge outside the band's rows by itself. Boxes per edge were a
  quarter of the time.

**Parity.** Both backends run the same paint shaders; the CPU's coverage is
exact areas and the GPU's is grids, held together by `tools/sdlgpu_parity`
within its tolerance.

## What stays, at first

- **On today's code:** filters (`Image_Filter`), custom programs, external
  callbacks and motion blur. A filter's input is a layer image, and today's
  filter code runs on it. Programs and externals target images, as today.
- **Fonts and text layout**, oglyph, ocurves' booleans, and path utilities.
- **The SDL_GPU backend's shaders and planner**, which now read the Scene's
  compiled form.

## What goes

- **From the canvas:** `Params` packing on the canvas side, and `Paint_Slot`
  and `paint_gen`.
- **From the CPU path:** `sw_match_blit_image` and `sw_fill_solid`'s
  pattern matching: the direct cases are read from the Scene's paints and
  transforms instead.
- **Elsewhere:**
  - recording canvases, `Player` and `Shared_Images`, replaced by Scenes;
  - in odpdf, its per-page shape building. Its decoding of images at about
    the drawn size stays, so that a huge scan is never held whole; ovg's
    mipmapped sampling then resamples close to 1:1.

## Staging

Each step is measured on odpdf's 233 files, its per-page cases (the coat of
arms; dense small text such as font_truetype_slow_post_lookup and
font_type1_10), the svg and Lottie suites, a UI-like frame on both backends,
and parity. Each is released on its own.

1. Done: v0.1.11.
2. This document, reviewed.
3. Done, set aside: a native CPU renderer for fills, strokes and glyph runs
   (measured above).
4. **Transparency, measured first.** Profile odpdf's transparency pages
   (tile_clamp_bug, mask_bc, fireworks) to split their cost into mask
   re-rendering, oversized layer targets, the composite and blend filter
   passes, and backdrop copies. Then the Scene types and `Canvas` building
   Scenes, compiled by both backends onto today's machinery, with each mask
   rendered once per index and read per draw by the shared shaders, and
   layers and masks bounded tightly. A CPU-only layer compositor only if the
   profile still shows the layer passes dominating after that.
5. **Blend modes per draw, isolation and knockout, and the GPU's new shader
   work for them (see Backends),** with layer planning moved behind the
   boundary. The new image formats (`Luma8` a texture-type branch on both
   backends) and borrowed views (oksl's `Channel_Image` already takes a row
   stride). The svg and Lottie suites and parity pass through the new path.
6. Apps migrate: odpdf writes its adapter and the others follow through the
   canvas. Then the "What goes" list is deleted.

## Later, not in these steps

- Mesh shadings (PDF types 4 to 7): Gouraud-shaded triangles, as a draw
  taking vertices with a colour each. odpdf tessellates Coons and tensor
  patches itself, and samples function-based shadings into a Pixel_View.

## Decided in review

- **Patterns** are draw ranges outside `main`, with only `main` painted.
- **Box gradients** leave the core paint union: no app uses them, only
  ovg's own parity scenes. `paint_box_gradient` becomes a canvas helper that
  draws a feathered rounded rectangle. That's exact for a transparent outer
  colour (UI shadows); a two-colour one fills the outer colour first.
- **No `Luma16`** until a caller needs it: odpdf converts 16-bit samples to
  8 while decoding.
- **Kept shapes stay**, as `Scene_Path.shape`. Building grids per scene would
  give up the GPU's resident buffers and the 4 to 20 times faster zoomed-out
  levels that maps rely on; callers that don't use them (odpdf) leave it
  nil.

## Open question

1. **The `Player` replacement.** onimite records on one thread and plays on
   another today. A Scene handed across threads covers it, but its images
   created on the recording side need the same ordering rule players use.

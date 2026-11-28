# The Scene: ovg's boundary as data (design draft)

Status: reviewed 2026-11-26, after ovg v0.1.11, and revised the same day
after a native CPU renderer prototype was measured and set aside (see
Backends). Revised 2026-11-27 for the API and the data's shape: every index
a one-based `*_Id` handle whose zero is never a row, clips by rectangle as
well as path,
masks and patterns in dependency order, lifetimes and glyph reuse kept out of
the Scene, and exact-truth tests (see "Decided in review"). Nothing here is
built yet. Each step in "Staging" lands on its own, as a release; the
priority is the boundary and correctness, not speed.

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
Every index is a handle of its own type, one-based, read as `table[id - 1]`:
one indexing rule everywhere. Ranges are `Range{start, count}`, as in
`Frame` today, and an empty range is none.

```odin
Path_Id      :: distinct u32 // paths[id - 1]
Transform_Id :: distinct u32 // transforms[id - 1]
Paint_Id     :: distinct u32 // paints[id - 1]
Run_Id       :: distinct u32 // runs[id - 1]
Pattern_Id   :: distinct u32 // patterns[id - 1]
Mask_Id      :: distinct u32 // masks[id - 1]
Stroke_Id    :: distinct u32 // strokes[id - 1]
Motion_Id    :: distinct u32 // motions[id - 1]
Lut_Id       :: distinct u32 // luts[id - 1]
Scene_Image_Id :: distinct u32 // images[id - 1]: a Scene_Image, not the store's Image_Id
```

Zero is never a row. For an optional handle (a mask, a stroke style, a
motion, a transfer table) it means none, so a `Draw{}` has none of them. For
a required one (a draw's path, transform, paint or run) it means the field
was left out, which the check at compile time rejects instead of drawing
row 0. Distinct types also keep a path handle from being passed where a
transform is wanted. `Image_Id` keeps its own form (a slot key), as today.

A Scene holds what the caller describes and nothing a backend derives from
it: no image lifetimes, no glyph-reuse keys, no compiled rows. Those are
worked out when the scene is compiled, in one pass over its draws, so a
Scene can't contradict itself (an index pointing at the wrong row is the one
mistake left, and the contract below makes it a checked one).

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
	Image_Paint,      // Scene_Image_Id, image-to-paint transform, sampling, tint
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
  global alpha), applied to any paint, gradients and images included. It
  means what it says: 0 is transparent (and such a draw is culled), 1
  opaque. The builder procedures default it to 1; the Scene doesn't carry
  today's `Layer_Params` rule that an opacity of 0 means 1;
- a blend: one of the 11 Porter-Duff composite operations the canvas has
  today (Copy, Source_In, Destination_Out, Xor, Lighter...), or source-over
  with one of the 16 blend modes, so the canvas maps onto it without loss.
  A Porter-Duff operation is bounded: it acts where the draw (or a layer's
  or a run's content) covers, at least 1/510, and leaves every pixel it
  doesn't cover as it was, whatever size a backend makes the layer. Unlike
  HTML canvas's unbounded operations, Copy or Source_In don't clear
  uncovered pixels; a `Scene_Clear` or a mask does that. A layer or a run
  has no shape apart from its content, so its content's alpha is its
  coverage: an edge pixel half covered takes the content's half-covered
  value, as a source image does under Copy;
- an optional mask (`Mask_Id`), read by that draw alone.

That's PDF's graphics state, where a soft mask, a blend mode and an opacity
apply to each painting operation separately (ISO 32000 11.6.3, 11.6.5).
Grouping consecutive draws into one masked layer would differ wherever they
overlap. A mask is rendered once per scene and read by every draw and layer
that names it.

```odin
Draw :: union {
	Fill,        // path, transform, paint, rule, edge (exact, aliased, feather)
	Stroke,      // path, transform, stroke style, paint; hairline: device width
	Glyphs,      // run, paint, stroke (none: filled)
	Clear,       // rectangle, colour
	Clip_Push,   // Clip_Shape (below), intersected with the current clip
	Clip_Pop,
	Layer_Push,  // opacity, blend mode, isolated, knockout, filter range, mask
	Layer_Pop,
	Program,     // a custom program run into an image (today's run_program)
	External,    // the host's callback (today's run_external, 3D interop)
}
```

```odin
Clip_Shape :: union {
	Clip_Rect, // [4]i32: whole device pixels x0, y0, x1, y1 (a scissor, PDF's re W n, SVG overflow)
	Clip_Path, // path, transform, rule
	Clip_Run,  // glyph run: the union of its glyphs (PDF's text clip modes)
}
```

Structure is nesting in the draw list, not render targets:

- **Clips** are a stack of coverage. Each push intersects the current clip
  until its pop. A rectangle is its own case rather than a four-point path,
  because it is the common one and both backends cut to it without
  rasterizing it: the GPU as a scissor, the CPU by clamping rows and
  columns. It is whole pixels, so nothing is partly covered; a rectangle with
  fractional edges is a `Clip_Path`, whose edge pixels get their exact
  coverage. A text clip is a `Clip_Run`; a `Glyphs` draw only paints. A clip by path or run has exact coverage like a fill's, and draws
  multiply theirs by it. It cuts what the draws paint and nothing else: a
  clip doesn't make a layer, so clipped draws stay separate draws with their
  own opacity and blend, as PDF and SVG define them. v0.1.15's clip
  shortcuts (dropping a clip layer its clip covers, compositing the others
  in one pass) are interim, on today's layers; the Scene's clips replace
  them.
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
  covers the union of its readers' clipped bounds, at most the target. A
  luminance mask keeps its group's premultiplied colour and each read takes
  its luminance there, which is the straight colour's times alpha: no pass
  of its own (v0.1.13). Only a transfer table needs one, once.
- **Patterns** are draw ranges a paint refers to, drawn per lattice cell.
  A cell's draws are in cell space (their transforms map into it); the
  cell's transform maps cell space to the device, and its clip rectangle
  (PDF's BBox) and steps are in cell space, the rectangle at any origin.
- **Building order.** Dependencies come first: a scene's mask and pattern
  draw ranges are appended before its `main` draws, and `main` stays the
  last range of `draws` (the builder asserts it, so a range can't fall
  inside `main` by accident).
- **Dependency order.** Masks and pattern cells may refer to each other
  (PDF nests soft masks, and a pattern may paint with a pattern or under a
  mask), so their order is kept in the one table they share, `draws`: a
  mask's or a cell's draws may name only masks and patterns whose draw
  ranges end before theirs starts. Dependencies then come first, no cycle
  (through either table) can be written, and a backend compiles every mask
  and cell in one forward pass. `main` may name any. A scene that breaks the
  order is rejected when it's compiled, not drawn wrong.

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

A glyph's transform is exactly what the caller gives. Placing glyphs on a
sub-pixel grid is the caller's decision, made before it builds the Scene:
odpdf rounds each glyph's device origin to a quarter pixel for its still
pages, and a UI or a video that moves text leaves positions as they are.
How a backend reuses a glyph's coverage is its own business and appears
nowhere in the Scene: the CPU covers each (outline, linear transform, phase
to 1/1024 px) once a frame and copies it, as v0.1.15's glyph table does, so
glyphs a caller put on one grid share an entry.

### Motion blur

As today: per-draw motion, held in `motions` and named by a draw's
`Motion_Id` (none: the draw doesn't move), so draws that never move, and the
structural ones (clips, layers), have no row. Only the GPU backend and its CPU reference implement velocity
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
- Compiling a scene checks it once, up front: every index in range, every
  range inside its table, every required handle set, masks and patterns in
  dependency order, and clip and layer pushes and pops balanced within each
  draw range on its own (`main`, each mask's, each pattern cell's). A scene that fails is rejected whole with the first
  offending draw named; past the check, the backends read the tables
  without bounds checks.

### Correctness

Each part of the contract has a test against exact truth, not against an
earlier output of ovg or against another renderer:

- coverage: exact areas of fills, strokes and glyph runs (the run's union,
  not a summed winding), within one 8-bit level, on both backends;
- aliased edges: the centre rule, and shapes sharing an edge partitioning
  the pixels with no gap or overlap;
- composites and blend modes: the Porter-Duff and blend-mode formulas
  evaluated in floats on known colours, per draw and per layer;
- masks: alpha and luminance (both weightings) on translucent colours, the
  backdrop colour and the transfer table, against the formula;
- groups: isolated and non-isolated, knockout and not, against PDF 11.4's
  equations;
- clips: rectangle, path and run, nested, against the product of their
  exact coverages.

Parity between the backends (`tools/sdlgpu_parity`) is a second check on
top, not the reference. Where ovg differs from a reference renderer (resvg,
a PDF juror) and the specification decides, ovg follows the specification
and the difference is documented, not matched with a path of its own.

### Lifetimes and threads

- A Scene is built on any thread and owns its tables. Clearing it keeps their
  capacity, so a builder reused frame to frame allocates nothing once it's
  warm.
- `render(backend, &scene, target)` reads it and nothing else. Borrowed views
  and caller-kept shapes must live until it returns.
- The memory a render works in is the backend's, sized when it compiles the
  scene: layer and mask targets, velocity twins and scratch take their
  lifetimes (first and last draw that uses them) from that pass, and
  targets whose lifetimes don't overlap share memory (on the CPU, one block
  packed as v0.1.15's transient images are; on the GPU, textures reused by
  size within the render). Blocks kept from render to render grow by at
  least half again, so a need that varies doesn't reallocate each time.
  None of this is in the Scene.
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
- a scissor becomes a `Clip_Push` of a `Clip_Rect` (a rotated scissor, a
  `Clip_Path` of its rectangle);
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
- a solid colour, or an image whose texels land one per pixel at whole
  pixels, written directly under any coverage (`sw_fill_solid`, and the
  copy for a rectangle), now read from the Scene's paints and transforms
  rather than matched in the GPU's shape;
- every other paint and blend through the GPU's shaders on oksl's JIT;
- a glyph run as a group, so a translucent run paints once, each glyph's
  coverage worked out once a frame per phase (v0.1.15's glyph table);
- clips as a stack of coverage per band: a push works out its coverage over
  the band's rows, times the clip under it, and every draw's coverage is
  multiplied by the top one, in the direct fills and in the shaders' output
  alike, with no layer and no change to the shaders;
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

   Done in v0.1.13, before the Scene types. The profile found
   tile_clamp_bug's four Multiply layers at the canvas size though they
   draw a tenth of it, and every luminance mask paying two filter passes
   (8 to 11 ns a pixel each on the CPU) before it was read. Blend layers now
   cover their window, through a copy of the backdrop under it, and a
   luminance mask is read as luminance where it's drawn. Per pass at 72
   dpi, in instructions: tile_clamp_bug 3.45 G to 2.01 G (hayro 0.47 G),
   mask_bc 0.251 G to 0.073 G (0.025 G), fireworks 0.295 G to 0.201 G
   (0.037 G). A blend in the shape shader would save at most the blend
   pass left, 2.8 of tile_clamp_bug's 88 ms, and isn't built. Rendering
   each mask once needs every reader known before the mask is drawn, so it
   waits for the Scene: fireworks draws 4 masks 64 times, about 4 of its
   11.7 ms.
   After it, on today's layers: v0.1.14 widened the CPU's 1:1 image copy;
   v0.1.15 added the glyph table, lifetime-shared transient memory and two
   clip shortcuts (a topographic map at 100 dpi, 15.7 G to 13.0 G
   instructions; removing its clip layers entirely measured 8.2 G, which is
   what the Scene's clips are for).

   Next, the Scene itself: its types as above, the up-front check, the
   exact-truth tests under "Correctness", and `Canvas` building Scenes onto
   today's machinery, with clips as coverage on the CPU and masks rendered
   once per index.
5. **Blend modes per draw, isolation and knockout, and the GPU's new shader
   work for them (see Backends),** with layer planning moved behind the
   boundary. The new image formats (`Luma8` a texture-type branch on both
   backends) and borrowed views (oksl's `Channel_Image` already takes a row
   stride). The svg and Lottie suites and parity pass through the new path.
6. Apps migrate: odpdf writes its adapter and the others follow through the
   canvas. Then the "What goes" list is deleted.

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

- **Every index is a one-based `*_Id` handle** (`Path_Id` through `Lut_Id`,
  and `Scene_Image_Id`), read as `table[id - 1]`: 0 is none for an optional
  one and a missing field, rejected by the check, for a required one.
- **Clips have a rectangle case** (`Clip_Rect`) beside paths and glyph
  runs.
- **Masks and patterns are in dependency order**, by position in `draws`:
  each names only those whose draws come before its own, so compiling is one
  forward pass and cycles can't be written, even through both tables.
- **Derived state stays out of the Scene**: image and target lifetimes,
  glyph-reuse keys and compiled rows are the backend's, worked out when it
  compiles a scene.
- **Glyph transforms are exact**: snapping is the caller's choice before it
  builds the Scene; reuse of coverage is internal to the backend.
- **Tests are against exact truth** (see "Correctness"), with parity on
  top; a difference from a reference renderer is documented, never matched
  by a path of its own.

## Open questions

1. **The `Player` replacement.** onimite records on one thread and plays on
   another today. A Scene handed across threads covers it, but its images
   created on the recording side need the same ordering rule players use.
2. **Clips by path on the GPU.** Leaning to a coverage texture per clip,
   bounded to the draws it clips and read by the same fetch as a mask in
   `shape.frag`: it matches the CPU's exact coverage within parity. A
   one-bit stencil is aliased without multisampling, and would fail both
   the exact-coverage clip tests and parity.

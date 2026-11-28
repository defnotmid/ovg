package ovg

import "base:runtime"

// The Scene: a frame as flat, read-only tables and a list of draws that
// refer to them (docs/scene.md). A caller builds one, on any thread, and a
// backend compiles and renders it; nothing a backend derives (lifetimes,
// glyph reuse, compiled rows) is kept here. `scene_check` validates a
// whole scene once, up front, so that compiling it reads the tables
// without further checks.

// Every index is a one-based handle of its own type, read as
// `table[id - 1]`. Zero is never a row: for an optional handle it means
// none, for a required one a field left out, which `scene_check` rejects.
Path_Id :: distinct u32
Transform_Id :: distinct u32
Paint_Id :: distinct u32
Run_Id :: distinct u32
Pattern_Id :: distinct u32
Mask_Id :: distinct u32
Stroke_Id :: distinct u32
Motion_Id :: distinct u32
Lut_Id :: distinct u32
// A Scene's image row (Scene_Image), not the image store's Image_Id.
Scene_Image_Id :: distinct u32

// What a path is made of, in the units the caller drew it. A verb takes
// its points in order: Move 1, Line 1, Quad 2, Cubic 3, Close 0.
Path_Verb :: enum u8 {
	Move,
	Line,
	Quad,
	Cubic,
	Close,
}

// A range of the scene's verbs and of its points, its bounds (made when
// the path is added), or a kept shape the caller owns (its words read in
// place of points; the GPU uses its uploaded grid and levels).
Scene_Path :: struct {
	verbs:  Range,
	points: Range,
	bounds: Bounds,
	shape:  ^Shape,
}

// A stroke's pen in its path's units: width, caps, join, miter limit and a
// dash pattern (a range of `dashes`, with its phase). A hairline's width is
// in device pixels instead.
Scene_Stroke_Style :: struct {
	width:       f32,
	cap_start:   Line_Cap,
	cap_end:     Line_Cap,
	join:        Line_Join,
	miter_limit: f32,
	dashes:      Range,
	dash_phase:  f32,
	hairline:    bool,
}

// Premultiplied RGBA.
Scene_Solid :: struct {
	color: [4]f32,
}

// Gradients in their transform's space, over a range of `stops`. `spread`
// is pad, reflect or repeat; `clip` cuts the paint before the first stop
// or past the last (PDF's Extend false).
Scene_Linear :: struct {
	transform:  Transform_Id,
	start, end: Vec2,
	stops:      Range,
	spread:     Gradient_Spread,
	clip:       Gradient_Clip,
}

Scene_Radial :: struct {
	transform:  Transform_Id,
	// Two circles: the focal one (centre, radius) and the outer one.
	focal:      Vec2,
	focal_r:    f32,
	center:     Vec2,
	radius:     f32,
	stops:      Range,
	spread:     Gradient_Spread,
	clip:       Gradient_Clip,
}

Scene_Conic :: struct {
	transform: Transform_Id,
	center:    Vec2,
	angle:     f32,
	stops:     Range,
}

// An image over the unit square of its transform's space (image to paint
// space), sampled as `sampling` says and multiplied by `tint`
// (premultiplied).
Scene_Image_Paint :: struct {
	image:     Scene_Image_Id,
	transform: Transform_Id,
	sampling:  Image_Sampling,
	tint:      [4]f32,
}

// A pattern cell drawn per lattice cell; an uncoloured cell's draws are
// coverage, painted in `color`.
Scene_Pattern_Paint :: struct {
	pattern: Pattern_Id,
	color:   [4]f32,
}

// What a draw paints with, in drawing space: nothing depends on any canvas
// state, so one row serves every draw that uses it.
Scene_Paint :: union {
	Scene_Solid,
	Scene_Linear,
	Scene_Radial,
	Scene_Conic,
	Scene_Image_Paint,
	Scene_Pattern_Paint,
}

// Says what to do, not how: nearest, linear, or averaged over what a
// pixel covers when minified.
Image_Sampling :: enum u8 {
	Linear,
	Nearest,
	Area,
}

// Formats that say what they mean.
Scene_Pixel_Format :: enum u8 {
	// As stored.
	RGBA8_Premul,
	// Premultiplied after sampling.
	RGBA8_Straight,
	// (g, g, g, 1).
	Luma8,
	// (1, 1, 1, a): a stencil takes the paint's colour.
	Alpha8,
	// As stored (layers, HDR).
	RGBA16F,
}

// Pixels borrowed for one render: valid, and not written, until the
// render that reads them returns.
Pixel_View :: struct {
	format:        Scene_Pixel_Format,
	data:          []u8,
	width, height: u32,
	// Bytes from one row to the next; 0 means tightly packed.
	stride:        u32,
}

// A persistent image in the backend's store, or a view borrowed for this
// render.
Scene_Image :: union {
	Image_Id,
	Pixel_View,
}

// A glyph: an outline path and its transform from the glyph's units to
// the run's space.
Scene_Glyph :: struct {
	path:      Path_Id,
	transform: Transform_Id,
}

// A range of glyphs and the run's transform from its space to the device.
// Its coverage is the union of its glyphs' coverages, each through its own
// non-zero winding.
Scene_Run :: struct {
	glyphs:    Range,
	transform: Transform_Id,
}

// How a draw's coverage meets its edge: exact area, the aliased centre
// rule, or the exact area eased across a feathered edge (`feather` px).
Scene_Edge :: struct {
	kind:    Shape_Edge,
	feather: f32,
}

// How a draw combines with what is under it: a Porter-Duff operation, or
// source-over with a blend mode.
Scene_Blend :: struct {
	op:   Composite_Operation,
	mode: Blend_Mode,
}

// What every painting draw carries besides its geometry and paint. An
// opacity of 0 is transparent and 1 opaque; builders default it to 1.
Scene_Look :: struct {
	paint:   Paint_Id,
	opacity: f32,
	blend:   Scene_Blend,
	mask:    Mask_Id,
	motion:  Motion_Id,
}

Scene_Fill :: struct {
	path:      Path_Id,
	transform: Transform_Id,
	rule:      Fill_Rule,
	edge:      Scene_Edge,
	using look: Scene_Look,
}

Scene_Stroke :: struct {
	path:      Path_Id,
	transform: Transform_Id,
	style:     Stroke_Id,
	using look: Scene_Look,
}

// A glyph run, filled, or stroked with `stroke` between the glyphs' and
// the run's transforms.
Scene_Glyphs :: struct {
	run:    Run_Id,
	stroke: Stroke_Id,
	using look: Scene_Look,
}

// A rectangle of whole device pixels set to `color` (premultiplied).
Scene_Clear :: struct {
	rect:  [4]i32,
	color: [4]f32,
}

// Whole device pixels x0, y0, x1, y1.
Clip_Rect :: distinct [4]i32

Clip_Path :: struct {
	path:      Path_Id,
	transform: Transform_Id,
	rule:      Fill_Rule,
}

Clip_Run :: struct {
	run: Run_Id,
}

Clip_Shape :: union {
	Clip_Rect,
	Clip_Path,
	Clip_Run,
}

// Intersects the current clip with `shape` until the matching pop.
Clip_Push :: struct {
	shape: Clip_Shape,
}

Clip_Pop :: struct {}

// The draws to the matching pop composited as one.
Layer_Push :: struct {
	opacity:  f32,
	blend:    Scene_Blend,
	isolated: bool,
	knockout: bool,
	filters:  Range,
	mask:     Mask_Id,
}

Layer_Pop :: struct {}

Scene_Draw :: union {
	Scene_Fill,
	Scene_Stroke,
	Scene_Glyphs,
	Scene_Clear,
	Clip_Push,
	Clip_Pop,
	Layer_Push,
	Layer_Pop,
}

// How a mask reads its group.
Scene_Mask_Read :: enum u8 {
	Alpha,
	// Luminance with Rec. 709 weights.
	Luminance,
	// Luminance with PDF's weights.
	Luminance_Pdf,
}

// A draw range outside `main` rendered once into a mask, read by every
// draw and layer that names it. A luminance mask's group is composited
// over `backdrop` first (PDF's /BC); `lut` maps the value (PDF's /TR).
Scene_Mask :: struct {
	draws:    Range,
	read:     Scene_Mask_Read,
	backdrop: [4]f32,
	lut:      Lut_Id,
}

// A draw range outside `main` drawn per lattice cell: the cell's transform,
// its steps, its clip rectangle (PDF's BBox, in cell space) and whether its
// draws are coverage painted in the use site's colour.
Pattern_Cell :: struct {
	draws:      Range,
	transform:  Transform_Id,
	step:       Vec2,
	clip:       Bounds,
	uncoloured: bool,
}

Scene :: struct {
	transforms: [dynamic]Transform2D,
	verbs:      [dynamic]Path_Verb,
	points:     [dynamic]Vec2,
	paths:      [dynamic]Scene_Path,
	strokes:    [dynamic]Scene_Stroke_Style,
	dashes:     [dynamic]f32,
	paints:     [dynamic]Scene_Paint,
	stops:      [dynamic]Gradient_Stop,
	images:     [dynamic]Scene_Image,
	runs:       [dynamic]Scene_Run,
	glyphs:     [dynamic]Scene_Glyph,
	// Every draw: those painted (`main`) and those masks and pattern cells
	// refer to by range.
	draws:      [dynamic]Scene_Draw,
	main:       Range,
	masks:      [dynamic]Scene_Mask,
	patterns:   [dynamic]Pattern_Cell,
	luts:       [dynamic][256]u8,
	filters:    [dynamic]Image_Filter,
	motions:    [dynamic]Shape_Motion,
}

scene_init :: proc(s: ^Scene, allocator := context.allocator) {
	s.transforms = make([dynamic]Transform2D, allocator)
	s.verbs = make([dynamic]Path_Verb, allocator)
	s.points = make([dynamic]Vec2, allocator)
	s.paths = make([dynamic]Scene_Path, allocator)
	s.strokes = make([dynamic]Scene_Stroke_Style, allocator)
	s.dashes = make([dynamic]f32, allocator)
	s.paints = make([dynamic]Scene_Paint, allocator)
	s.stops = make([dynamic]Gradient_Stop, allocator)
	s.images = make([dynamic]Scene_Image, allocator)
	s.runs = make([dynamic]Scene_Run, allocator)
	s.glyphs = make([dynamic]Scene_Glyph, allocator)
	s.draws = make([dynamic]Scene_Draw, allocator)
	s.masks = make([dynamic]Scene_Mask, allocator)
	s.patterns = make([dynamic]Pattern_Cell, allocator)
	s.luts = make([dynamic][256]u8, allocator)
	s.filters = make([dynamic]Image_Filter, allocator)
	s.motions = make([dynamic]Shape_Motion, allocator)
}

scene_destroy :: proc(s: ^Scene) {
	delete(s.transforms)
	delete(s.verbs)
	delete(s.points)
	delete(s.paths)
	delete(s.strokes)
	delete(s.dashes)
	delete(s.paints)
	delete(s.stops)
	delete(s.images)
	delete(s.runs)
	delete(s.glyphs)
	delete(s.draws)
	delete(s.masks)
	delete(s.patterns)
	delete(s.luts)
	delete(s.filters)
	delete(s.motions)
	s^ = {}
}

// Empties every table, keeping its room, so a scene rebuilt each frame
// allocates nothing once warm.
scene_clear :: proc(s: ^Scene) {
	clear(&s.transforms)
	clear(&s.verbs)
	clear(&s.points)
	clear(&s.paths)
	clear(&s.strokes)
	clear(&s.dashes)
	clear(&s.paints)
	clear(&s.stops)
	clear(&s.images)
	clear(&s.runs)
	clear(&s.glyphs)
	clear(&s.draws)
	s.main = {}
	clear(&s.masks)
	clear(&s.patterns)
	clear(&s.luts)
	clear(&s.filters)
	clear(&s.motions)
}

scene_add_transform :: proc(s: ^Scene, t: Transform2D) -> Transform_Id {
	append(&s.transforms, t)
	return Transform_Id(len(s.transforms))
}

// The points a verb takes.
path_verb_points :: proc "contextless" (v: Path_Verb) -> int {
	switch v {
	case .Move, .Line:
		return 1
	case .Quad:
		return 2
	case .Cubic:
		return 3
	case .Close:
		return 0
	}
	return 0
}

// A path of `verbs` over `points`, copied into the scene, its bounds those
// of its points (control points included, so they hold its curves).
scene_add_path :: proc(s: ^Scene, verbs: []Path_Verb, points: []Vec2) -> Path_Id {
	v0, p0 := len(s.verbs), len(s.points)
	append(&s.verbs, ..verbs)
	append(&s.points, ..points)
	b := EMPTY_BOUNDS
	for p in points {
		b = {min(b.minx, p.x), min(b.miny, p.y), max(b.maxx, p.x), max(b.maxy, p.y)}
	}
	append(&s.paths, Scene_Path{verbs = {u32(v0), u32(len(verbs))}, points = {u32(p0), u32(len(points))}, bounds = b})
	return Path_Id(len(s.paths))
}

scene_add_paint :: proc(s: ^Scene, p: Scene_Paint) -> Paint_Id {
	append(&s.paints, p)
	return Paint_Id(len(s.paints))
}

scene_add_stroke :: proc(s: ^Scene, style: Scene_Stroke_Style) -> Stroke_Id {
	append(&s.strokes, style)
	return Stroke_Id(len(s.strokes))
}

scene_add_image :: proc(s: ^Scene, image: Scene_Image) -> Scene_Image_Id {
	append(&s.images, image)
	return Scene_Image_Id(len(s.images))
}

// Appends a draw to `main`, which must be the draws' last range: a scene
// is built with `main` drawn last, or set by the caller.
scene_draw :: proc(s: ^Scene, d: Scene_Draw) {
	if s.main.count == 0 {
		s.main.start = u32(len(s.draws))
	}
	append(&s.draws, d)
	s.main.count = u32(len(s.draws)) - s.main.start
}

// A painting draw's look: `paint`, opaque, source-over, no mask, still.
scene_look :: proc "contextless" (paint: Paint_Id) -> Scene_Look {
	return {paint = paint, opacity = 1, blend = {op = .Source_Over}}
}

// Why `scene_check` rejected a scene.
Scene_Error :: enum u8 {
	None,
	// A required handle left 0.
	Missing_Handle,
	// A handle past its table.
	Handle_Out_Of_Range,
	// A range past the end of its table.
	Range_Out_Of_Bounds,
	// A path's verbs don't take the points it has.
	Path_Points_Mismatch,
	// A mask's or a pattern cell's draws name a mask or pattern that isn't
	// earlier in its table (or name themselves).
	Dependency_Order,
	// A Clip_Pop or Layer_Pop without its push, or a push without its pop,
	// within one draw range.
	Unbalanced,
}

// Where `scene_check` found the first problem: the draw (index into
// `draws`), or the row of another table, with which table it was.
Scene_Problem :: struct {
	error: Scene_Error,
	table: Scene_Table,
	index: int,
}

Scene_Table :: enum u8 {
	Draws,
	Paths,
	Paints,
	Runs,
	Glyphs,
	Masks,
	Patterns,
}

// Checks a whole scene once: every handle set where required and inside
// its table, every range inside its table, every path's verbs and points
// agreeing, masks and pattern cells naming only earlier ones, and pushes
// and pops balanced within `main` and within each mask's and pattern
// cell's range on its own. Returns the first problem, or `.None`.
scene_check :: proc(s: ^Scene) -> Scene_Problem {
	in_range :: proc "contextless" (r: Range, n: int) -> bool {
		return int(r.start) + int(r.count) <= n
	}
	handle :: proc "contextless" (id: u32, n: int, required: bool) -> Scene_Error {
		if id == 0 {
			return .Missing_Handle if required else .None
		}
		return .None if int(id) <= n else .Handle_Out_Of_Range
	}
	for p, i in s.paths {
		if p.shape != nil {
			continue
		}
		if !in_range(p.verbs, len(s.verbs)) || !in_range(p.points, len(s.points)) {
			return {.Range_Out_Of_Bounds, .Paths, i}
		}
		n := 0
		for v in s.verbs[p.verbs.start:][:p.verbs.count] {
			n += path_verb_points(v)
		}
		if n != int(p.points.count) {
			return {.Path_Points_Mismatch, .Paths, i}
		}
	}
	for g, i in s.glyphs {
		if e := handle(u32(g.path), len(s.paths), true); e != .None {
			return {e, .Glyphs, i}
		}
		if e := handle(u32(g.transform), len(s.transforms), true); e != .None {
			return {e, .Glyphs, i}
		}
	}
	for r, i in s.runs {
		if !in_range(r.glyphs, len(s.glyphs)) {
			return {.Range_Out_Of_Bounds, .Runs, i}
		}
		if e := handle(u32(r.transform), len(s.transforms), true); e != .None {
			return {e, .Runs, i}
		}
	}
	for p, i in s.paints {
		e := Scene_Error.None
		switch v in p {
		case Scene_Solid:
		case Scene_Linear:
			e = handle(u32(v.transform), len(s.transforms), true)
			if e == .None && !in_range(v.stops, len(s.stops)) {
				e = .Range_Out_Of_Bounds
			}
		case Scene_Radial:
			e = handle(u32(v.transform), len(s.transforms), true)
			if e == .None && !in_range(v.stops, len(s.stops)) {
				e = .Range_Out_Of_Bounds
			}
		case Scene_Conic:
			e = handle(u32(v.transform), len(s.transforms), true)
			if e == .None && !in_range(v.stops, len(s.stops)) {
				e = .Range_Out_Of_Bounds
			}
		case Scene_Image_Paint:
			e = handle(u32(v.image), len(s.images), true)
			if e == .None {
				e = handle(u32(v.transform), len(s.transforms), true)
			}
		case Scene_Pattern_Paint:
			e = handle(u32(v.pattern), len(s.patterns), true)
		}
		if e != .None {
			return {e, .Paints, i}
		}
	}
	for m, i in s.masks {
		if !in_range(m.draws, len(s.draws)) {
			return {.Range_Out_Of_Bounds, .Masks, i}
		}
		if e := handle(u32(m.lut), len(s.luts), false); e != .None {
			return {e, .Masks, i}
		}
	}
	for p, i in s.patterns {
		if !in_range(p.draws, len(s.draws)) {
			return {.Range_Out_Of_Bounds, .Patterns, i}
		}
		if e := handle(u32(p.transform), len(s.transforms), true); e != .None {
			return {e, .Patterns, i}
		}
	}
	if !in_range(s.main, len(s.draws)) {
		return {.Range_Out_Of_Bounds, .Draws, int(s.main.start)}
	}
	// Each range on its own: main may name any mask or pattern; a mask's or
	// a cell's draws only those whose ranges end before theirs starts.
	if p := scene_check_draws(s, s.main, true); p.error != .None {
		return p
	}
	for m in s.masks {
		if p := scene_check_draws(s, m.draws, false); p.error != .None {
			return p
		}
	}
	for c in s.patterns {
		if p := scene_check_draws(s, c.draws, false); p.error != .None {
			return p
		}
	}
	return {}
}

// The draws of range `r`: their handles, the masks and patterns they may
// name, and their pushes and pops nesting. Outside `main` a draw may name
// only a mask or pattern whose draws end before `r` starts in the draw
// table, so dependencies come first in it and no cycle can be written.
@(private = "file")
scene_check_draws :: proc(s: ^Scene, r: Range, is_main: bool) -> Scene_Problem {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	handle :: proc "contextless" (id: u32, n: int, required: bool) -> Scene_Error {
		if id == 0 {
			return .Missing_Handle if required else .None
		}
		return .None if int(id) <= n else .Handle_Out_Of_Range
	}
	before :: proc "contextless" (dep, r: Range, is_main: bool) -> bool {
		return is_main || dep.start + dep.count <= r.start
	}
	look :: proc(s: ^Scene, l: Scene_Look, r: Range, is_main: bool) -> Scene_Error {
		if e := handle(u32(l.paint), len(s.paints), true); e != .None {
			return e
		}
		if e := handle(u32(l.mask), len(s.masks), false); e != .None {
			return e
		}
		if e := handle(u32(l.motion), len(s.motions), false); e != .None {
			return e
		}
		if l.mask != 0 && !before(s.masks[l.mask - 1].draws, r, is_main) {
			return .Dependency_Order
		}
		if pp, ok := s.paints[l.paint - 1].(Scene_Pattern_Paint); ok && !before(s.patterns[pp.pattern - 1].draws, r, is_main) {
			return .Dependency_Order
		}
		return .None
	}
	// The pushes open, innermost last: a pop must close the last one.
	Open :: enum u8 {Clip, Layer}
	open := make([dynamic]Open, context.temp_allocator)
	for k in r.start ..< r.start + r.count {
		e := Scene_Error.None
		switch d in s.draws[k] {
		case Scene_Fill:
			e = handle(u32(d.path), len(s.paths), true)
			if e == .None {
				e = handle(u32(d.transform), len(s.transforms), true)
			}
			if e == .None {
				e = look(s, d.look, r, is_main)
			}
		case Scene_Stroke:
			e = handle(u32(d.path), len(s.paths), true)
			if e == .None {
				e = handle(u32(d.transform), len(s.transforms), true)
			}
			if e == .None {
				e = handle(u32(d.style), len(s.strokes), true)
			}
			if e == .None {
				e = look(s, d.look, r, is_main)
			}
		case Scene_Glyphs:
			e = handle(u32(d.run), len(s.runs), true)
			if e == .None {
				e = handle(u32(d.stroke), len(s.strokes), false)
			}
			if e == .None {
				e = look(s, d.look, r, is_main)
			}
		case Scene_Clear:
		case Clip_Push:
			append(&open, Open.Clip)
			switch c in d.shape {
			case Clip_Rect:
			case Clip_Path:
				e = handle(u32(c.path), len(s.paths), true)
				if e == .None {
					e = handle(u32(c.transform), len(s.transforms), true)
				}
			case Clip_Run:
				e = handle(u32(c.run), len(s.runs), true)
			case:
				e = .Missing_Handle
			}
		case Clip_Pop:
			if last, ok := pop_safe(&open); !ok || last != .Clip {
				e = .Unbalanced
			}
		case Layer_Push:
			append(&open, Open.Layer)
			if int(d.filters.start) + int(d.filters.count) > len(s.filters) {
				e = .Range_Out_Of_Bounds
			} else if e = handle(u32(d.mask), len(s.masks), false); e == .None && d.mask != 0 && !before(s.masks[d.mask - 1].draws, r, is_main) {
				e = .Dependency_Order
			}
		case Layer_Pop:
			if last, ok := pop_safe(&open); !ok || last != .Layer {
				e = .Unbalanced
			}
		case:
			e = .Missing_Handle
		}
		if e != .None {
			return {e, .Draws, int(k)}
		}
	}
	if len(open) != 0 {
		return {.Unbalanced, .Draws, int(r.start + r.count) - 1 if r.count > 0 else int(r.start)}
	}
	return {}
}

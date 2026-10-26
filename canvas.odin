package ovg

import "core:math"
import "core:mem"

import cv "curves"

// The 2D drawing context. Records draw commands for a frame; `flush` hands
// them to the backend. Port of femtovg's `Canvas`.
Canvas :: struct {
	allocator:             mem.Allocator,
	backend:               Backend,
	width:                 u32,
	height:                u32,
	current_render_target: Render_Target,
	// Drawing coordinates of the target's top-left pixel.
	current_render_origin: [2]i32,
	states:                [dynamic]State,
	commands:              [dynamic]Command,
	paints:                [dynamic]Params,
	// Uniform blocks of custom program runs (program.odin).
	bytes:                 [dynamic]u8,
	filters:               [dynamic]Image_Filter,
	runs:                  [dynamic]Program_Run,
	shapes:                [dynamic]Shape_Instance,
	// The words of the shapes paths are filled with this frame.
	shape_words:           [dynamic]u32,
	// Building the shapes of paths filled and stroked.
	scratch:               Shape_Scratch,
	images:                Image_Store,
	programs:              Slot_Map(Backend_Program),
	gradients:             Gradient_Store,
	fringe_width:          f32,
	device_px_ratio:       f32,
	// Bounds on per-draw work (limits.odin); canvas_init sets
	// DEFAULT_LIMITS. Dashes use Dash_Segments.
	limits:                Limits,
	// The limits reached since init (clear it to watch again).
	limited:               bit_set[Limit],
	// Programs registered on a recording canvas, for the player to create.
	program_ops:           [dynamic]Program_Op,
}

canvas_init :: proc(c: ^Canvas, backend: Backend, allocator := context.allocator) {
	c^ = {
		allocator       = allocator,
		backend         = backend,
		states          = make([dynamic]State, allocator),
		commands        = make([dynamic]Command, allocator),
		paints          = make([dynamic]Params, allocator),
		shapes          = make([dynamic]Shape_Instance, allocator),
		shape_words     = make([dynamic]u32, allocator),
		bytes           = make([dynamic]u8, allocator),
		filters         = make([dynamic]Image_Filter, allocator),
		runs            = make([dynamic]Program_Run, allocator),
		limits          = DEFAULT_LIMITS,
		fringe_width    = 1,
		device_px_ratio = 1,
	}
	shape_scratch_init(&c.scratch, allocator)
	image_store_init(&c.images, backend, allocator)
	gradient_store_init(&c.gradients, allocator)
	slot_map_init(&c.programs, allocator)
	append(&c.states, default_state())
}

// A canvas that records frames for another thread to play (`canvas_take`,
// `Player`): drawing works as on any canvas, but nothing reaches a backend,
// so it can run on any thread. Images and programs get their ids here and
// are made by the player. Drawing is identical to a canvas on the player's
// backend.
canvas_init_recording :: proc(c: ^Canvas, allocator := context.allocator) {
	canvas_init(c, {set_size = proc(data: rawptr, width, height: u32, dpi: f32) {}}, allocator)
	c.images.recording = true
	c.program_ops = make([dynamic]Program_Op, allocator)
}

canvas_destroy :: proc(c: ^Canvas) {
	delete(c.states)
	delete(c.commands)
	delete(c.paints)
	delete(c.bytes)
	delete(c.filters)
	delete(c.runs)
	delete(c.shapes)
	delete(c.shape_words)
	shape_scratch_destroy(&c.scratch)
	programs_destroy(c)
	image_store_destroy(&c.images)
	gradient_store_destroy(&c.gradients)
	delete(c.program_ops)
	c^ = {}
}

// ---- state ------------------------------------------------------------------

state :: #force_inline proc "contextless" (c: ^Canvas) -> ^State {
	return &c.states[len(c.states) - 1]
}

save :: proc(c: ^Canvas) {
	append(&c.states, state(c)^)
}

restore :: proc(c: ^Canvas) {
	if len(c.states) > 1 {
		pop(&c.states)
	} else {
		reset(c)
	}
}

// Resets the current state to defaults.
reset :: proc "contextless" (c: ^Canvas) {
	state(c)^ = default_state()
}

// Sets the screen size in device pixels and starts a frame on the screen.
set_size :: proc(c: ^Canvas, width, height: u32, dpi: f32 = 1) {
	c.width = width
	c.height = height
	c.fringe_width = 1.0 / dpi
	c.device_px_ratio = dpi
	c.backend.set_size(c.backend.data, width, height, dpi)
	c.current_render_target = nil
	c.current_render_origin = {}
	append(&c.commands, Command{type = Cmd_Set_Render_Target{}})
}

render_target_size :: proc(c: ^Canvas) -> (w, h: u32) {
	switch id in c.current_render_target {
	case Image_Id:
		if info, ok := image_store_info(&c.images, id); ok {
			return info.width, info.height
		}
		return 0, 0
	}
	return c.width, c.height
}

set_global_alpha :: proc "contextless" (c: ^Canvas, alpha: f32) {
	state(c).alpha = alpha
}

set_composite_operation :: proc "contextless" (c: ^Canvas, op: Composite_Operation) {
	state(c).composite_operation = composite_state_from_op(op)
}

set_composite_blend_func :: proc "contextless" (c: ^Canvas, src, dst: Blend_Factor) {
	state(c).composite_operation = {src, dst, src, dst}
}

set_composite_blend_func_separate :: proc "contextless" (c: ^Canvas, src_rgb, dst_rgb, src_alpha, dst_alpha: Blend_Factor) {
	state(c).composite_operation = {src_rgb, dst_rgb, src_alpha, dst_alpha}
}

// Directs subsequent drawing to `target` (`nil` = screen), whose top-left
// pixel is at `origin` in drawing coordinates.
set_render_target :: proc(c: ^Canvas, target: Render_Target, origin := [2]i32{}) {
	if c.current_render_target != target || c.current_render_origin != origin {
		append(&c.commands, Command{type = Cmd_Set_Render_Target{target, origin}})
		c.current_render_target = target
		c.current_render_origin = origin
	}
}

// ---- transforms ---------------------------------------------------------------

reset_transform :: proc "contextless" (c: ^Canvas) {
	state(c).transform = TRANSFORM_IDENTITY
}

// Replaces the current transform.
set_transform :: proc "contextless" (c: ^Canvas, t: Transform2D) {
	state(c).transform = t
}

// Applies `t` before the current transform (femtovg's `set_transform`).
apply_transform :: proc "contextless" (c: ^Canvas, t: Transform2D) {
	transform_premultiply(&state(c).transform, t)
}

translate :: proc "contextless" (c: ^Canvas, x, y: f32) {
	apply_transform(c, transform_translation(x, y))
}

rotate :: proc "contextless" (c: ^Canvas, angle: f32) {
	apply_transform(c, transform_rotation(angle))
}

scale :: proc "contextless" (c: ^Canvas, x, y: f32) {
	apply_transform(c, transform_scaling(x, y))
}

skew_x :: proc "contextless" (c: ^Canvas, angle: f32) {
	apply_transform(c, transform_skew_x(angle))
}

skew_y :: proc "contextless" (c: ^Canvas, angle: f32) {
	apply_transform(c, transform_skew_y(angle))
}

current_transform :: proc "contextless" (c: ^Canvas) -> Transform2D {
	return state(c).transform
}

// ---- scissor ------------------------------------------------------------------

// Clips drawing to a rectangle in current coordinates.
scissor :: proc "contextless" (c: ^Canvas, x, y, width, height: f32) {
	w, h := max(width, 0), max(height, 0)
	st := state(c)
	st.scissor.transform = transform_multiply(transform_translation(x + w * 0.5, y + h * 0.5), st.transform)
	st.scissor.extent = {w * 0.5, h * 0.5}
	st.scissor.has_extent = true
}

// Intersects the current scissor with a rectangle. With a rotated transform
// the result is the bounding box of the intersection, as in femtovg.
intersect_scissor :: proc "contextless" (c: ^Canvas, x, y, w, h: f32) {
	st := state(c)
	if !st.scissor.has_extent {
		scissor(c, x, y, w, h)
		return
	}
	m := transform_multiply(st.scissor.transform, transform_inverse(st.transform))
	ex, ey := st.scissor.extent[0], st.scissor.extent[1]
	tex := ex * abs(m[0]) + ey * abs(m[2])
	tey := ex * abs(m[1]) + ey * abs(m[3])
	r := rect_intersect({m[4] - tex, m[5] - tey, tex * 2, tey * 2}, {x, y, w, h})
	scissor(c, r.x, r.y, r.w, r.h)
}

reset_scissor :: proc "contextless" (c: ^Canvas) {
	state(c).scissor = {transform = TRANSFORM_IDENTITY}
}

@(private)
current_scissor_rect :: proc(c: ^Canvas) -> Maybe(Rect) {
	w, h := render_target_size(c)
	if r, ok := scissor_as_rect(state(c).scissor, f32(w), f32(h)); ok {
		if !state(c).scissor.has_extent {
			// The whole target, in drawing coordinates.
			r.x, r.y = f32(c.current_render_origin.x), f32(c.current_render_origin.y)
		}
		return r
	}
	return nil
}

// Overwrites a rectangle of the current target with `color`, ignoring the
// transform and composite state but honouring an axis-aligned scissor.
clear_rect :: proc(c: ^Canvas, x, y, width, height: u32, color: Color) {
	append(
		&c.commands,
		Command {
			type = Cmd_Clear_Rect{x, y, width, height, color},
			composite_operation = composite_state_from_op(.Copy),
			scissor_rect = current_scissor_rect(c),
		},
	)
}

// ---- images -------------------------------------------------------------------

create_image_empty :: proc(c: ^Canvas, width, height: u32, format: Pixel_Format, flags: Image_Flags = {}) -> (Image_Id, Error) {
	return image_store_alloc(&c.images, {flags, width, height, format})
}

// An image filled with `src` that players of this recording canvas's
// frames share under `key` (one texture for all of them, `Shared_Images`);
// `create_image` on other canvases. `stable`: `src.data` outlives the
// playing of every frame recorded with it, so it is borrowed, not copied.
create_image_shared :: proc(c: ^Canvas, src: Image_Source, key: u64, stable := false, flags: Image_Flags = {}) -> (Image_Id, Error) {
	return image_store_alloc_shared(&c.images, {flags, src.width, src.height, src.format}, src, key, stable)
}

create_image :: proc(c: ^Canvas, src: Image_Source, flags: Image_Flags = {}) -> (id: Image_Id, err: Error) {
	id = create_image_empty(c, src.width, src.height, src.format, flags) or_return
	if update_err := image_store_update(&c.images, id, src, 0, 0); update_err != nil {
		image_store_remove(&c.images, id)
		return {}, update_err
	}
	return id, nil
}

update_image :: proc(c: ^Canvas, id: Image_Id, src: Image_Source, x, y: u32) -> Error {
	return image_store_update(&c.images, id, src, x, y)
}

delete_image :: proc(c: ^Canvas, id: Image_Id) {
	image_store_remove(&c.images, id)
}

image_info :: proc(c: ^Canvas, id: Image_Id) -> (Image_Info, bool) {
	return image_store_info(&c.images, id)
}

// Copies an image's texels back as stored, tightly packed (RGBA16F: four
// f16 per pixel), as of the last flush. Not on recording canvases.
read_image :: proc(c: ^Canvas, id: Image_Id, allocator := context.allocator) -> ([]u8, Error) {
	entry := image_store_get(&c.images, id)
	if entry == nil || entry.virtual {
		return nil, .Image_Id_Not_Found
	}
	if c.images.recording || c.backend.read_image == nil {
		return nil, .Unsupported_Operation
	}
	return c.backend.read_image(c.backend.data, entry.image, entry.info, allocator)
}

realloc_image :: proc(c: ^Canvas, id: Image_Id, width, height: u32, format: Pixel_Format, flags: Image_Flags = {}) -> Error {
	return image_store_realloc(&c.images, id, {flags, width, height, format})
}

// Writes `filter(source)` into `target` when the frame is flushed. Both
// images must have the same size and format. Transforms, scissor and the
// current render target do not apply.
filter_image :: proc(c: ^Canvas, target: Image_Id, filter: Image_Filter, source: Image_Id) {
	append(&c.filters, filter)
	append(&c.commands, Command{type = Cmd_Filter_Image{target, u32(len(c.filters) - 1)}, image = source})
}

// ---- paths ----------------------------------------------------------------------

// Whether drawing coordinates (x, y) are inside `p` (under the current
// transform) by `rule`: the winding of the point about the path's exact
// curves, Solid / Hole winding its contours as fill does.
contains_point :: proc(c: ^Canvas, p: ^Path, x, y: f32, rule: Fill_Rule) -> bool {
	h := &c.scratch.hit
	cv.contours_clear(h)
	contours_append_path(h, p, state(c).transform)
	w, _ := cv.contours_winding(h, 0, len(h.contours), {f64(x), f64(y)}, &c.scratch.stack)
	return cv.fill_inside(w, rule == .Even_Odd)
}

// Bounds of the path under the current transform.
path_bounds :: proc(c: ^Canvas, p: ^Path) -> Bounds {
	return path_device_bounds(c, p, state(c).transform)
}

// The exact bounds of what `p` draws under `t`: each segment's ends and
// turning points (a lone Move_To and zero-length segments draw nothing).
path_device_bounds :: proc(c: ^Canvas, p: ^Path, t: Transform2D) -> Bounds {
	b := EMPTY_BOUNDS
	add :: proc(b: ^Bounds, lo, hi: Vec2) {
		b^ = {min(b.minx, lo.x), min(b.miny, lo.y), max(b.maxx, hi.x), max(b.maxy, hi.y)}
	}
	at :: proc(t: Transform2D, p: Vec2) -> Vec2 {
		return transform_point(t, p.x, p.y)
	}
	it := path_events(p)
	for e in path_events_next(&it) {
		switch e.kind {
		case .Line, .Close:
			if e.p[0] == e.p[1] {
				continue
			}
			a, z := at(t, e.p[0]), at(t, e.p[1])
			add(&b, {min(a.x, z.x), min(a.y, z.y)}, {max(a.x, z.x), max(a.y, z.y)})
		case .Cubic:
			if e.p[0] == e.p[1] && e.p[1] == e.p[2] && e.p[2] == e.p[3] {
				continue
			}
			lo, hi := cv.cubic_bounds([4]Vec2{at(t, e.p[0]), at(t, e.p[1]), at(t, e.p[2]), at(t, e.p[3])})
			add(&b, lo, hi)
		case .Begin, .Solid, .Hole:
		}
	}
	return b
}

@(private)
outside_target :: proc(c: ^Canvas, b: Bounds) -> bool {
	w, h := render_target_size(c)
	x, y := f32(c.current_render_origin.x), f32(c.current_render_origin.y)
	return b.maxx < x || b.minx > x + f32(w) || b.maxy < y || b.miny > y + f32(h)
}

// Fills `p` by per-pixel coverage: the path becomes a shape for this frame
// (shape.odin), built in drawing coordinates, so its pixels' footprints
// are upright boxes. A feathered paint widens the footprint and eases the
// coverage in (Params.smooth_edge); one without anti-aliasing takes each
// pixel center's winding.
fill_path :: proc(c: ^Canvas, p: ^Path, paint: Paint) {
	t := state(c).transform
	b := &c.scratch.builder
	shape_builder_reset(b)
	b.tol = 1.0 / 16
	shape_add_path(b, p, t)
	fill_built(c, paint, t)
}

// Fills the canvas's builder's curves (drawing coordinates) with `paint`,
// as a shape for this frame; `t` is the transform they were made under.
@(private)
fill_built :: proc(c: ^Canvas, paint: Paint, t: Transform2D) {
	start := len(c.shape_words)
	origin, extent, ok := cv.build_append(&c.scratch.builder, &c.shape_words, search = false)
	if !ok {
		return
	}
	words := c.shape_words[start:]
	inst := paint_instance(paint, t)
	inst.words = {u32(start), u32(len(words))}
	inst.transform = {extent, 0, 0, extent, origin.x, origin.y}
	if outside_target(c, device_bounds(words, inst.transform, 1 + inst.widen)) {
		resize(&c.shape_words, start)
		return
	}
	cmd: Command
	cmd, inst.paint = shape_paint(c, paint)
	push_shape(c, cmd, inst)
}

// An instance filling with `paint` drawn under `t` (path units to drawing
// coordinates): the paint's fill rule, anti-aliasing and feather.
@(private)
paint_instance :: proc "contextless" (paint: Paint, t: Transform2D) -> Shape_Instance {
	inst := Shape_Instance {
		even_odd = paint.fill_rule == .Even_Odd,
		aliased  = !paint.anti_alias,
	}
	if paint.feather > 0 {
		// femtovg's fringe for the feather, as the footprint's growth.
		scale := math.sqrt(abs(t[0] * t[3] - t[1] * t[2]))
		inst.widen = 1.5 * paint.feather * scale * math.SQRT_TWO * math.sqrt(f32(math.PI))
	}
	return inst
}

// Fills a shape (shape.odin) with `paint` under the current transform, by
// per-pixel coverage: no tessellation, so a shape built once draws at any
// transform for the cost of its bounds. `local` maps the shape's source
// units (its path's, or a glyph's font units, y down) to current units.
// The paint fills as with fill_path (fill rule, anti-aliasing, feather).
// The frame keeps `s`'s address: the shape must stay there, undestroyed,
// until the frame has been rendered.
fill_shape :: proc(c: ^Canvas, s: ^Shape, paint: Paint, local := TRANSFORM_IDENTITY) {
	to := transform_multiply(local, state(c).transform)
	inst := paint_instance(paint, to)
	inst.transform = transform_multiply(shape_local(s), to)
	if outside_target(c, device_bounds(s.data, inst.transform, 1 + inst.widen)) {
		return
	}
	inst.shape = s
	cmd: Command
	cmd, inst.paint = shape_paint(c, paint)
	push_shape(c, cmd, inst)
}

// `fill_shape` at each of `locals`, sharing one paint row: a shape drawn
// many times (an editor's anchors and handles) costs an instance each.
fill_shapes :: proc(c: ^Canvas, s: ^Shape, paint: Paint, locals: []Transform2D) {
	push_shapes(c, s, paint, 0, locals)
}

// Draws the outline of `s` (built with one: shape_from_path's `outline`)
// as a line `width` pixels wide under the current transform and `local`,
// whatever they scale or turn: a selection's or a handle's hairline, with
// no stroke to build. Contours the path leaves open stay open; ends and
// corners round. A pixel takes its share within width / 2 of the outline
// (cv.hairline); the paint's fill rule, anti-aliasing and feather do not
// apply. As with fill_shape, the frame keeps `s`'s address.
hairline_shape :: proc(c: ^Canvas, s: ^Shape, paint: Paint, width: f32, local := TRANSFORM_IDENTITY) {
	if width > 0 {
		local := local
		push_shapes(c, s, paint, width, ([^]Transform2D)(&local)[:1])
	}
}

// `hairline_shape` at each of `locals`, sharing one paint row.
hairline_shapes :: proc(c: ^Canvas, s: ^Shape, paint: Paint, width: f32, locals: []Transform2D) {
	if width > 0 {
		push_shapes(c, s, paint, width, locals)
	}
}

// Markers `radius` pixels (half a square's side, a circle's radius) at each
// of `points` (current units), filled, or with `outline` > 0 outlined that
// many pixels wide, whatever the transform scales or turns: an editor's
// anchors and handles. One batch, one paint: the markers are a group, so a
// pixel takes their union once (the paint shading it) and stops once it is
// covered, and each costs its pixels' closed-form coverage (cv.marker)
// where a shape costs its curves.
fill_markers :: proc(c: ^Canvas, kind: Marker_Kind, radius, outline: f32, paint: Paint, points: []Vec2) {
	if kind == .None || !(radius > 0) {
		return
	}
	cmd: Command
	row, white := max(u32), u32(0)
	t := state(c).transform
	// The target, grown by what a marker's coverage reaches past its center.
	w, h := render_target_size(c)
	reach := radius + 1 + 0.5 * max(outline, 0)
	x0, y0 := f32(c.current_render_origin.x) - reach, f32(c.current_render_origin.y) - reach
	x1, y1 := x0 + f32(w) + 2 * reach, y0 + f32(h) + 2 * reach
	start := len(c.shapes)
	for q in points {
		at := transform_point(t, q.x, q.y)
		if at.x < x0 || at.x > x1 || at.y < y0 || at.y > y1 {
			continue
		}
		if row == max(u32) {
			p := paint
			p.feather, p.fill_rule = 0, .Non_Zero
			cmd, row = shape_paint(c, p)
			white = solid_paint(c, {1, 1, 1, 1})
		}
		append(&c.shapes, Shape_Instance{transform = {radius, 0, 0, radius, at.x, at.y}, paint = white, marker = kind, hairline = max(outline, 0)})
	}
	if n := len(c.shapes) - start; n > 0 {
		push_instances(c, cmd, n, row + 1)
	}
}

// Instances of `s` at each of `locals` with one paint row: fills, or
// hairlines `hairline` pixels wide.
@(private)
push_shapes :: proc(c: ^Canvas, s: ^Shape, paint: Paint, hairline: f32, locals: []Transform2D) {
	cmd: Command
	row := max(u32)
	current := state(c).transform
	for local in locals {
		to := transform_multiply(local, current)
		inst := Shape_Instance{hairline = hairline} if hairline > 0 else paint_instance(paint, to)
		inst.transform = transform_multiply(shape_local(s), to)
		if outside_target(c, device_bounds(s.data, inst.transform, instance_reach(inst))) {
			continue
		}
		if row == max(u32) {
			pp := paint
			if hairline > 0 {
				pp.feather = 0
			}
			cmd, row = shape_paint(c, pp)
		}
		inst.shape = s
		inst.paint = row
		push_shape(c, cmd, inst)
	}
}


// Whether shapes filled with `paint` under the current state can overlap
// without showing it: opaque colours blended source-over with no global
// alpha. Otherwise a run fills as one (a group, `Cmd_Draw_Shapes.group`).
@(private)
paint_opaque :: proc(c: ^Canvas, paint: Paint) -> bool {
	st := state(c)
	if st.alpha < 1 || st.composite_operation != composite_state_from_op(.Source_Over) {
		return false
	}
	opaque :: proc(gc: Gradient_Colors) -> bool {
		switch g in gc {
		case Two_Stop_Gradient:
			return g.start_color.a >= 1 && g.end_color.a >= 1
		case Multi_Stop_Gradient:
			if g.tint < 1 {
				return false
			}
			for s in g.stops {
				if s.color.a < 1 {
					return false
				}
			}
			return true
		}
		return false
	}
	switch f in paint.flavor {
	case Paint_Color:
		return f.a >= 1
	case Paint_Image:
		return false
	case Paint_Linear_Gradient:
		return opaque(f.colors)
	case Paint_Box_Gradient:
		return opaque(f.colors)
	case Paint_Radial_Gradient:
		return opaque(f.colors)
	case Paint_Conic_Gradient:
		return opaque(f.colors)
	}
	return false
}

// The command state and paint row for shapes filled with `paint` under the
// current state; several shapes may share them.
@(private)
shape_paint :: proc(c: ^Canvas, paint: Paint) -> (cmd: Command, row: u32) {
	st := state(c)
	flavor := paint.flavor
	flavor_mul_alpha(&flavor, st.alpha)
	cmd = {
		composite_operation = st.composite_operation,
		scissor_rect        = current_scissor_rect(c),
	}
	attach_paint_image(c, &cmd, &flavor)
	params := params_from_paint(&c.images, paint_space(paint, st.transform), &flavor, st.scissor, c.fringe_width, c.fringe_width, -1)
	params.spread = f32(paint.spread)
	params.smooth_edge = paint.feather > 0
	return cmd, add_paint(c, params)
}

// `fill_shape` with a paint row from `shape_paint`.
@(private)
push_shape_at :: proc(c: ^Canvas, cmd: Command, s: ^Shape, local: Transform2D, row: u32, even_odd: bool, group: u32 = 0) {
	t := transform_multiply(shape_local(s), transform_multiply(local, state(c).transform))
	if outside_target(c, shape_device_bounds(s, t)) {
		return
	}
	push_shape(c, cmd, {shape = s, transform = t, paint = row, even_odd = even_odd}, group)
}

// Device bounds of a shape under `t` (shape units to drawing coordinates),
// grown by the pixel its edge coverage reaches.
shape_device_bounds :: proc "contextless" (s: ^Shape, t: Transform2D) -> Bounds {
	return device_bounds(s.data, t, 1)
}

// Device bounds of shape words under `t`, grown by `grow` pixels.
@(private)
device_bounds :: proc "contextless" (words: []u32, t: Transform2D, grow: f32) -> Bounds {
	x0, y0, x1, y1 := cv.bounds(words)
	b := EMPTY_BOUNDS
	for p in ([4]Vec2{{x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}}) {
		q := transform_point(t, p.x, p.y)
		b = {min(b.minx, q.x), min(b.miny, q.y), max(b.maxx, q.x), max(b.maxy, q.y)}
	}
	return {b.minx - grow, b.miny - grow, b.maxx + grow, b.maxy + grow}
}

// Appends a shape instance, extending the frame's last command when it is
// a shape draw with the same image, blend, scissor and group.
@(private)
push_shape :: proc(c: ^Canvas, base: Command, inst: Shape_Instance, group: u32 = 0) {
	append(&c.shapes, inst)
	at := u32(len(c.shapes) - 1)
	if n := len(c.commands); n > 0 {
		last := &c.commands[n - 1]
		if d, ok := &last.type.(Cmd_Draw_Shapes); ok && d.instances.start + d.instances.count == at && d.group == group && last.image == base.image && last.composite_operation == base.composite_operation && last.scissor_rect == base.scissor_rect {
			d.instances.count += 1
			return
		}
	}
	cmd := base
	cmd.type = Cmd_Draw_Shapes{{at, 1}, group}
	append(&c.commands, cmd)
}

// `push_shape` for the last `n` instances appended at once.
@(private)
push_instances :: proc(c: ^Canvas, base: Command, n: int, group: u32 = 0) {
	at := u32(len(c.shapes) - n)
	if k := len(c.commands); k > 0 {
		last := &c.commands[k - 1]
		if d, ok := &last.type.(Cmd_Draw_Shapes); ok && d.instances.start + d.instances.count == at && d.group == group && last.image == base.image && last.composite_operation == base.composite_operation && last.scissor_rect == base.scissor_rect {
			d.instances.count += u32(n)
			return
		}
	}
	cmd := base
	cmd.type = Cmd_Draw_Shapes{{at, u32(n)}, group}
	append(&c.commands, cmd)
}

// Strokes `p` with `paint`: the stroke's outline (stroke.odin) filled by
// coverage like fill_path, each pixel once however the stroke overlaps
// itself.
stroke_path :: proc(c: ^Canvas, p: ^Path, paint: Paint) {
	t := state(c).transform
	scale := transform_average_scale(t)
	if scale <= 0 {
		return
	}
	b := &c.scratch.builder
	shape_builder_reset(b)
	b.tol = 1.0 / 16
	if !stroke_add(&c.scratch, p, t, paint.stroke, b.tol / scale, c.limits[.Dash_Segments]) {
		c.limited += {.Dash_Segments}
	}
	fill := paint
	fill.fill_rule = .Non_Zero
	fill_built(c, fill, t)
}

// Adds a paint row to the frame and returns its index.
@(private)
add_paint :: proc(c: ^Canvas, params: Params) -> u32 {
	append(&c.paints, params)
	return u32(len(c.paints) - 1)
}

// A paint row of one premultiplied colour, unscissored: a group's white
// instances or its opacity.
@(private)
solid_paint :: proc(c: ^Canvas, color: [4]f32) -> u32 {
	params := default_params()
	params.shader_type = .Fill_Color
	params.inner_col = color
	params.outer_col = color
	params.stroke_mult = 1
	params.stroke_thr = -1
	return add_paint(c, params)
}

@(private)
attach_paint_image :: proc(c: ^Canvas, cmd: ^Command, flavor: ^Paint_Flavor) {
	if img, ok := flavor.(Paint_Image); ok {
		cmd.image = img.id
		return
	}
	if gc := flavor_gradient_colors(flavor); gc != nil {
		if ms, ok := gc.(Multi_Stop_Gradient); ok {
			if id, err := gradient_store_lookup_or_add(&c.gradients, ms, &c.images); err == nil {
				cmd.image = id
			}
		}
	}
}

// ---- marks ----------------------------------------------------------------------

// The lengths of the frame being recorded: what was recorded after a mark
// can be found (layers size themselves from it) or dropped.
Canvas_Mark :: struct {
	commands: int,
	paints:   int,
	bytes:    int,
	filters:  int,
	runs:     int,
	shapes:   int,
	words:    int,
}

canvas_mark :: proc "contextless" (c: ^Canvas) -> Canvas_Mark {
	return {len(c.commands), len(c.paints), len(c.bytes), len(c.filters), len(c.runs), len(c.shapes), len(c.shape_words)}
}

// Drops everything recorded since `m`. The render target must be the one
// that was current at the mark.
canvas_truncate :: proc(c: ^Canvas, m: Canvas_Mark) {
	// Shrinking keeps the capacity.
	resize(&c.commands, m.commands)
	resize(&c.paints, m.paints)
	resize(&c.bytes, m.bytes)
	resize(&c.filters, m.filters)
	resize(&c.runs, m.runs)
	resize(&c.shapes, m.shapes)
	resize(&c.shape_words, m.words)
}

// ---- flush ----------------------------------------------------------------------

// Renders the recorded frame and clears it. `output` is backend-specific
// (for SDL_GPU, an `Output` texture; 0 renders offscreen).
flush :: proc(c: ^Canvas, output: Render_Output = 0) {
	assert(!c.images.recording, "a recording canvas hands frames over with canvas_take")
	c.backend.render(c.backend.data, output, &c.images, canvas_frame(c))
	clear(&c.commands)
	clear(&c.bytes)
	clear(&c.filters)
	clear(&c.runs)
	clear(&c.paints)
	clear(&c.shapes)
	clear(&c.shape_words)
	frame_end(c)
}

// The frame recorded so far, as `flush` hands it over.
@(private)
canvas_frame :: proc "contextless" (c: ^Canvas) -> Frame {
	return {paints = c.paints[:], commands = c.commands[:], bytes = c.bytes[:], filters = c.filters[:], runs = c.runs[:], shapes = c.shapes[:], shape_words = c.shape_words[:]}
}

@(private)
frame_end :: proc(c: ^Canvas) {
	gradient_store_release_old(&c.gradients, &c.images)
	// The backend starts every frame on the screen; keep the canvas in sync.
	c.current_render_target = nil
	c.current_render_origin = {}
}

// A frame recorded on a recording canvas, handed whole to a `Player`: what
// `flush` gives a backend, plus the image and program work logged since the
// previous frame. Flat arrays, reused frame after frame.
Recorded_Frame :: struct {
	width:       u32,
	height:      u32,
	dpi:         f32,
	paints:      [dynamic]Params,
	commands:    [dynamic]Command,
	bytes:       [dynamic]u8,
	filters:     [dynamic]Image_Filter,
	runs:        [dynamic]Program_Run,
	shapes:      [dynamic]Shape_Instance,
	shape_words: [dynamic]u32,
	image_ops:   [dynamic]Image_Op,
	pixels:      [dynamic]u8,
	program_ops: [dynamic]Program_Op,
}

recorded_frame_destroy :: proc(f: ^Recorded_Frame) {
	delete(f.paints)
	delete(f.commands)
	delete(f.bytes)
	delete(f.filters)
	delete(f.runs)
	delete(f.shapes)
	delete(f.shape_words)
	delete(f.image_ops)
	delete(f.pixels)
	delete(f.program_ops)
	f^ = {}
}

// Ends the frame on a recording canvas like `flush`, moving it into `out`
// instead of rendering it. The arrays swap, so both keep their capacity.
canvas_take :: proc(c: ^Canvas, out: ^Recorded_Frame) {
	assert(c.images.recording)
	out.width, out.height, out.dpi = c.width, c.height, c.device_px_ratio
	// A frame's arrays not yet made take the canvas's allocator, so the
	// canvas never draws into memory of whatever allocator its first frame
	// happened to run under.
	swap_clear :: proc(a, b: ^[dynamic]$T) {
		if b.allocator.procedure == nil {
			b.allocator = a.allocator
		}
		a^, b^ = b^, a^
		clear(a)
	}
	swap_clear(&c.paints, &out.paints)
	swap_clear(&c.commands, &out.commands)
	swap_clear(&c.bytes, &out.bytes)
	swap_clear(&c.filters, &out.filters)
	swap_clear(&c.runs, &out.runs)
	swap_clear(&c.shapes, &out.shapes)
	swap_clear(&c.shape_words, &out.shape_words)
	swap_clear(&c.images.ops, &out.image_ops)
	swap_clear(&c.images.pixels, &out.pixels)
	swap_clear(&c.program_ops, &out.program_ops)
	frame_end(c)
}

// Copy of the screen as RGBA8, top-down. Call after `flush`.
screenshot :: proc(c: ^Canvas, allocator := context.allocator) -> (Screenshot, Error) {
	// A recording canvas renders nothing (its player does).
	if c.backend.screenshot == nil {
		return {}, .Unsupported_Operation
	}
	return c.backend.screenshot(c.backend.data, allocator)
}

// ---- shader parameters ------------------------------------------------------------

// Builds the uniforms for one draw from the paint and global state. Port of
// femtovg's `Params::new`.
params_from_paint :: proc(
	images: ^Image_Store,
	global_transform: Transform2D,
	flavor: ^Paint_Flavor,
	scissor: Scissor,
	stroke_width: f32,
	fringe_width: f32,
	stroke_thr: f32,
) -> Params {
	p := default_params()

	if scissor.has_extent && scissor.extent[0] >= -0.5 && scissor.extent[1] >= -0.5 {
		m := scissor.transform
		p.scissor_mat = transform_to_mat3x4(transform_inverse(m))
		p.scissor_ext = scissor.extent
		p.scissor_scale = {math.hypot(m[0], m[2]) / fringe_width, math.hypot(m[1], m[3]) / fringe_width}
	}

	p.stroke_mult = (stroke_width * 0.5 + fringe_width * 0.5) / fringe_width
	p.stroke_thr = stroke_thr

	inv := TRANSFORM_IDENTITY
	switch f in flavor {
	case Paint_Color:
		pm := color_to_array(premultiplied(f))
		p.inner_col = pm
		p.outer_col = pm
		p.shader_type = .Fill_Color
		inv = transform_inverse(global_transform)
	case Paint_Image:
		info, ok := image_store_info(images, f.id)
		if !ok {
			return p
		}
		p.extent = {f.width, f.height}
		pm := color_to_array(premultiplied(f.tint))
		p.inner_col = pm
		p.outer_col = pm
		t := transform_rotation(f.angle)
		t[4] += f.x
		t[5] += f.y
		t = transform_multiply(t, global_transform)
		if .Flip_Y in info.flags {
			m := transform_multiply(transform_translation(0, f.height * 0.5), t)
			m = transform_multiply(transform_scaling(1, -1), m)
			m = transform_multiply(transform_translation(0, -f.height * 0.5), m)
			inv = transform_inverse(m)
		} else {
			inv = transform_inverse(t)
		}
		p.shader_type = .Fill_Image
		p.tex_type = tex_type_for(info)
	case Paint_Linear_Gradient:
		LARGE :: 1e5
		dx := f.end.x - f.start.x
		dy := f.end.y - f.start.y
		d := math.hypot(dx, dy)
		if d > 0.0001 {
			dx /= d
			dy /= d
		} else {
			dx, dy = 0, 1
		}
		t := Transform2D{dy, -dx, dx, dy, f.start.x - dx * LARGE, f.start.y - dy * LARGE}
		inv = transform_inverse(transform_multiply(t, global_transform))
		p.extent = {LARGE, LARGE + d * 0.5}
		// In paint units, which a paint transform may scale (SVG
		// objectBoundingBox): no one-unit minimum.
		p.feather = max(d, 1e-6)
		apply_gradient_colors(&p, f.colors, false)
	case Paint_Box_Gradient:
		t := transform_translation(f.pos.x + f.width * 0.5, f.pos.y + f.height * 0.5)
		inv = transform_inverse(transform_multiply(t, global_transform))
		p.extent = {f.width * 0.5, f.height * 0.5}
		p.radius = f.radius
		p.feather = f.feather
		apply_gradient_colors(&p, f.colors, false)
	case Paint_Radial_Gradient:
		t := transform_translation(f.center.x, f.center.y)
		inv = transform_inverse(transform_multiply(t, global_transform))
		if f.focal != {} {
			p.extent = {f.out_radius, f.in_radius}
			p.focal = {1, f.focal.x, f.focal.y}
		} else {
			r := (f.in_radius + f.out_radius) * 0.5
			fe := f.out_radius - f.in_radius
			p.extent = {r, r}
			p.radius = r
			p.feather = max(fe, 1e-6)
		}
		apply_gradient_colors(&p, f.colors, false)
	case Paint_Conic_Gradient:
		t := transform_translation(f.center.x, f.center.y)
		inv = transform_inverse(transform_multiply(t, global_transform))
		apply_gradient_colors(&p, f.colors, true)
	}
	p.paint_mat = transform_to_mat3x4(inv)
	return p
}

// How the shader converts a texel: 0 = premultiplied RGBA, 1 = straight
// RGBA, 2 = single channel replicated to all four.
tex_type_for :: proc "contextless" (info: Image_Info) -> f32 {
	switch info.format {
	case .RGBA8:
		return 0 if .Premultiplied in info.flags else 1
	case .Gray8, .Gray16:
		return 2
	case .RGB8, .RGBA16F:
		return 0
	}
	return 0
}

@(private)
apply_gradient_colors :: proc "contextless" (p: ^Params, gc: Gradient_Colors, conic: bool) {
	switch g in gc {
	case Two_Stop_Gradient:
		p.inner_col = color_to_array(premultiplied(g.start_color))
		p.outer_col = color_to_array(premultiplied(g.end_color))
		p.shader_type = .Fill_Gradient_Conic if conic else .Fill_Gradient
	case Multi_Stop_Gradient:
		// The ramp holds the stops alone (one per stop list, however the
		// paint fades); the alpha multiplies it here.
		p.inner_col = {g.tint, g.tint, g.tint, g.tint}
		p.outer_col = p.inner_col
		p.shader_type = .Fill_Image_Gradient_Conic if conic else .Fill_Image_Gradient
	}
}

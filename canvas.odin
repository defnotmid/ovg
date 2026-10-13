package ovg

import "core:math"
import "core:mem"

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
	verts:                 [dynamic]Vertex,
	pieces:                [dynamic]Piece,
	paints:                [dynamic]Params,
	// Uniform blocks of custom program runs (program.odin).
	bytes:                 [dynamic]u8,
	filters:               [dynamic]Image_Filter,
	runs:                  [dynamic]Program_Run,
	images:                Image_Store,
	programs:              Slot_Map(Backend_Program),
	gradients:             Gradient_Store,
	fringe_width:          f32,
	device_px_ratio:       f32,
	tess_tol:              f32,
	dist_tol:              f32,
	// Dashed copy of the path being stroked.
	dash_scratch:          Path,
	// The stroke being dashed, flattened.
	dash_flat:             Flat_Path,
	// The path being drawn, tessellated (`tessellate`).
	tess:                  Tessellation,
	// Bounds on per-draw work (limits.odin); canvas_init sets
	// DEFAULT_LIMITS. Dashes use Dash_Segments.
	limits:                Limits,
	// The limits reached since init (clear it to watch again).
	limited:               bit_set[Limit],
	// Caps of zero-length subpaths (round / square dots).
	cap_scratch:           Path,
	// Programs registered on a recording canvas, for the player to create.
	program_ops:           [dynamic]Program_Op,
}

canvas_init :: proc(c: ^Canvas, backend: Backend, allocator := context.allocator) {
	c^ = {
		allocator       = allocator,
		backend         = backend,
		states          = make([dynamic]State, allocator),
		commands        = make([dynamic]Command, allocator),
		verts           = make([dynamic]Vertex, allocator),
		pieces          = make([dynamic]Piece, allocator),
		paints          = make([dynamic]Params, allocator),
		bytes           = make([dynamic]u8, allocator),
		limits          = DEFAULT_LIMITS,
		fringe_width    = 1,
		device_px_ratio = 1,
		tess_tol        = 0.25,
		dist_tol        = 0.01,
	}
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
	delete(c.verts)
	delete(c.pieces)
	delete(c.paints)
	delete(c.bytes)
	delete(c.filters)
	delete(c.runs)
	programs_destroy(c)
	image_store_destroy(&c.images)
	gradient_store_destroy(&c.gradients)
	path_destroy(&c.dash_scratch)
	flat_path_destroy(&c.dash_flat)
	tessellation_destroy(&c.tess)
	path_destroy(&c.cap_scratch)
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
	c.tess_tol = 0.25 / dpi
	c.dist_tol = 0.01 / dpi
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

@(private)
// Tessellates `p` under `t` into the canvas's scratch, valid until the next
// call.
tessellate :: proc(c: ^Canvas, p: ^Path, t: Transform2D) -> ^Tessellation {
	tessellation_build(&c.tess, p, t, c.tess_tol, c.dist_tol)
	return &c.tess
}

contains_point :: proc(c: ^Canvas, p: ^Path, x, y: f32, rule: Fill_Rule) -> bool {
	cache := tessellate(c, p, state(c).transform)
	b := cache.bounds
	if b.maxx < 0 || b.minx > f32(c.width) || b.maxy < 0 || b.miny > f32(c.height) {
		return false
	}
	return tessellation_contains_point(cache, x, y, rule)
}

// Bounds of the path under the current transform.
path_bounds :: proc(c: ^Canvas, p: ^Path) -> Bounds {
	return tessellate(c, p, state(c).transform).bounds
}

@(private)
outside_target :: proc(c: ^Canvas, b: Bounds) -> bool {
	w, h := render_target_size(c)
	x, y := f32(c.current_render_origin.x), f32(c.current_render_origin.y)
	return b.maxx < x || b.minx > x + f32(w) || b.maxy < y || b.miny > y + f32(h)
}

fill_path :: proc(c: ^Canvas, p: ^Path, paint: Paint) {
	st := state(c)
	t := st.transform
	cache := tessellate(c, p, t)
	if outside_target(c, cache.bounds) {
		return
	}

	flavor := paint.flavor
	flavor_mul_alpha(&flavor, st.alpha)

	fringe := c.fringe_width if paint.anti_alias else 0
	if paint.feather > 0 {
		// The fringe straddles the edge: at most the shape's smaller extent,
		// so the inner edge does not cross over.
		scale := math.sqrt(abs(t[0] * t[3] - t[1] * t[2]))
		b := cache.bounds
		fringe = min(c.fringe_width + 1.5 * paint.feather * scale * math.SQRT_TWO * math.sqrt(f32(math.PI)), min(b.maxx - b.minx, b.maxy - b.miny))
	}
	tessellation_fill(cache, fringe, .Miter, 2.4)
	convex := len(cache.contours) == 1 && cache.contours[0].convexity == .Convex

	cmd := Command {
		composite_operation = st.composite_operation,
		scissor_rect        = current_scissor_rect(c),
	}
	attach_paint_image(c, &cmd, &flavor)
	params := params_from_paint(&c.images, paint_space(paint, t), &flavor, {}, st.scissor, c.fringe_width, c.fringe_width, -1)
	params.spread = f32(paint.spread)
	params.smooth_edge = paint.feather > 0
	fill := add_paint(c, params)
	if convex {
		start := len(c.pieces)
		for ct in cache.contours {
			emit_list(c, cache.fill_verts[ct.fill.start:][:ct.fill.count], fill)
			emit_strip(c, cache.stroke_verts[ct.stroke.start:][:ct.stroke.count], fill)
		}
		push_draw(c, cmd, .None, fill, start)
		return
	}

	// Winding count from the fan triangles (no color, so the fill's paint
	// serves), the fringe outside the shape, then cover the path bounds
	// where the count is set (zeroing it).
	even_odd := paint.fill_rule == .Even_Odd
	start := len(c.pieces)
	for ct in cache.contours {
		emit_list(c, cache.fill_verts[ct.fill.start:][:ct.fill.count], fill)
	}
	push_draw(c, cmd, .Winding, fill, start)
	start = len(c.pieces)
	for ct in cache.contours {
		emit_strip(c, cache.stroke_verts[ct.stroke.start:][:ct.stroke.count], fill)
	}
	push_draw(c, cmd, .Outside_Even_Odd if even_odd else .Outside_Non_Zero, fill, start)
	b := cache.bounds
	x0, y0, x1, y1 := b.minx - fringe, b.miny - fringe, b.maxx + fringe, b.maxy + fringe
	start = len(c.pieces)
	emit_list(c, {{x0, y0, 0.5, 1}, {x1, y0, 0.5, 1}, {x1, y1, 0.5, 1}, {x0, y0, 0.5, 1}, {x1, y1, 0.5, 1}, {x0, y1, 0.5, 1}}, fill)
	push_draw(c, cmd, .Cover_Even_Odd if even_odd else .Cover_Non_Zero, fill, start)
}

stroke_path :: proc(c: ^Canvas, p: ^Path, paint: Paint) {
	p := p
	if len(paint.stroke.dash) > 0 {
		// Dash in path units, before the transform (SVG).
		path_reset(&c.dash_scratch)
		if !path_dash(p, paint.stroke.dash, paint.stroke.dash_offset, paint.stroke.path_length, &c.dash_scratch, &c.dash_flat, c.limits[.Dash_Segments]) {
			c.limited += {.Dash_Segments}
		}
		p = &c.dash_scratch
	}
	if paint.stroke.line_cap_start != .Butt || paint.stroke.line_cap_end != .Butt {
		stroke_zero_length_caps(c, p, paint)
	}
	st := state(c)
	t := st.transform
	cache := tessellate(c, p, t)
	if outside_target(c, cache.bounds) {
		return
	}

	flavor := paint.flavor
	line_width := max(paint.stroke.line_width * transform_average_scale(t), 0)
	if line_width < c.fringe_width {
		// Thinner than a pixel: keep the width and fade out instead, which
		// preserves apparent coverage. Linear in the width (femtovg's fix of
		// nanovg's squared fade): a 0.5 px line is half covered, as in
		// Skia's hairlines and the browsers.
		a := clamp(line_width / c.fringe_width, 0, 1)
		flavor_mul_alpha(&flavor, a)
		line_width = c.fringe_width
	}
	flavor_mul_alpha(&flavor, st.alpha)

	fringe := c.fringe_width if paint.anti_alias else 0
	tessellation_stroke(
		cache,
		line_width * 0.5,
		fringe,
		paint.stroke.line_cap_start,
		paint.stroke.line_cap_end,
		paint.stroke.line_join,
		paint.stroke.miter_limit,
		c.tess_tol,
	)

	cmd := Command {
		composite_operation = st.composite_operation,
		scissor_rect        = current_scissor_rect(c),
	}
	attach_paint_image(c, &cmd, &flavor)
	params := params_from_paint(&c.images, paint_space(paint, t), &flavor, {}, st.scissor, line_width, c.fringe_width, -1)
	params.spread = f32(paint.spread)
	stroke := add_paint(c, params)
	start := len(c.pieces)
	for ct in cache.contours {
		emit_strip(c, cache.stroke_verts[ct.stroke.start:][:ct.stroke.count], stroke)
	}
	if !paint.stroke.stencil_strokes {
		push_draw(c, cmd, .None, stroke, start)
		return
	}
	// Each pixel once (overlapping parts of a translucent stroke do not
	// darken), then zero the stencil over the same pieces.
	push_draw(c, cmd, .Once, stroke, start)
	push_draw(c, cmd, .Clear, stroke, start)
}

// Zero-length subpaths ("M p L p", "M p Z", zero dashes) have no stroke
// geometry, but round and square caps still draw a dot there (SVG).
@(private)
stroke_zero_length_caps :: proc(c: ^Canvas, p: ^Path, paint: Paint) {
	t := state(c).transform
	tol := c.dist_tol / max(transform_average_scale(t), 1e-6)
	dots := &c.cap_scratch
	path_reset(dots)
	hw := paint.stroke.line_width * 0.5
	caps := [2]Line_Cap{paint.stroke.line_cap_start, paint.stroke.line_cap_end}
	start, last, dir: Vec2
	length: f32
	open, has_seg := false, false
	// The dot is the start cap behind the subpath's direction and the end
	// cap ahead of it, each its own style.
	finish :: proc(dots: ^Path, open, has_seg: bool, length, tol: f32, at, dir: Vec2, hw: f32, caps: [2]Line_Cap) {
		if !open || !has_seg || length > tol {
			return
		}
		if caps == {.Round, .Round} {
			path_circle(dots, at.x, at.y, hw)
			return
		}
		d := dir if dir != {} else Vec2{1, 0}
		n := Vec2{-d.y, d.x}
		// One cap's half, from `at + from * hw` round to `at - from * hw`
		// on the `side` half-plane.
		half :: proc(dots: ^Path, at, from, side: Vec2, hw: f32, cap: Line_Cap) {
			switch cap {
			case .Butt:
			case .Square:
				for q in ([2]Vec2{at + (from + side) * hw, at + (side - from) * hw}) {
					path_line_to(dots, q.x, q.y)
				}
			case .Round:
				// Half a circle from `from` through `side` (path_arc: .Hole
				// sweeps to larger angles).
				a0 := math.atan2(from.y, from.x)
				up := from.x * side.y - from.y * side.x > 0
				path_arc(dots, at.x, at.y, hw, a0, a0 + (math.PI if up else -math.PI), .Hole if up else .Solid)
			}
			e := at - from * hw
			path_line_to(dots, e.x, e.y)
		}
		s := at + n * hw
		path_move_to(dots, s.x, s.y)
		half(dots, at, n, d, hw, caps[1])
		half(dots, at, -n, -d, hw, caps[0])
		path_close(dots)
	}
	it := path_iter(p)
	for verb, coords in path_iter_next(&it) {
		switch verb {
		case .Move_To:
			finish(dots, open, has_seg, length, tol, start, dir, hw, caps)
			start, last = coords[0], coords[0]
			length, dir = 0, {}
			open, has_seg = true, false
		case .Line_To, .Bezier_To:
			to := coords[len(coords) - 1]
			d := coords[0] - last
			if l := math.hypot(d.x, d.y); l > 0 && dir == {} {
				dir = d / l
			}
			for q in coords {
				e := q - last
				length += math.hypot(e.x, e.y)
				last = q
			}
			last = to
			has_seg = true
		case .Close:
			has_seg = true
			finish(dots, open, has_seg, length, tol, start, dir, hw, caps)
			open = false
		case .Solid, .Hole:
		}
	}
	finish(dots, open, has_seg, length, tol, start, dir, hw, caps)
	if len(dots.verbs) == 0 {
		return
	}
	fill := paint
	fill.fill_rule = .Non_Zero
	fill.stroke.dash = nil
	fill_path(c, dots, fill)
}

// Adds a paint row to the frame and returns its index.
@(private)
add_paint :: proc(c: ^Canvas, params: Params) -> u32 {
	append(&c.paints, params)
	return u32(len(c.paints) - 1)
}

// Appends `src` painted with `paint` as one piece: a triangle list, or a
// strip.
@(private)
emit_piece :: proc(c: ^Canvas, src: []Path_Vertex, paint: u32, strip: bool) {
	if len(src) < 3 {
		return
	}
	base := len(c.verts)
	// Every new vertex is written below: no zeroing first.
	non_zero_resize(&c.verts, base + len(src))
	for v, i in src {
		c.verts[base + i] = vertex(v.x, v.y, v.u, v.v, paint)
	}
	append(&c.pieces, Piece{{u32(base), u32(len(src))}, strip})
}

@(private)
emit_list :: #force_inline proc(c: ^Canvas, src: []Path_Vertex, paint: u32) {
	emit_piece(c, src, paint, false)
}

@(private)
emit_strip :: #force_inline proc(c: ^Canvas, src: []Path_Vertex, paint: u32) {
	emit_piece(c, src, paint, true)
}

// A draw of the pieces from `start` to the end of the frame's, under
// `stencil`; none when there are none.
@(private)
push_draw :: proc(c: ^Canvas, base: Command, stencil: Stencil_Mode, paint: u32, start: int) {
	if len(c.pieces) == start {
		return
	}
	cmd := base
	cmd.type = Cmd_Draw{stencil, paint}
	cmd.pieces = {u32(start), u32(len(c.pieces) - start)}
	append(&c.commands, cmd)
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
	verts:    int,
	pieces:   int,
	paints:   int,
	bytes:    int,
	filters:  int,
	runs:     int,
}

canvas_mark :: proc "contextless" (c: ^Canvas) -> Canvas_Mark {
	return {len(c.commands), len(c.verts), len(c.pieces), len(c.paints), len(c.bytes), len(c.filters), len(c.runs)}
}

// Drops everything recorded since `m`. The render target must be the one
// that was current at the mark.
canvas_truncate :: proc(c: ^Canvas, m: Canvas_Mark) {
	// Shrinking keeps the capacity.
	resize(&c.commands, m.commands)
	resize(&c.verts, m.verts)
	resize(&c.pieces, m.pieces)
	resize(&c.paints, m.paints)
	resize(&c.bytes, m.bytes)
	resize(&c.filters, m.filters)
	resize(&c.runs, m.runs)
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
	clear(&c.verts)
	clear(&c.pieces)
	clear(&c.paints)
	frame_end(c)
}

// The frame recorded so far, as `flush` hands it over.
@(private)
canvas_frame :: proc "contextless" (c: ^Canvas) -> Frame {
	return {c.verts[:], c.pieces[:], c.paints[:], c.commands[:], c.bytes[:], c.filters[:], c.runs[:]}
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
	verts:       [dynamic]Vertex,
	pieces:      [dynamic]Piece,
	paints:      [dynamic]Params,
	commands:    [dynamic]Command,
	bytes:       [dynamic]u8,
	filters:     [dynamic]Image_Filter,
	runs:        [dynamic]Program_Run,
	image_ops:   [dynamic]Image_Op,
	pixels:      [dynamic]u8,
	program_ops: [dynamic]Program_Op,
}

recorded_frame_destroy :: proc(f: ^Recorded_Frame) {
	delete(f.verts)
	delete(f.pieces)
	delete(f.paints)
	delete(f.commands)
	delete(f.bytes)
	delete(f.filters)
	delete(f.runs)
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
	swap_clear :: proc(a, b: ^[dynamic]$T) {
		a^, b^ = b^, a^
		clear(a)
	}
	swap_clear(&c.verts, &out.verts)
	swap_clear(&c.pieces, &out.pieces)
	swap_clear(&c.paints, &out.paints)
	swap_clear(&c.commands, &out.commands)
	swap_clear(&c.bytes, &out.bytes)
	swap_clear(&c.filters, &out.filters)
	swap_clear(&c.runs, &out.runs)
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
	glyph_texture: Glyph_Texture,
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
	p.glyph_texture_type = u8(glyph_texture.kind)

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

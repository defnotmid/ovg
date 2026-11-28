package ovg

import "core:math"

// A Scene recorded onto a canvas, through its layer stack, so that either
// backend draws it with today's machinery (docs/scene.md, staging step 4).
// What this path can't yet draw exactly is rejected whole, before anything
// is recorded, rather than drawn approximately: groups that are knockout or
// not isolated, layer filters, transfer tables, a mask backdrop other than
// black, pattern paints, motion, and a Porter-Duff operation on a layer.
//
// Masks are drawn again for each reader here, and clips by path are layers;
// rendering each mask once and clipping by coverage are the compile steps
// that come next. The result is the same.

// What recording a scene works in, kept by the caller across scenes, and
// the per-render images and shapes it made, released by
// `scene_renderer_release` once the canvas has flushed.
Scene_Renderer :: struct {
	path:      Path,
	glyph:     Path,
	clip:      Path,
	paths:     [dynamic]Path,
	operands:  [dynamic]Bool_Operand,
	booleans:  Bool_Scratch,
	images:    [dynamic]Image_Id,
	made:      [dynamic]Image_Id,
	shapes:    [dynamic]Shape,
	rgba:      [dynamic]u8,
	// Per open Layer_Push, the mask its pop draws (0: none).
	layer_masks: [dynamic]Mask_Id,
	// Per open push, whether it pushed a layer (true) or saved a scissor.
	pushed_layer: [dynamic]bool,
}

scene_renderer_init :: proc(r: ^Scene_Renderer, allocator := context.allocator) {
	path_init(&r.path, allocator)
	path_init(&r.glyph, allocator)
	path_init(&r.clip, allocator)
	r.paths = make([dynamic]Path, allocator)
	r.operands = make([dynamic]Bool_Operand, allocator)
	r.images = make([dynamic]Image_Id, allocator)
	r.made = make([dynamic]Image_Id, allocator)
	r.shapes = make([dynamic]Shape, allocator)
	r.rgba = make([dynamic]u8, allocator)
	r.layer_masks = make([dynamic]Mask_Id, allocator)
	r.pushed_layer = make([dynamic]bool, allocator)
}

scene_renderer_destroy :: proc(r: ^Scene_Renderer, c: ^Canvas) {
	scene_renderer_release(r, c)
	path_destroy(&r.path)
	path_destroy(&r.glyph)
	path_destroy(&r.clip)
	for &p in r.paths {
		path_destroy(&p)
	}
	delete(r.paths)
	delete(r.operands)
	bool_scratch_destroy(&r.booleans)
	delete(r.images)
	delete(r.made)
	delete(r.shapes)
	delete(r.rgba)
	delete(r.layer_masks)
	delete(r.pushed_layer)
}

// Frees what recording a scene made for one render (images for borrowed
// views, hairline outlines): call it after the canvas has flushed.
scene_renderer_release :: proc(r: ^Scene_Renderer, c: ^Canvas) {
	for id in r.made {
		delete_image(c, id)
	}
	clear(&r.made)
	for &s in r.shapes {
		shape_destroy(&s)
	}
	clear(&r.shapes)
}

// Checks `s`, then records it onto `c` through `ls` (begun and ended here,
// over the canvas's size). On a problem nothing is recorded and the first
// one is returned.
scene_record :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, s: ^Scene) -> Scene_Problem {
	if p := scene_check(s); p.error != .None {
		return p
	}
	if p := scene_record_supported(s); p.error != .None {
		return p
	}
	// Images: a store image as it is; a view uploaded for this render.
	clear(&r.images)
	for img in s.images {
		switch v in img {
		case Image_Id:
			append(&r.images, v)
		case Pixel_View:
			append(&r.images, scene_upload(r, c, v))
		}
	}
	// A blend mode reads the target as an image: then the frame is drawn
	// in a root layer.
	root := false
	for d in s.draws {
		#partial switch v in d {
		case Scene_Fill:
			root ||= v.blend.mode != .Normal
		case Scene_Stroke:
			root ||= v.blend.mode != .Normal
		case Scene_Glyphs:
			root ||= v.blend.mode != .Normal
		case Layer_Push:
			root ||= v.blend.mode != .Normal
		}
	}
	layer_stack_begin(ls, c, c.width, c.height, nil, root)
	save(c)
	clear(&r.layer_masks)
	clear(&r.pushed_layer)
	scene_record_range(r, c, ls, s, s.main)
	restore(c)
	layer_stack_end(ls, c)
	return {}
}

// Rejects, whole, what this recording can't draw exactly yet.
@(private = "file")
scene_record_supported :: proc(s: ^Scene) -> Scene_Problem {
	look :: proc(s: ^Scene, l: Scene_Look) -> bool {
		if l.motion != 0 {
			return false
		}
		_, pattern := s.paints[l.paint - 1].(Scene_Pattern_Paint)
		return !pattern
	}
	for d, k in s.draws {
		ok := true
		#partial switch v in d {
		case Scene_Fill:
			ok = look(s, v.look)
		case Scene_Stroke:
			ok = look(s, v.look)
		case Scene_Glyphs:
			// A run composites as a group: through a layer, which takes no
			// Porter-Duff operation yet.
			ok = look(s, v.look) && v.blend.op == .Source_Over
		case Layer_Push:
			ok = v.isolated && !v.knockout && v.filters.count == 0 && v.blend.op == .Source_Over
		}
		if !ok {
			return {.Unsupported, .Draws, k}
		}
	}
	for m, i in s.masks {
		black := m.backdrop == {} || m.backdrop == {0, 0, 0, 1}
		if m.lut != 0 || (m.read != .Alpha && !black) {
			return {.Unsupported, .Masks, i}
		}
	}
	return {}
}

// A borrowed view as an image of this render, in the format it says.
@(private = "file")
scene_upload :: proc(r: ^Scene_Renderer, c: ^Canvas, v: Pixel_View) -> Image_Id {
	src := Image_Source{width = v.width, height = v.height, data = v.data, row_stride = v.stride}
	flags: Image_Flags
	switch v.format {
	case .RGBA8_Premul:
		src.format = .RGBA8
		flags = {.Premultiplied}
	case .RGBA8_Straight:
		src.format = .RGBA8
	case .Alpha8:
		// Gray8 samples as (1, 1, 1, g): a stencil.
		src.format = .Gray8
	case .Luma8:
		// (g, g, g, 1), as opaque RGBA.
		resize(&r.rgba, int(v.width * v.height * 4))
		stride := int(v.stride) if v.stride != 0 else int(v.width)
		for y in 0 ..< int(v.height) {
			for x in 0 ..< int(v.width) {
				g := v.data[y * stride + x]
				o := (y * int(v.width) + x) * 4
				r.rgba[o], r.rgba[o + 1], r.rgba[o + 2], r.rgba[o + 3] = g, g, g, 255
			}
		}
		src = image_source_rgba(r.rgba[:], v.width, v.height)
		flags = {.Premultiplied}
	case .RGBA16F:
		src.format = .RGBA16F
		flags = {.Premultiplied}
	}
	id, err := create_image(c, src, flags)
	if err != nil {
		return {}
	}
	append(&r.made, id)
	return id
}

@(private = "file")
scene_color :: proc "contextless" (premul: [4]f32) -> Color {
	a := premul[3]
	if a <= 0 {
		return {}
	}
	return {premul[0] / a, premul[1] / a, premul[2] / a, a}
}

// Scene path `id` into `out`, its points mapped by `t`.
@(private = "file")
scene_path_into :: proc(s: ^Scene, id: Path_Id, out: ^Path, t := TRANSFORM_IDENTITY) {
	path_reset(out)
	sp := s.paths[id - 1]
	pts := s.points[sp.points.start:][:sp.points.count]
	at := 0
	tp :: proc "contextless" (t: Transform2D, p: Vec2) -> Vec2 {
		return transform_point(t, p.x, p.y)
	}
	for v in s.verbs[sp.verbs.start:][:sp.verbs.count] {
		switch v {
		case .Move:
			q := tp(t, pts[at])
			path_move_to(out, q.x, q.y)
		case .Line:
			q := tp(t, pts[at])
			path_line_to(out, q.x, q.y)
		case .Quad:
			a, b := tp(t, pts[at]), tp(t, pts[at + 1])
			path_quad_to(out, a.x, a.y, b.x, b.y)
		case .Cubic:
			a, b, e := tp(t, pts[at]), tp(t, pts[at + 1]), tp(t, pts[at + 2])
			path_bezier_to(out, a.x, a.y, b.x, b.y, e.x, e.y)
		case .Close:
			path_close(out)
		}
		at += path_verb_points(v)
	}
}

// A Scene paint as a canvas paint for a draw under `draw` (its geometry's
// transform to the device): the paint's own transform, then back into the
// draw's space.
@(private = "file")
scene_canvas_paint :: proc(r: ^Scene_Renderer, s: ^Scene, id: Paint_Id, draw: Transform2D) -> Paint {
	into :: proc(s: ^Scene, t: Transform_Id, draw: Transform2D) -> Transform2D {
		return transform_multiply(s.transforms[t - 1], transform_inverse(draw))
	}
	p: Paint
	switch v in s.paints[id - 1] {
	case Scene_Solid:
		p = paint_color(scene_color(v.color))
	case Scene_Linear:
		p = paint_linear_gradient_stops(v.start.x, v.start.y, v.end.x, v.end.y, s.stops[v.stops.start:][:v.stops.count])
		p.spread = v.spread
		p.gradient_clip = v.clip
		p.transform = into(s, v.transform, draw)
	case Scene_Radial:
		p = paint_radial_gradient_focal_stops(v.center.x, v.center.y, v.radius, v.focal.x, v.focal.y, v.focal_r, s.stops[v.stops.start:][:v.stops.count])
		p.spread = v.spread
		p.gradient_clip = v.clip
		p.transform = into(s, v.transform, draw)
	case Scene_Conic:
		p = paint_conic_gradient_stops(v.center.x, v.center.y, s.stops[v.stops.start:][:v.stops.count])
		// The start angle: turned about the centre in paint space.
		turn := transform_multiply(transform_multiply(transform_translation(-v.center.x, -v.center.y), transform_rotation(v.angle)), transform_translation(v.center.x, v.center.y))
		p.transform = transform_multiply(turn, into(s, v.transform, draw))
	case Scene_Image_Paint:
		p = paint_image_tint(r.images[v.image - 1], 0, 0, 1, 1, 0, scene_color(v.tint))
		p.transform = into(s, v.transform, draw)
	case Scene_Pattern_Paint:
		// Rejected by scene_record_supported.
	}
	if p.transform == TRANSFORM_IDENTITY {
		p.transform = {}
	}
	return p
}

// Draws range `rg` of `s.draws` in order.
@(private = "file")
scene_record_range :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, s: ^Scene, rg: Range) {
	culled := 0
	for k in rg.start ..< rg.start + rg.count {
		d := s.draws[k]
		// Inside a transparent layer: nothing until its pop.
		if culled > 0 {
			#partial switch _ in d {
			case Layer_Push, Clip_Push:
				culled += 1
			case Layer_Pop, Clip_Pop:
				culled -= 1
			}
			continue
		}
		switch v in d {
		case Scene_Fill:
			scene_record_look(r, c, ls, s, v.look, proc(r: ^Scene_Renderer, c: ^Canvas, s: ^Scene, d: Scene_Draw) {
				f := d.(Scene_Fill)
				t := s.transforms[f.transform - 1]
				p := scene_canvas_paint(r, s, f.paint, t)
				p.fill_rule = f.rule
				p.anti_alias = f.edge.kind != .Aliased
				p.feather = f.edge.feather if f.edge.kind == .Smooth else 0
				set_transform(c, t)
				if sh := s.paths[f.path - 1].shape; sh != nil {
					fill_shape(c, sh, p)
				} else {
					scene_path_into(s, f.path, &r.path)
					fill_path(c, &r.path, p)
				}
			}, d)
		case Scene_Stroke:
			scene_record_look(r, c, ls, s, v.look, proc(r: ^Scene_Renderer, c: ^Canvas, s: ^Scene, d: Scene_Draw) {
				st := d.(Scene_Stroke)
				t := s.transforms[st.transform - 1]
				style := s.strokes[st.style - 1]
				p := scene_canvas_paint(r, s, st.paint, t)
				scene_path_into(s, st.path, &r.path)
				if style.hairline {
					// A hairline's width is in device pixels: its outline in
					// device space.
					reset_transform(c)
					scene_path_into(s, st.path, &r.path, t)
					p.transform = {}
					if sh, ok := shape_from_path(&r.path, outline = true); ok {
						append(&r.shapes, sh)
						hairline_shape(c, &r.shapes[len(r.shapes) - 1], p, style.width)
					}
					return
				}
				p.stroke = {
					miter_limit    = style.miter_limit,
					line_width     = style.width,
					line_cap_start = style.cap_start,
					line_cap_end   = style.cap_end,
					line_join      = style.join,
					dash           = s.dashes[style.dashes.start:][:style.dashes.count],
					dash_offset    = style.dash_phase,
				}
				set_transform(c, t)
				stroke_path(c, &r.path, p)
			}, d)
		case Scene_Glyphs:
			scene_record_glyphs(r, c, ls, s, v)
		case Scene_Clear:
			save(c)
			reset_transform(c)
			reset_scissor(c)
			x0, y0 := max(v.rect[0], 0), max(v.rect[1], 0)
			x1, y1 := v.rect[2], v.rect[3]
			if x1 > x0 && y1 > y0 {
				clear_rect(c, u32(x0), u32(y0), u32(x1 - x0), u32(y1 - y0), scene_color(v.color))
			}
			restore(c)
		case Clip_Push:
			switch cl in v.shape {
			case Clip_Rect:
				save(c)
				reset_transform(c)
				intersect_scissor(c, f32(cl[0]), f32(cl[1]), f32(cl[2] - cl[0]), f32(cl[3] - cl[1]))
				append(&r.pushed_layer, false)
			case Clip_Path:
				scene_path_into(s, cl.path, &r.clip, s.transforms[cl.transform - 1])
				save(c)
				reset_transform(c)
				layer_push(ls, c, {opacity = 1, clip_path = &r.clip, clip_rule = cl.rule})
				restore(c)
				append(&r.pushed_layer, true)
			case Clip_Run:
				scene_run_union(r, s, cl.run, &r.clip)
				save(c)
				reset_transform(c)
				layer_push(ls, c, {opacity = 1, clip_path = &r.clip, clip_rule = .Non_Zero})
				restore(c)
				append(&r.pushed_layer, true)
			}
		case Clip_Pop:
			if pop(&r.pushed_layer) {
				layer_pop(ls, c)
			} else {
				restore(c)
			}
		case Layer_Push:
			if v.opacity <= 0 {
				culled = 1
				continue
			}
			params := Layer_Params{opacity = v.opacity, blend = v.blend.mode}
			scene_mask_params(s, v.mask, &params)
			layer_push(ls, c, params)
			append(&r.layer_masks, v.mask)
		case Layer_Pop:
			if m := pop(&r.layer_masks); m != 0 {
				scene_record_mask(r, c, ls, s, m)
			}
			layer_pop(ls, c)
		}
	}
}

@(private = "file")
scene_mask_params :: proc "contextless" (s: ^Scene, m: Mask_Id, params: ^Layer_Params) {
	if m == 0 {
		return
	}
	switch s.masks[m - 1].read {
	case .Alpha:
		params.mask_alpha = true
	case .Luminance:
		params.mask_luminance = .Rec709
	case .Luminance_Pdf:
		params.mask_luminance = .Pdf
	}
}

// A mask's draws into the open layer's mask.
@(private = "file")
scene_record_mask :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, s: ^Scene, m: Mask_Id) {
	layer_mask_begin(ls, c)
	save(c)
	reset_scissor(c)
	scene_record_range(r, c, ls, s, s.masks[m - 1].draws)
	restore(c)
	layer_mask_end(ls, c)
}

// A painting draw under its look: skipped at opacity 0; a blend mode, or a
// mask, wraps it in a layer of its own (a mask is read by that draw
// alone); its opacity and Porter-Duff operation are the canvas's.
@(private = "file")
scene_record_look :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, s: ^Scene, l: Scene_Look, draw: proc(r: ^Scene_Renderer, c: ^Canvas, s: ^Scene, d: Scene_Draw), d: Scene_Draw) {
	if l.opacity <= 0 {
		return
	}
	wrap := l.blend.mode != .Normal || l.mask != 0
	if wrap {
		params := Layer_Params{opacity = 1, blend = l.blend.mode}
		scene_mask_params(s, l.mask, &params)
		layer_push(ls, c, params)
	}
	save(c)
	set_global_alpha(c, l.opacity)
	set_composite_operation(c, l.blend.op)
	draw(r, c, s, d)
	restore(c)
	if wrap {
		if l.mask != 0 {
			scene_record_mask(r, c, ls, s, l.mask)
		}
		layer_pop(ls, c)
	}
}

// A glyph run's coverage is the union of its glyphs': an opaque solid run
// draws its glyphs directly (overlapping opaque coverage of one colour is
// their union); any other paints its bounds through an alpha mask of the
// glyphs, so it paints once wherever glyphs overlap.
@(private = "file")
scene_record_glyphs :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, s: ^Scene, g: Scene_Glyphs) {
	if g.opacity <= 0 {
		return
	}
	run := s.runs[g.run - 1]
	rt := s.transforms[run.transform - 1]
	solid, is_solid := s.paints[g.paint - 1].(Scene_Solid)
	direct := g.stroke == 0 && is_solid && solid.color[3] >= 1 && g.opacity >= 1 && g.mask == 0 && g.blend == {}
	if direct {
		p := scene_canvas_paint(r, s, g.paint, rt)
		save(c)
		set_transform(c, rt)
		for gl in s.glyphs[run.glyphs.start:][:run.glyphs.count] {
			scene_path_into(s, gl.path, &r.glyph, s.transforms[gl.transform - 1])
			fill_path(c, &r.glyph, p)
		}
		restore(c)
		return
	}
	// The run's device bounds, filled with the paint through the glyphs.
	b := EMPTY_BOUNDS
	for gl in s.glyphs[run.glyphs.start:][:run.glyphs.count] {
		t := transform_multiply(s.transforms[gl.transform - 1], rt)
		pb := s.paths[gl.path - 1].bounds
		for q in ([4]Vec2{{pb.minx, pb.miny}, {pb.maxx, pb.miny}, {pb.maxx, pb.maxy}, {pb.minx, pb.maxy}}) {
			d := transform_point(t, q.x, q.y)
			b = {min(b.minx, d.x), min(b.miny, d.y), max(b.maxx, d.x), max(b.maxy, d.y)}
		}
	}
	if g.stroke != 0 {
		// The pen reaches past the outlines: by half the width and the
		// miter, in run space.
		st := s.strokes[g.stroke - 1]
		reach := st.width * 0.5 * max(st.miter_limit, 1)
		scale := math.sqrt(abs(rt[0] * rt[3] - rt[1] * rt[2]))
		b = bounds_grow_f(b, reach * max(scale, 1))
	}
	// Drawn as: a layer at the run's opacity whose content is the bounds
	// filled with the paint and whose alpha mask is the glyphs. A run
	// under a mask of its own gets it on an outer layer, which also takes
	// the blend mode, so the blend meets the backdrop.
	masked := g.mask != 0
	if masked {
		outer := Layer_Params{opacity = 1, blend = g.blend.mode}
		scene_mask_params(s, g.mask, &outer)
		layer_push(ls, c, outer)
	}
	params := Layer_Params{opacity = g.opacity, blend = .Normal if masked else g.blend.mode, mask_alpha = true}
	layer_push(ls, c, params)
	save(c)
	reset_transform(c)
	path_reset(&r.path)
	path_rect(&r.path, b.minx, b.miny, b.maxx - b.minx, b.maxy - b.miny)
	fill_path(c, &r.path, scene_canvas_paint(r, s, g.paint, TRANSFORM_IDENTITY))
	restore(c)
	layer_mask_begin(ls, c)
	save(c)
	set_transform(c, rt)
	white := paint_color({1, 1, 1, 1})
	for gl in s.glyphs[run.glyphs.start:][:run.glyphs.count] {
		scene_path_into(s, gl.path, &r.glyph, s.transforms[gl.transform - 1])
		if g.stroke == 0 {
			fill_path(c, &r.glyph, white)
		} else {
			st := s.strokes[g.stroke - 1]
			w := white
			w.stroke = {miter_limit = st.miter_limit, line_width = st.width, line_cap_start = st.cap_start, line_cap_end = st.cap_end, line_join = st.join, dash = s.dashes[st.dashes.start:][:st.dashes.count], dash_offset = st.dash_phase}
			stroke_path(c, &r.glyph, w)
		}
	}
	restore(c)
	layer_mask_end(ls, c)
	layer_pop(ls, c)
	if masked {
		scene_record_mask(r, c, ls, s, g.mask)
		layer_pop(ls, c)
	}
}

@(private = "file")
bounds_grow_f :: proc "contextless" (b: Bounds, d: f32) -> Bounds {
	return {b.minx - d, b.miny - d, b.maxx + d, b.maxy + d}
}

// The union of a run's glyphs in device space, each through its own
// non-zero winding, as one path (ocurves' booleans).
@(private = "file")
scene_run_union :: proc(r: ^Scene_Renderer, s: ^Scene, id: Run_Id, out: ^Path) {
	run := s.runs[id - 1]
	rt := s.transforms[run.transform - 1]
	n := int(run.glyphs.count)
	for len(r.paths) < n {
		p: Path
		path_init(&p)
		append(&r.paths, p)
	}
	clear(&r.operands)
	for gl, i in s.glyphs[run.glyphs.start:][:n] {
		scene_path_into(s, gl.path, &r.paths[i], transform_multiply(s.transforms[gl.transform - 1], rt))
		append(&r.operands, Bool_Operand{&r.paths[i], .Non_Zero})
	}
	path_reset(out)
	if n == 1 {
		path_append(out, &r.paths[0])
		return
	}
	if path_boolean_many(out, r.operands[:], .Union, &r.booleans) != nil {
		// Too hard for the booleans: the glyphs as they are, which differs
		// only where outlines of opposite winding overlap.
		path_reset(out)
		for i in 0 ..< n {
			path_append(out, &r.paths[i])
		}
	}
}

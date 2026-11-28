package ovg

import "base:runtime"
import "core:math"
import "core:slice"

// A Scene recorded onto a canvas, through its layer stack, so that either
// backend draws it with today's machinery (docs/scene.md, staging step 4).
// What this path can't yet draw exactly is rejected whole, before anything
// is recorded, rather than drawn approximately: layer filters, motion, a
// Porter-Duff operation with a mask, what reads its backdrop through a path
// clip, clips directly inside a knockout group, and the pattern cases
// listed at scene_record_supported. Non-isolated and knockout groups are
// drawn as scene_group and scene_knockout say. A layer or a run
// under a Porter-Duff operation is drawn into an image first, which then
// composites with the operation where it isn't transparent (bounded).
//
// A pattern cell is rendered once into a tile, before anything else: its
// draws in cell space, mapped onto a tile of whole pixels spanning one
// lattice step, cut to the cell's clip rectangle. A pattern paint draws the
// tile repeating, through the cell's transform. That is exact when the
// lattice lands on whole device pixels, and resampled otherwise.
//
// Each mask a draw or layer names is rendered once, before anything else
// and outside every layer, into an image of the canvas's size: a luminance
// mask's group isolated, then over its backdrop colour (PDF's /BC), its
// transfer table (/TR) applied once to its value. Every reader copies that
// image into its own mask, 1:1. Clips by path are layers;
// clipping by coverage is the compile step that comes next.

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
	// Per mask, its image (none when nothing names it).
	mask_images: [dynamic]Image_Id,
	// Per pattern, its tile (none when nothing paints with it).
	tiles:       [dynamic]Scene_Tile,
	// What every transform read composes onto: the device for main and
	// masks, a tile's pixels inside a pattern cell.
	base:        Transform2D,
	// Inside an uncoloured cell: every paint is white, so only coverage
	// reaches the tile.
	white:       bool,
	// Drawing a non-isolated group's alpha: blend modes are off and groups
	// inside are isolated (scene_group).
	alpha_pass:  bool,
	// Drawing a knockout element's shape: white, opaque, unmasked, blend
	// modes off, groups plain (scene_knockout).
	shape_pass:  bool,
	// Per open Layer_Push, its Porter-Duff operation: anything but
	// source-over draws the layer into an image first (scene_bounded_end).
	layer_ops:   [dynamic]Composite_Operation,
	// The open bounded images, innermost last.
	bounded:     [dynamic]Image_Id,
}

// A pattern cell's tile: its image and size in pixels, and the map from
// tile pixels to device space.
Scene_Tile :: struct {
	image:   Image_Id,
	size:    [2]u32,
	to_device: Transform2D,
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
	r.mask_images = make([dynamic]Image_Id, allocator)
	r.tiles = make([dynamic]Scene_Tile, allocator)
	r.layer_ops = make([dynamic]Composite_Operation, allocator)
	r.bounded = make([dynamic]Image_Id, allocator)
	r.base = TRANSFORM_IDENTITY
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
	delete(r.mask_images)
	delete(r.tiles)
	delete(r.layer_ops)
	delete(r.bounded)
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
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if p := scene_check(s); p.error != .None {
		return p
	}
	if p := scene_record_supported(s); p.error != .None {
		return p
	}
	// Images: a store image as it is (sampling as its flags say, which
	// must be what its paints ask); a view uploaded for this render,
	// sampling as its paints ask.
	sampling, _, _ := scene_sampling(s)
	for img, i in s.images {
		if id, stored := img.(Image_Id); stored {
			info, _ := image_info(c, id)
			has := Image_Sampling.Nearest if .Nearest in info.flags else .Area if .Generate_Mipmaps in info.flags else .Linear
			if has != sampling[i] {
				return {.Unsupported, .Images, i}
			}
		}
	}
	clear(&r.images)
	for img, i in s.images {
		switch v in img {
		case Image_Id:
			append(&r.images, v)
		case Pixel_View:
			append(&r.images, scene_upload(r, c, v, sampling[i]))
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
			// A non-isolated group reads its backdrop as an image.
			root ||= v.blend.mode != .Normal || !v.isolated
		}
	}
	layer_stack_begin(ls, c, c.width, c.height, nil, root)
	save(c)
	clear(&r.layer_masks)
	clear(&r.pushed_layer)
	clear(&r.layer_ops)
	clear(&r.bounded)
	r.alpha_pass, r.shape_pass = false, false
	scene_render_masks(r, c, ls, s)
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
		// A mask or blend mode draws through a layer, which composites
		// source-over: a Porter-Duff operation would apply inside it.
		return l.blend.op == .Source_Over || l.mask == 0 && l.blend.mode == .Normal
	}
	kept :: proc(s: ^Scene, p: Path_Id) -> bool {
		return s.paths[p - 1].shape != nil
	}
	// What each open push is. Inside a non-isolated group: no clears and
	// no Porter-Duff operations, which PDF's groups don't have and the
	// group's alpha (scene_group) can't follow. A knockout group's elements
	// are its draws and layers: no clips directly inside one yet.
	Open :: enum u8 {Rect, Path_Clip, Isolated, Group, Knockout}
	opens := make([dynamic]Open, 0, 16, context.temp_allocator)
	inside := 0
	for d, k in s.draws {
		l: Scene_Look
		#partial switch v in d {
		case Scene_Fill:
			l = v.look
		case Scene_Stroke:
			l = v.look
		case Scene_Glyphs:
			l = v.look
		case Layer_Push:
			l.blend = v.blend
		case Clip_Push:
			if len(opens) > 0 && opens[len(opens) - 1] == .Knockout {
				return {.Unsupported, .Draws, k}
			}
		case Scene_Clear:
			if inside > 0 {
				return {.Unsupported, .Draws, k}
			}
		}
		if inside > 0 && l.blend.op != .Source_Over {
			return {.Unsupported, .Draws, k}
		}
		#partial switch v in d {
		case Layer_Push:
			o := Open.Knockout if v.knockout else .Isolated if v.isolated else .Group
			append(&opens, o)
			inside += int(o >= .Group)
		case Clip_Push:
			_, rect := v.shape.(Clip_Rect)
			append(&opens, Open.Rect if rect else .Path_Clip)
		case Layer_Pop, Clip_Pop:
			if len(opens) > 0 {
				inside -= int(pop(&opens) >= .Group)
			}
		}
		ok := true
		#partial switch v in d {
		case Scene_Fill:
			ok = look(s, v.look)
		case Scene_Stroke:
			// Kept shapes are read by fills only, so far.
			ok = look(s, v.look) && !kept(s, v.path)
		case Scene_Glyphs:
			// A run composites as a group, through a layer, which takes no
			// Porter-Duff operation yet; no hairline pen for runs yet.
			ok = look(s, v.look) && (v.blend.op == .Source_Over || v.mask == 0 && v.blend.mode == .Normal)
			if ok && v.stroke != 0 {
				ok = !s.strokes[v.stroke - 1].hairline
			}
			run := s.runs[v.run - 1]
			for g in s.glyphs[run.glyphs.start:][:run.glyphs.count] {
				ok &&= !kept(s, g.path)
			}
		case Clip_Push:
			#partial switch c in v.shape {
			case Clip_Path:
				ok = !kept(s, c.path)
			case Clip_Run:
				run := s.runs[c.run - 1]
				for g in s.glyphs[run.glyphs.start:][:run.glyphs.count] {
					ok &&= !kept(s, g.path)
				}
			}
		case Layer_Push:
			ok = v.filters.count == 0 && (v.blend.op == .Source_Over || v.mask == 0 && v.blend.mode == .Normal && v.isolated && !v.knockout)
		}
		if !ok {
			return {.Unsupported, .Draws, k}
		}
	}
	// Pattern cells: cells that don't overlap (a step at least the clip's
	// size), a tile of at most 4096 pixels a side, and draws made in cell
	// space: no whole-pixel clips or clears, masks or patterns inside; an
	// uncoloured cell paints coverage, so its images must be stencils.
	for cell, i in s.patterns {
		w, h := cell.clip.maxx - cell.clip.minx, cell.clip.maxy - cell.clip.miny
		if abs(cell.step.x) < w || abs(cell.step.y) < h || cell.step.x == 0 || cell.step.y == 0 {
			return {.Unsupported, .Patterns, i}
		}
		size := scene_tile_size(s, cell)
		if size.x > 4096 || size.y > 4096 {
			return {.Unsupported, .Patterns, i}
		}
		for k in cell.draws.start ..< cell.draws.start + cell.draws.count {
			l: Scene_Look
			has_look := false
			switch d in s.draws[k] {
			case Scene_Fill:
				l, has_look = d.look, true
			case Scene_Stroke:
				l, has_look = d.look, true
			case Scene_Glyphs:
				l, has_look = d.look, true
			case Clip_Push:
				if _, rect := d.shape.(Clip_Rect); rect {
					return {.Unsupported, .Draws, int(k)}
				}
			case Layer_Push:
				if d.mask != 0 {
					return {.Unsupported, .Draws, int(k)}
				}
			case Scene_Clear:
				return {.Unsupported, .Draws, int(k)}
			case Clip_Pop, Layer_Pop:
			}
			if !has_look {
				continue
			}
			if l.mask != 0 {
				return {.Unsupported, .Draws, int(k)}
			}
			#partial switch pv in s.paints[l.paint - 1] {
			case Scene_Pattern_Paint:
				return {.Unsupported, .Draws, int(k)}
			case Scene_Image_Paint:
				if view, is_view := s.images[pv.image - 1].(Pixel_View); cell.uncoloured && (!is_view || view.format != .Alpha8) {
					return {.Unsupported, .Draws, int(k)}
				}
			}
		}
	}
	// Sampling is an image's here: every paint of an image must ask for the
	// same, and a stored image must already sample that way.
	if _, i, ok := scene_sampling(s); !ok {
		return {.Unsupported, .Paints, i}
	}
	return {}
}

// The sampling each image is drawn with (Linear when no paint names it),
// or false and the first paint that disagrees with another of its image.
@(private = "file")
scene_sampling :: proc(s: ^Scene) -> (sampling: []Image_Sampling, bad: int, ok: bool) {
	sampling = make([]Image_Sampling, len(s.images), context.temp_allocator)
	named := make([]bool, len(s.images), context.temp_allocator)
	for p, i in s.paints {
		ip, is_image := p.(Scene_Image_Paint)
		if !is_image {
			continue
		}
		k := int(ip.image) - 1
		if named[k] && sampling[k] != ip.sampling {
			return nil, i, false
		}
		named[k], sampling[k] = true, ip.sampling
	}
	return sampling, 0, true
}

// A borrowed view as an image of this render, in the format it says.
@(private = "file")
scene_upload :: proc(r: ^Scene_Renderer, c: ^Canvas, v: Pixel_View, sampling: Image_Sampling) -> Image_Id {
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
	switch sampling {
	case .Linear:
	case .Nearest:
		flags += {.Nearest}
	case .Area:
		flags += {.Generate_Mipmaps}
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

// Transform `id` on to the device (or, inside a pattern cell, the tile).
@(private = "file")
scene_xf :: proc "contextless" (r: ^Scene_Renderer, s: ^Scene, id: Transform_Id) -> Transform2D {
	return transform_multiply(s.transforms[id - 1], r.base)
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
	into :: proc(r: ^Scene_Renderer, s: ^Scene, t: Transform_Id, draw: Transform2D) -> Transform2D {
		return transform_multiply(transform_multiply(s.transforms[t - 1], r.base), transform_inverse(draw))
	}
	p: Paint
	if r.shape_pass {
		return paint_color({1, 1, 1, 1})
	}
	if r.white {
		// Inside an uncoloured cell: coverage only, in white; a stencil
		// image (Alpha8) keeps its alpha.
		if ip, is_image := s.paints[id - 1].(Scene_Image_Paint); is_image {
			p = paint_image_tint(r.images[ip.image - 1], 0, 0, 1, 1, 0, {1, 1, 1, 1})
			p.transform = into(r, s, ip.transform, draw)
			return p
		}
		return paint_color({1, 1, 1, 1})
	}
	switch v in s.paints[id - 1] {
	case Scene_Solid:
		p = paint_color(scene_color(v.color))
	case Scene_Linear:
		p = paint_linear_gradient_stops(v.start.x, v.start.y, v.end.x, v.end.y, s.stops[v.stops.start:][:v.stops.count])
		p.spread = v.spread
		p.gradient_clip = v.clip
		p.transform = into(r, s, v.transform, draw)
	case Scene_Radial:
		p = paint_radial_gradient_focal_stops(v.center.x, v.center.y, v.radius, v.focal.x, v.focal.y, v.focal_r, s.stops[v.stops.start:][:v.stops.count])
		p.spread = v.spread
		p.gradient_clip = v.clip
		p.transform = into(r, s, v.transform, draw)
	case Scene_Conic:
		p = paint_conic_gradient_stops(v.center.x, v.center.y, s.stops[v.stops.start:][:v.stops.count])
		// The start angle: turned about the centre in paint space.
		turn := transform_multiply(transform_multiply(transform_translation(-v.center.x, -v.center.y), transform_rotation(v.angle)), transform_translation(v.center.x, v.center.y))
		p.transform = transform_multiply(turn, into(r, s, v.transform, draw))
	case Scene_Image_Paint:
		p = paint_image_tint(r.images[v.image - 1], 0, 0, 1, 1, 0, scene_color(v.tint))
		p.transform = into(r, s, v.transform, draw)
	case Scene_Pattern_Paint:
		// The tile repeating, from its pixels to the device, then into the
		// draw's space; an uncoloured cell's coverage tinted.
		t := r.tiles[v.pattern - 1]
		tint := scene_color(v.color) if s.patterns[v.pattern - 1].uncoloured else Color{1, 1, 1, 1}
		p = paint_image_tint(t.image, 0, 0, f32(t.size.x), f32(t.size.y), 0, tint)
		p.transform = transform_multiply(t.to_device, transform_inverse(draw))
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
	for k := rg.start; k < rg.start + rg.count; k += 1 {
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
				t := scene_xf(r, s, f.transform)
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
				t := scene_xf(r, s, st.transform)
				style := s.strokes[st.style - 1]
				p := scene_canvas_paint(r, s, st.paint, t)
				scene_path_into(s, st.path, &r.path)
				if style.hairline {
					// A hairline's width is in device pixels: its outline in
					// device space.
					reset_transform(c)
					scene_path_into(s, st.path, &r.path, t)
					p = scene_canvas_paint(r, s, st.paint, TRANSFORM_IDENTITY)
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
				// A clip is coverage each draw takes (clip_path), no layer.
				scene_path_into(s, cl.path, &r.clip, scene_xf(r, s, cl.transform))
				save(c)
				reset_transform(c)
				clip_path(c, &r.clip, cl.rule)
				append(&r.pushed_layer, false)
			case Clip_Run:
				scene_run_union(r, s, cl.run, &r.clip)
				save(c)
				reset_transform(c)
				clip_path(c, &r.clip, .Non_Zero)
				append(&r.pushed_layer, false)
			}
		case Clip_Pop:
			if pop(&r.pushed_layer) {
				layer_pop(ls, c)
			} else {
				restore(c)
			}
		case Layer_Push:
			if r.shape_pass {
				// A group's shape is its elements' union, whatever it is.
				layer_push(ls, c, {opacity = 1})
				append(&r.layer_masks, 0)
				append(&r.layer_ops, Composite_Operation.Source_Over)
				continue
			}
			if v.opacity <= 0 {
				culled = 1
				continue
			}
			if v.knockout {
				pop_at := scene_matching_pop(s, k)
				scene_knockout(r, c, ls, s, v, {k + 1, pop_at - k - 1})
				k = pop_at
				continue
			}
			if !v.isolated && !r.alpha_pass {
				pop_at := scene_matching_pop(s, k)
				scene_group(r, c, ls, s, v, {k + 1, pop_at - k - 1})
				k = pop_at
				continue
			}
			if v.blend.op != .Source_Over {
				scene_bounded_begin(r, c, ls)
			}
			params := Layer_Params{opacity = v.opacity, blend = scene_mode(r, v.blend.mode)}
			scene_mask_params(s, v.mask, &params)
			layer_push(ls, c, params)
			append(&r.layer_masks, v.mask)
			append(&r.layer_ops, v.blend.op)
		case Layer_Pop:
			if m := pop(&r.layer_masks); m != 0 {
				scene_record_mask(r, c, ls, s, m)
			}
			layer_pop(ls, c)
			if op := pop(&r.layer_ops); op != .Source_Over {
				scene_bounded_end(r, c, ls, op)
			}
		}
	}
}

// The layer params that read mask `m` as its readers take it (as alpha
// once its transfer table has run).
@(private = "file")
scene_mask_params :: proc "contextless" (s: ^Scene, m: Mask_Id, params: ^Layer_Params) {
	if m == 0 {
		return
	}
	read := s.masks[m - 1].read
	if s.masks[m - 1].lut != 0 {
		read = .Alpha
	}
	switch read {
	case .Alpha:
		params.mask_alpha = true
	case .Luminance:
		params.mask_luminance = .Rec709
	case .Luminance_Pdf:
		params.mask_luminance = .Pdf
	}
}

// Mask `m` into the open layer's mask: its image, copied 1:1.
@(private = "file")
scene_record_mask :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, s: ^Scene, m: Mask_Id) {
	img := r.mask_images[m - 1]
	layer_mask_begin(ls, c)
	scene_copy(ls, c, img)
	layer_mask_end(ls, c)
}

// `img` (the canvas's size) drawn over the current target 1:1, unclipped.
@(private = "file")
scene_copy :: proc(ls: ^Layer_Stack, c: ^Canvas, img: Image_Id) {
	save(c)
	reset_transform(c)
	reset_scissor(c)
	set_global_alpha(c, 1)
	set_composite_operation(c, .Source_Over)
	path_reset(&ls.scratch)
	path_rect(&ls.scratch, 0, 0, f32(ls.width), f32(ls.height))
	p := paint_image(img, 0, 0, f32(ls.width), f32(ls.height), 0)
	p.anti_alias = false
	fill_path(c, &ls.scratch, p)
	restore(c)
}

// A blend mode as drawn: off while drawing a non-isolated group's alpha.
@(private = "file")
scene_mode :: #force_inline proc "contextless" (r: ^Scene_Renderer, m: Blend_Mode) -> Blend_Mode {
	return .Normal if r.alpha_pass else m
}

// The Layer_Pop closing the Layer_Push at `push` (scene_check has checked
// the nesting).
@(private = "file")
scene_matching_pop :: proc(s: ^Scene, push: u32) -> u32 {
	depth := 0
	for k := push; ; k += 1 {
		#partial switch _ in s.draws[k] {
		case Layer_Push, Clip_Push:
			depth += 1
		case Layer_Pop, Clip_Pop:
			depth -= 1
			if depth == 0 {
				return k
			}
		}
	}
}

// A non-isolated group (PDF 11.4.4, 11.4.8) of the draws `inner`. They
// composite onto a copy of the backdrop B (G), so a blend mode inside
// blends with what is under the group. Drawn again into a transparent
// image with blend modes off and groups inside isolated, they give the
// group's alpha a_g (A), which G can't give back over an opaque backdrop.
// The group's own colour is G - (1 - a_g) B with alpha a_g: B with A drawn
// over it Destination_Out is (1 - a_g) B (T), and G - T is one arithmetic
// composite (its alpha comes out a_g). That composites onto the backdrop
// with the group's opacity, blend mode and mask. Every image is RGBA16F,
// so the subtraction keeps faint levels.
@(private = "file")
scene_group :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, s: ^Scene, v: Layer_Push, inner: Range) {
	w, h := ls.width, ls.height
	b := layer_backdrop(ls, c, .RGBA16F)
	g := layer_image_begin(ls, c, w, h, .RGBA16F)
	scene_copy(ls, c, b)
	scene_record_range(r, c, ls, s, inner)
	layer_image_end(ls, c)
	a := layer_image_begin(ls, c, w, h, .RGBA16F)
	alpha_pass := r.alpha_pass
	r.alpha_pass = true
	scene_record_range(r, c, ls, s, inner)
	r.alpha_pass = alpha_pass
	layer_image_end(ls, c)
	own := scene_remove(ls, c, g, a, b)
	layer_release(ls, b)
	layer_image_release(ls, g)
	layer_image_release(ls, a)
	scene_group_composite(r, c, ls, s, v, own)
	layer_release(ls, own)
}

// `g` less (1 - m) `b`, where `m` is `a`'s alpha: B with A drawn over it
// Destination_Out, then one arithmetic composite. A pooled RGBA16F image
// the stack's size, for `layer_release`.
@(private = "file")
scene_remove :: proc(ls: ^Layer_Stack, c: ^Canvas, g, a, b: Image_Id) -> Image_Id {
	w, h := ls.width, ls.height
	t := layer_acquire(ls, c, w, h, format = .RGBA16F)
	layer_target_begin(ls, c, t, keep = true)
	save(c)
	set_global_alpha(c, 1)
	set_composite_operation(c, .Copy)
	layer_blit(ls, c, b, 0, 0, w, h, 1, keep_motion = true)
	set_composite_operation(c, .Destination_Out)
	layer_blit(ls, c, a, 0, 0, w, h, 1, keep_motion = true)
	restore(c)
	layer_target_end(ls, c)
	out := layer_acquire(ls, c, w, h, format = .RGBA16F)
	filter_image(c, out, Composite{op = .Arithmetic, k = {0, 1, -1, 0}, backdrop = t}, g)
	layer_release(ls, t)
	return out
}

// A group's own colour `own` onto its backdrop, with the group's opacity,
// blend mode and mask.
@(private = "file")
scene_group_composite :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, s: ^Scene, v: Layer_Push, own: Image_Id) {
	params := Layer_Params{opacity = v.opacity, blend = scene_mode(r, v.blend.mode)}
	scene_mask_params(s, v.mask, &params)
	layer_push(ls, c, params)
	scene_copy(ls, c, own)
	if v.mask != 0 {
		scene_record_mask(r, c, ls, s, v.mask)
	}
	layer_pop(ls, c)
}

// `into` (a pooled image) with `shape`'s alpha f knocked out of it, then
// `add` added: into (1 - f) + add.
@(private = "file")
scene_knock :: proc(ls: ^Layer_Stack, c: ^Canvas, into, shape, add: Image_Id) {
	w, h := ls.width, ls.height
	layer_target_begin(ls, c, into, keep = true)
	save(c)
	set_global_alpha(c, 1)
	set_composite_operation(c, .Destination_Out)
	layer_blit(ls, c, shape, 0, 0, w, h, 1, keep_motion = true)
	set_composite_operation(c, .Lighter)
	layer_blit(ls, c, add, 0, 0, w, h, 1, keep_motion = true)
	restore(c)
	layer_target_end(ls, c)
}

// A knockout group (PDF 11.4.6) of the draws `inner`. Each element (a draw,
// or a layer and its range) composites with the group's starting backdrop
// C0 rather than with the elements before it, and replaces them by its
// shape f. With X the element drawn onto C0 (its own opacity, blend mode
// and mask; f in it once), f C_t = X - (1 - f) C0, so the result R,
// starting as C0, becomes R (1 - f) + X - (1 - f) C0: R with the element's
// shape S drawn Destination_Out, then X - (1 - f) C0 added. An isolated
// group's C0 is transparent, which leaves X. A non-isolated group's alpha
// knocks out alike, A (1 - f) plus the element's alpha alone, and its
// colour is then R - (1 - a_g) C0, as in scene_group. Images are RGBA16F
// and handed back per element.
@(private = "file")
scene_knockout :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, s: ^Scene, v: Layer_Push, inner: Range) {
	w, h := ls.width, ls.height
	isolated := v.isolated || r.alpha_pass
	b, a: Image_Id
	if !isolated {
		b = layer_backdrop(ls, c, .RGBA16F)
		a = layer_acquire(ls, c, w, h, format = .RGBA16F)
		layer_target_begin(ls, c, a)
		layer_target_end(ls, c)
	}
	res := layer_acquire(ls, c, w, h, format = .RGBA16F)
	layer_target_begin(ls, c, res, keep = !isolated)
	if !isolated {
		save(c)
		set_global_alpha(c, 1)
		set_composite_operation(c, .Copy)
		layer_blit(ls, c, b, 0, 0, w, h, 1, keep_motion = true)
		restore(c)
	}
	layer_target_end(ls, c)
	for k := inner.start; k < inner.start + inner.count; k += 1 {
		el := Range{k, 1}
		if _, push := s.draws[k].(Layer_Push); push {
			pop_at := scene_matching_pop(s, k)
			el = {k, pop_at - k + 1}
			k = pop_at
		}
		shape := layer_image_begin(ls, c, w, h, .RGBA16F)
		shape_pass := r.shape_pass
		r.shape_pass = true
		scene_record_range(r, c, ls, s, el)
		r.shape_pass = shape_pass
		layer_image_end(ls, c)
		x := layer_image_begin(ls, c, w, h, .RGBA16F)
		if !isolated {
			scene_copy(ls, c, b)
		}
		scene_record_range(r, c, ls, s, el)
		layer_image_end(ls, c)
		if isolated {
			scene_knock(ls, c, res, shape, x)
		} else {
			add := scene_remove(ls, c, x, shape, b)
			scene_knock(ls, c, res, shape, add)
			layer_release(ls, add)
			alone := layer_image_begin(ls, c, w, h, .RGBA16F)
			alpha_pass := r.alpha_pass
			r.alpha_pass = true
			scene_record_range(r, c, ls, s, el)
			r.alpha_pass = alpha_pass
			layer_image_end(ls, c)
			scene_knock(ls, c, a, shape, alone)
			layer_image_release(ls, alone)
		}
		layer_image_release(ls, x)
		layer_image_release(ls, shape)
	}
	own := res
	if !isolated {
		own = scene_remove(ls, c, res, a, b)
		layer_release(ls, res)
		layer_release(ls, a)
		layer_release(ls, b)
	}
	scene_group_composite(r, c, ls, s, v, own)
	layer_release(ls, own)
}

// A layer or run under a Porter-Duff operation: drawn source-over into an
// image the open target's size, which `scene_bounded_end` composites with
// the operation where the image isn't transparent (half an 8-bit step or
// more), leaving every other pixel as it was, whatever size the backend
// made the layer's window.
@(private = "file")
scene_bounded_begin :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack) {
	append(&r.bounded, layer_image_begin(ls, c, ls.width, ls.height, .RGBA16F if ls.format == .RGBA16F else .RGBA8))
}

@(private = "file")
scene_bounded_end :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, op: Composite_Operation) {
	img := pop(&r.bounded)
	layer_image_end(ls, c)
	save(c)
	reset_transform(c)
	set_global_alpha(c, 1)
	set_composite_operation(c, op)
	path_reset(&ls.scratch)
	path_rect(&ls.scratch, 0, 0, f32(ls.width), f32(ls.height))
	p := paint_image(img, 0, 0, f32(ls.width), f32(ls.height), 0)
	p.anti_alias = false
	c.image_bounded = true
	fill_path(c, &ls.scratch, p)
	c.image_bounded = false
	restore(c)
}

// Every mask a draw or layer names and every pattern a paint uses,
// rendered before main and outside every layer (a layer that turns out to
// draw nothing drops what was recorded in it), in the order their draws
// come in `draws`: their draws name only masks and patterns whose draws
// come before, so those are ready first.
@(private = "file")
scene_render_masks :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, s: ^Scene) {
	resize(&r.mask_images, len(s.masks))
	resize(&r.tiles, len(s.patterns))
	named := make([]bool, len(s.masks), context.temp_allocator)
	painted := make([]bool, len(s.patterns), context.temp_allocator)
	for d in s.draws {
		l: Scene_Look
		#partial switch v in d {
		case Scene_Fill:
			l = v.look
		case Scene_Stroke:
			l = v.look
		case Scene_Glyphs:
			l = v.look
		case Layer_Push:
			l.mask = v.mask
		}
		if l.mask != 0 {
			named[l.mask - 1] = true
		}
		if l.paint != 0 {
			if pp, ok := s.paints[l.paint - 1].(Scene_Pattern_Paint); ok {
				painted[pp.pattern - 1] = true
			}
		}
	}
	// (draw start, 0 mask or 1 pattern, index)
	order := make([dynamic][3]u32, 0, len(s.masks) + len(s.patterns), context.temp_allocator)
	for mk, i in s.masks {
		r.mask_images[i] = {}
		if named[i] {
			append(&order, [3]u32{mk.draws.start, 0, u32(i)})
		}
	}
	for cell, i in s.patterns {
		r.tiles[i] = {}
		if painted[i] {
			append(&order, [3]u32{cell.draws.start, 1, u32(i)})
		}
	}
	slice.sort_by(order[:], proc(a, b: [3]u32) -> bool {
		return a[0] < b[0] || a[0] == b[0] && (a[1] < b[1] || a[1] == b[1] && a[2] < b[2])
	})
	for o in order {
		if o[1] == 0 {
			r.mask_images[o[2]] = scene_mask_image(r, c, ls, s, Mask_Id(o[2] + 1))
		} else {
			r.tiles[o[2]] = scene_tile(r, c, ls, s, Pattern_Id(o[2] + 1))
		}
	}
}

// A cell's tile size: one lattice step, in the device pixels the cell's
// transform stretches each axis to.
@(private = "file")
scene_tile_size :: proc(s: ^Scene, cell: Pattern_Cell) -> [2]u32 {
	t := s.transforms[cell.transform - 1]
	sx, sy := math.hypot(t[0], t[1]), math.hypot(t[2], t[3])
	return {u32(max(math.ceil(abs(cell.step.x) * sx - 1e-3), 1)), u32(max(math.ceil(abs(cell.step.y) * sy - 1e-3), 1))}
}

// Pattern `id`'s tile: its cell's draws mapped from cell space onto the
// tile (the clip rectangle's corner at its origin, one step across it),
// cut to the clip rectangle.
@(private = "file")
scene_tile :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, s: ^Scene, id: Pattern_Id) -> Scene_Tile {
	cell := s.patterns[id - 1]
	size := scene_tile_size(s, cell)
	k := Vec2{f32(size.x) / abs(cell.step.x), f32(size.y) / abs(cell.step.y)}
	to_tile := transform_multiply(transform_translation(-cell.clip.minx, -cell.clip.miny), transform_scaling(k.x, k.y))
	to_cell := transform_inverse(to_tile)
	tile := layer_pattern_begin(ls, c, size.x, size.y)
	save(c)
	reset_transform(c)
	reset_scissor(c)
	scissor(c, 0, 0, (cell.clip.maxx - cell.clip.minx) * k.x, (cell.clip.maxy - cell.clip.miny) * k.y)
	base, white := r.base, r.white
	r.base, r.white = to_tile, cell.uncoloured
	scene_record_range(r, c, ls, s, cell.draws)
	r.base, r.white = base, white
	restore(c)
	layer_pattern_end(ls, c)
	return {tile, size, transform_multiply(to_cell, s.transforms[cell.transform - 1])}
}

// Mask `m` rendered, in device space and the canvas's size. Read as
// luminance with a backdrop colour (PDF's /BC), its group is drawn
// isolated, then composited over the backdrop (PDF 11.6.5.2), so where it
// draws nothing the mask is the backdrop's and its blend modes don't meet
// the backdrop. With a transfer table, its value (luminance or alpha) is
// written as white of that alpha and put through the table (PDF's /TR), so
// readers take it as alpha.
@(private = "file")
scene_mask_image :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, s: ^Scene, m: Mask_Id) -> Image_Id {
	mk := s.masks[m - 1]
	w, h := c.width, c.height
	img := layer_image_begin(ls, c, w, h)
	save(c)
	reset_scissor(c)
	set_global_alpha(c, 1)
	set_composite_operation(c, .Source_Over)
	over := mk.read != .Alpha && mk.backdrop != {}
	if over {
		clear_rect(c, 0, 0, w, h, scene_color(mk.backdrop))
		layer_push(ls, c, {opacity = 1})
	}
	// A mask is drawn whatever the clips of its readers.
	pushed := len(r.pushed_layer)
	scene_record_range(r, c, ls, s, mk.draws)
	assert(len(r.pushed_layer) == pushed)
	if over {
		layer_pop(ls, c)
	}
	restore(c)
	layer_image_end(ls, c)
	if mk.lut != 0 {
		// The value as white of that alpha: a luminance read takes the
		// premultiplied colour's luminance (v0.1.13), an alpha read the
		// alpha as it is.
		value := layer_image_begin(ls, c, w, h)
		if mk.read != .Alpha {
			c.image_luminance = .Pdf if mk.read == .Luminance_Pdf else .Rec709
		}
		scene_copy(ls, c, img)
		c.image_luminance = nil
		layer_image_end(ls, c)
		// RGB stays white; alpha goes through the table.
		table := s.luts[mk.lut - 1]
		lut: [256 * 4]u8
		for v, i in table {
			lut[i * 4], lut[i * 4 + 1], lut[i * 4 + 2], lut[i * 4 + 3] = 255, 255, 255, v
		}
		lut_id, err := create_image(c, image_source_rgba(lut[:], 256, 1), {})
		if err == nil {
			append(&r.made, lut_id)
			img = layer_image_begin(ls, c, w, h)
			layer_image_end(ls, c)
			filter_image(c, img, Component_Transfer{lut_id}, value)
		}
	}
	r.mask_images[m - 1] = img
	return img
}

// A painting draw under its look: skipped at opacity 0; a blend mode, or a
// mask, wraps it in a layer of its own (a mask is read by that draw
// alone); its opacity and Porter-Duff operation are the canvas's.
@(private = "file")
scene_record_look :: proc(r: ^Scene_Renderer, c: ^Canvas, ls: ^Layer_Stack, s: ^Scene, l: Scene_Look, draw: proc(r: ^Scene_Renderer, c: ^Canvas, s: ^Scene, d: Scene_Draw), d: Scene_Draw) {
	l := l
	if r.shape_pass {
		// The shape alone: an element at opacity 0 still has one.
		l.opacity, l.mask, l.blend = 1, 0, {}
	}
	if l.opacity <= 0 {
		return
	}
	mode := scene_mode(r, l.blend.mode)
	wrap := mode != .Normal || l.mask != 0
	if wrap {
		params := Layer_Params{opacity = 1, blend = mode}
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
	g := g
	if r.shape_pass {
		g.opacity, g.mask, g.blend = 1, 0, {}
	}
	if g.opacity <= 0 {
		return
	}
	run := s.runs[g.run - 1]
	if run.glyphs.count == 0 {
		return
	}
	if g.blend.op != .Source_Over {
		// Drawn source-over into an image, which then composites with the
		// operation where the run covers.
		over := g
		over.blend.op = .Source_Over
		scene_bounded_begin(r, c, ls)
		scene_record_glyphs(r, c, ls, s, over)
		scene_bounded_end(r, c, ls, g.blend.op)
		return
	}
	rt := scene_xf(r, s, run.transform)
	solid, is_solid := s.paints[g.paint - 1].(Scene_Solid)
	direct := g.stroke == 0 && (r.shape_pass || is_solid && solid.color[3] >= 1) && g.opacity >= 1 && g.mask == 0 && scene_mode(r, g.blend.mode) == .Normal
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
		// The run's transform stretches the pen by at most its longer axis.
		scale := max(math.hypot(rt[0], rt[1]), math.hypot(rt[2], rt[3]))
		b = bounds_grow_f(b, reach * scale)
	}
	// Out to whole pixels, plus one: the content must cover every pixel the
	// glyphs touch fully, or its own edge would cut their coverage twice.
	b = {math.floor(b.minx) - 1, math.floor(b.miny) - 1, math.ceil(b.maxx) + 1, math.ceil(b.maxy) + 1}
	// Drawn as: a layer at the run's opacity whose content is the bounds
	// filled with the paint and whose alpha mask is the glyphs. A run
	// under a mask of its own gets it on an outer layer, which also takes
	// the blend mode, so the blend meets the backdrop.
	masked := g.mask != 0
	mode := scene_mode(r, g.blend.mode)
	if masked {
		outer := Layer_Params{opacity = 1, blend = mode}
		scene_mask_params(s, g.mask, &outer)
		layer_push(ls, c, outer)
	}
	params := Layer_Params{opacity = g.opacity, blend = .Normal if masked else mode, mask_alpha = true}
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
	rt := scene_xf(r, s, run.transform)
	n := int(run.glyphs.count)
	for len(r.paths) < n {
		p: Path
		path_init(&p)
		append(&r.paths, p)
	}
	path_reset(out)
	if n == 0 {
		// The union of nothing: the clip lets nothing through.
		return
	}
	clear(&r.operands)
	for gl, i in s.glyphs[run.glyphs.start:][:n] {
		scene_path_into(s, gl.path, &r.paths[i], transform_multiply(s.transforms[gl.transform - 1], rt))
		append(&r.operands, Bool_Operand{&r.paths[i], .Non_Zero})
	}
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

package ovg

import "core:math"
import "core:slice"
import cv "deps:ocurves"

// Clips by path: each draw's coverage times its clip's, per draw, as PDF
// clips and with no layer. Each clip's coverage, times its parent's, is an
// image rendered just before the first draw that reads it (a child's
// render is a draw under its parent), as small as what is drawn under it;
// images live from that render to their last reader, sharing memory by
// lifetime as layers do, so only the clips open at once hold any. A draw
// reads one texel of its clip's image (shapes.glsl clip_coverage).

// A clip as the canvas records it: its path's coverage as a fill instance
// in drawing coordinates, the clip it narrows (one-based, 0 for none), its
// cell (drawing-coordinate pixels x0, y0, x1, y1 where its coverage may be
// above 0) and the pixels drawn under it (which bound what is rendered).
@(private)
Clip_Record :: struct {
	inst:     Shape_Instance,
	parent:   u32,
	cell:     [4]i32,
	used:     [4]i32,
	// Its path in drawing coordinates: contours [start, end) of the
	// canvas's clip_contours (none for a clip carried from a frame before).
	contours: [2]u32,
}

// A clip image kept from frame to frame, by size: `free_at`, the frame
// command after which it is free again this frame (where images are
// reused within a frame, Backend.transient_by_lifetime unset).
@(private)
Clip_Image :: struct {
	id:        Image_Id,
	w, h:      u32,
	used:      bool,
	free_at:   int,
	last_used: u32,
}

// Frames a clip image is kept unused, as the layer pool keeps its images.
CLIP_IMAGE_KEEP_FRAMES :: 2

@(private = "file")
NO_PIXELS :: [4]i32{max(i32), max(i32), min(i32), min(i32)}

@(private = "file")
pixels_intersect :: #force_inline proc "contextless" (a, b: [4]i32) -> [4]i32 {
	return {max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])}
}

@(private = "file")
pixels_union :: #force_inline proc "contextless" (a, b: [4]i32) -> [4]i32 {
	return {min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])}
}

@(private = "file")
pixels_empty :: #force_inline proc "contextless" (a: [4]i32) -> bool {
	return a[0] >= a[2] || a[1] >= a[3]
}

@(private = "file")
pixels_of :: proc "contextless" (b: Bounds) -> [4]i32 {
	if b.minx > b.maxx || b.miny > b.maxy {
		return NO_PIXELS
	}
	lim :: f32(1 << 30)
	return {i32(math.floor(clamp(b.minx, -lim, lim))), i32(math.floor(clamp(b.miny, -lim, lim))), i32(math.ceil(clamp(b.maxx, -lim, lim))), i32(math.ceil(clamp(b.maxy, -lim, lim)))}
}

// Intersects the current clip with `p` (current units and transform) by
// `rule`: what is drawn after takes its coverage times the path's exact
// coverage, until `restore` drops the clip with the state that holds it.
// A layer pushed under a clip starts unclipped; its composite is what the
// clip cuts, so a group is clipped once, as a whole.
clip_path :: proc(c: ^Canvas, p: ^Path, rule := Fill_Rule.Non_Zero) {
	st := state(c)
	if r, ok := clip_whole_pixels(p, st.transform); ok {
		// A rectangle on whole pixels covers each pixel whole or not at
		// all: the scissor, exactly, with no image.
		t := st.transform
		reset_transform(c)
		intersect_scissor(c, r[0], r[1], r[2] - r[0], r[3] - r[1])
		set_transform(c, t)
		return
	}
	b := &c.scratch.builder
	shape_builder_reset(b)
	// As fill_path's: an edge pixel's coverage within an 8-bit level.
	b.tol = 1.0 / 256
	shape_add_path(b, p, st.transform)
	w, h := render_target_size(c)
	o := c.current_render_origin
	cell := [4]i32{o.x, o.y, o.x + i32(w), o.y + i32(h)}
	if st.clip != 0 {
		cell = pixels_intersect(cell, c.clips[st.clip - 1].cell)
	}
	inst := Shape_Instance{rule = rule}
	contours := [2]u32{u32(len(c.clip_contours.contours)), 0}
	path_append(&c.clip_contours, p, st.transform)
	contours[1] = u32(len(c.clip_contours.contours))
	start := len(c.shape_words)
	if origin, extent, ok := cv.pieces_append(b, &c.shape_words); ok {
		words := c.shape_words[start:]
		inst.words = {u32(start), u32(len(words))}
		inst.transform = {extent, 0, 0, extent, origin.x, origin.y}
		cell = pixels_intersect(cell, pixels_of(device_bounds(words_bounds(words), inst.transform, 1)))
	} else {
		// Nothing to cover: everything is cut away.
		cell = NO_PIXELS
	}
	append(&c.clips, Clip_Record{inst, st.clip, cell, NO_PIXELS, contours})
	st.clip = u32(len(c.clips))
	paint_rows_stale(c)
}

// `p` under `t` as an axis-aligned rectangle on whole pixels (x0, y0, x1,
// y1), when it is one: a single contour of four line segments, each along
// an axis, every corner within a thousandth of a pixel of a whole one.
@(private)
clip_whole_pixels :: proc(p: ^Path, t: Transform2D) -> (r: [4]f32, ok: bool) {
	if len(p.contours) != 1 {
		return
	}
	corners: [6]Vec2
	n := 0
	it := cv.contour_segments(p, 0)
	for seg in cv.segments_next(&it) {
		if seg.kind != .Line || n >= 5 {
			return
		}
		q := transform_point(t, seg.p[0].x, seg.p[0].y)
		if n == 0 || q != corners[n - 1] {
			corners[n] = q
			n += 1
		}
	}
	if n > 1 && corners[n - 1] == corners[0] {
		n -= 1
	}
	if n != 4 {
		return
	}
	whole :: proc "contextless" (v: f32) -> bool {return abs(v - math.round(v)) < 1e-3}
	r = {1e30, 1e30, -1e30, -1e30}
	for i in 0 ..< 4 {
		a, b := corners[i], corners[(i + 1) % 4]
		if (a.x != b.x) == (a.y != b.y) || !whole(a.x) || !whole(a.y) {
			return
		}
		r = {min(r[0], a.x), min(r[1], a.y), max(r[2], a.x), max(r[3], a.y)}
	}
	r = {math.round(r[0]), math.round(r[1]), math.round(r[2]), math.round(r[3])}
	return r, r[0] < r[2] && r[1] < r[3]
}

// Sets the current state's clip to `k` (a frame clip, or 0): the layers'
// targets start unclipped and put their clip back.
@(private)
clip_set :: proc "contextless" (c: ^Canvas, k: u32) {
	if state(c).clip != k {
		state(c).clip = k
		paint_rows_stale(c)
	}
}

// Notes that `inst` is drawn under the current clip: its pixels widen what
// the clip's cell (and each parent's) renders.
@(private)
clip_use :: proc(c: ^Canvas, inst: Shape_Instance) {
	k := state(c).clip
	if k == 0 {
		return
	}
	r := &c.clips[k - 1]
	if inst.marker != .None {
		// A marker: the whole cell.
		r.used = r.cell
		return
	}
	if inst.shape == nil && inst.words.count == 0 {
		return
	}
	// The instance's transform takes shape units to the drawing's.
	b := device_bounds(instance_shape_bounds(inst, c.shape_words[:]), inst.transform, 1 + instance_reach(inst))
	r.used = pixels_union(r.used, pixels_intersect(r.cell, pixels_of(b)))
}

// Renders the frame's clips into images by lifetime, putting each one's
// commands just before the first command that reads it, and names each
// shape draw's clip image (Command.clip_image: a command's draws share one
// clip, push_shape), with each paint row told its clip's cell
// (Params.clip_cell). A clip's cell is cut to what is
// drawn under it and its children; one with nothing under it gets no
// image and cuts its draws away.
@(private)
clip_seal :: proc(c: ^Canvas) {
	n := len(c.clips)
	if n == 0 {
		return
	}
	// What is drawn under a clip reads every parent's coverage too.
	for i := n - 1; i >= 0; i -= 1 {
		r := &c.clips[i]
		r.used = pixels_intersect(r.used, r.cell)
		if pixels_empty(r.used) {
			r.used = NO_PIXELS
		} else if r.parent != 0 {
			pr := &c.clips[r.parent - 1]
			pr.used = pixels_union(pr.used, r.used)
		}
	}
	// A clip that covers whole every pixel drawn under it (and its
	// children's) cuts nothing: its draws and children read its parent
	// instead, and it has no image. A map's neatline around each group of
	// its features is the common case.
	eff := make([]u32, n + 1, context.temp_allocator)
	for k in 0 ..< n {
		r := &c.clips[k]
		r.parent = eff[r.parent]
		eff[k + 1] = u32(k + 1)
		if !pixels_empty(r.used) && clip_covers(&c.clip_contours, r.contours, r.inst.rule, r.used) {
			eff[k + 1] = r.parent
			r.used = NO_PIXELS
		}
	}
	for &pr in c.paints {
		pr.clip = eff[pr.clip]
	}
	// Each clip's lifetime in commands: its first reader (where it is
	// rendered) to its last; a child's render reads its parent.
	first := make([]int, n, context.temp_allocator)
	last := make([]int, n, context.temp_allocator)
	slice.fill(first, max(int))
	slice.fill(last, -1)
	for cmd, ci in c.commands {
		d, is_draw := cmd.type.(Cmd_Draw_Shapes)
		if !is_draw {
			continue
		}
		for inst in c.shapes[d.instances.start:][:d.instances.count] {
			if k := c.paints[inst.paint].clip; k != 0 {
				first[k - 1] = min(first[k - 1], ci)
				last[k - 1] = max(last[k - 1], ci)
			}
		}
	}
	for k := n - 1; k >= 0; k -= 1 {
		if p := c.clips[k].parent; p != 0 && first[k] != max(int) {
			first[p - 1] = min(first[p - 1], first[k])
			last[p - 1] = max(last[p - 1], first[k])
		}
	}
	// Images: a fresh one per clip where the backend shares memory by
	// lifetime, else one whose last reader has passed.
	c.clip_frame += 1
	for &img in c.clip_pool {
		img.used = false
		img.free_at = -1
	}
	image_of := make([]Image_Id, n, context.temp_allocator)
	again := !c.backend.transient_by_lifetime
	// By first reader, then index: a parent before its children.
	by_first := make([dynamic][2]int, 0, n, context.temp_allocator)
	for k in 0 ..< n {
		if first[k] != max(int) && !pixels_empty(c.clips[k].used) {
			append(&by_first, [2]int{first[k], k})
		}
	}
	slice.sort_by(by_first[:], proc(a, b: [2]int) -> bool {return a[0] < b[0] || a[0] == b[0] && a[1] < b[1]})
	order := make([]int, len(by_first), context.temp_allocator)
	for fk, i in by_first {
		order[i] = fk[1]
	}
	for k in order {
		r := c.clips[k].used
		// Sized to its cell where memory is lent by lifetime; else rounded
		// up, so an image serves clips of near sizes.
		w, h := u32(r[2] - r[0]), u32(r[3] - r[1])
		if again {
			w, h = clip_bucket(w), clip_bucket(h)
		}
		at := -1
		for img, i in c.clip_pool {
			if img.w == w && img.h == h && (!img.used || again && img.free_at < first[k]) {
				at = i
				break
			}
		}
		if at < 0 {
			id, _ := create_image_empty(c, w, h, .RGBA8, {.Premultiplied, .Nearest, .Transient})
			append(&c.clip_pool, Clip_Image{id = id, w = w, h = h})
			at = len(c.clip_pool) - 1
		}
		img := &c.clip_pool[at]
		img.used, img.free_at, img.last_used = true, last[k], c.clip_frame
		image_of[k] = img.id
	}
	for i := 0; i < len(c.clip_pool); {
		if !c.clip_pool[i].used && c.clip_frame - c.clip_pool[i].last_used > CLIP_IMAGE_KEEP_FRAMES {
			delete_image(c, c.clip_pool[i].id)
			unordered_remove(&c.clip_pool, i)
		} else {
			i += 1
		}
	}
	// The paint rows read their clip's cell; a clip without an image cuts
	// its draws away.
	for &pr in c.paints {
		if k := pr.clip; k != 0 {
			r := c.clips[k - 1].used
			pr.clip_cell = {f32(r[0]), f32(r[1]), f32(r[2]), f32(r[3])} if image_id_valid(image_of[k - 1]) else {}
		}
	}
	// The renders' paint rows: white, each under its clip's parent.
	white := make([]u32, n, context.temp_allocator)
	for k in order {
		params := default_params()
		params.shader_type = .Fill_Color
		params.inner_col, params.outer_col = {1, 1, 1, 1}, {1, 1, 1, 1}
		params.stroke_mult, params.stroke_thr = 1, -1
		if p := c.clips[k].parent; p != 0 {
			params.clip = p
			r := c.clips[p - 1].used
			params.clip_cell = {f32(r[0]), f32(r[1]), f32(r[2]), f32(r[3])}
		}
		white[k] = add_paint(c, params)
	}
	// The commands again: each clip rendered before its first reader, onto
	// the target that is current there.
	body := c.commands
	c.commands = c.clip_body
	c.clip_body = body
	clear(&c.commands)
	target := Cmd_Set_Render_Target{nil, {}, c.motion_blur}
	next := 0
	for cmd, ci in c.clip_body {
		for next < len(order) && first[order[next]] == ci {
			k := order[next]
			next += 1
			r := c.clips[k].used
			info, _ := image_store_info(&c.images, image_of[k])
			append(&c.commands, Command{type = Cmd_Set_Render_Target{image_of[k], {r[0], r[1]}, false}})
			_ = info
			append(&c.commands, Command{type = Cmd_Clear_Rect{u32(r[0]), u32(r[1]), u32(r[2] - r[0]), u32(r[3] - r[1]), TRANSPARENT}, composite_operation = composite_state_from_op(.Copy)})
			inst := c.clips[k].inst
			if inst.words.count > 0 {
				inst.paint = white[k]
				append(&c.shapes, inst)
				if c.motion_blur {
					append(&c.motions, Shape_Motion{})
				}
				parent_image := Image_Id{}
				if p := c.clips[k].parent; p != 0 {
					parent_image = image_of[p - 1]
				}
				append(&c.commands, Command{type = Cmd_Draw_Shapes{{u32(len(c.shapes) - 1), 1}, 0}, composite_operation = composite_state_from_op(.Source_Over), clip_image = parent_image})
			}
			append(&c.commands, Command{type = target})
		}
		if t, is_target := cmd.type.(Cmd_Set_Render_Target); is_target {
			target = t
		}
		out := cmd
		if d, is_draw := cmd.type.(Cmd_Draw_Shapes); is_draw && d.instances.count > 0 {
			if k := c.paints[c.shapes[d.instances.start].paint].clip; k != 0 {
				out.clip_image = image_of[k - 1]
			}
		}
		append(&c.commands, out)
	}
	clear(&c.clip_body)
}

// Whether the fill of contours `cs` (of `p`) by `rule` covers the pixels
// `r` whole: no outline enters them (a line by its exact crossing, a curve
// by its bounds, which can only answer no too often) and their centre is
// inside (ocurves' winding), so every point is.
@(private = "file")
clip_covers :: proc(p: ^Path, cs: [2]u32, rule: Fill_Rule, r: [4]i32) -> bool {
	if cs[0] >= cs[1] {
		return false
	}
	b := Bounds{f32(r[0]), f32(r[1]), f32(r[2]), f32(r[3])}
	enters :: proc "contextless" (q: [4][2]f32, line: bool, r: Bounds) -> bool {
		lo, hi := cv.cubic_bounds(q)
		if hi.x < r.minx || lo.x > r.maxx || hi.y < r.miny || lo.y > r.maxy {
			return false
		}
		if !line {
			return true
		}
		// The line from a to b against the rectangle (Liang-Barsky), its
		// edges counting as inside.
		a, d := q[0], q[3] - q[0]
		t0, t1: f32 = 0, 1
		for k in 0 ..< 4 {
			pk, qk: f32
			switch k {
			case 0: pk, qk = -d.x, a.x - r.minx
			case 1: pk, qk = d.x, r.maxx - a.x
			case 2: pk, qk = -d.y, a.y - r.miny
			case 3: pk, qk = d.y, r.maxy - a.y
			}
			if pk == 0 {
				if qk < 0 {
					return false
				}
				continue
			}
			t := qk / pk
			if pk < 0 {
				t0 = max(t0, t)
			} else {
				t1 = min(t1, t)
			}
			if t0 > t1 {
				return false
			}
		}
		return true
	}
	for i in int(cs[0]) ..< int(cs[1]) {
		it := cv.contour_segments(p, i)
		for seg in cv.segments_next(&it) {
			if enters({seg.p[0], seg.p[1], seg.p[2], seg.p[3]}, seg.kind == .Line, b) {
				return false
			}
		}
		// An open contour closes by a line, as fills close it.
		if a, e := p.pts[it.at - 1], p.pts[p.contours[i].start]; a != e {
			if enters({a, a, e, e}, true, b) {
				return false
			}
		}
	}
	w, _ := cv.contours_winding(p, int(cs[0]), int(cs[1] - cs[0]), {f64(b.minx + b.maxx) / 2, f64(b.miny + b.maxy) / 2})
	return cv.fill_inside(w, rule)
}

// A clip image's side for `n` pixels: the next power of two (at least 16),
// so images serve clips of near sizes, frame after frame.
@(private = "file")
clip_bucket :: proc "contextless" (n: u32) -> u32 {
	s := u32(16)
	for s < n {
		s *= 2
	}
	return s
}

// After a frame, before its arrays are cleared: the clips the states still
// hold, kept as the next frame's table, and their words as a temp copy the
// next frame's words start with (the records' word ranges index it).
@(private)
clip_carry :: proc(c: ^Canvas) -> []u32 {
	if len(c.clips) == 0 {
		return nil
	}
	keep := make([]u32, len(c.clips) + 1, context.temp_allocator)
	held := false
	for s in c.states {
		for k := s.clip; k != 0 && keep[k] == 0; k = c.clips[k - 1].parent {
			keep[k] = 1
			held = true
		}
	}
	if !held {
		clear(&c.clips)
		return nil
	}
	count := 0
	for r, i in c.clips {
		if keep[i + 1] != 0 {
			count += int(r.inst.words.count)
		}
	}
	words := make([]u32, count, context.temp_allocator)
	at, kept := 0, 0
	for i in 0 ..< len(c.clips) {
		if keep[i + 1] == 0 {
			continue
		}
		r := c.clips[i]
		r.parent = keep[r.parent] if r.parent != 0 else 0
		r.used = NO_PIXELS
		r.contours = {}
		if n := int(r.inst.words.count); n > 0 {
			copy(words[at:], c.shape_words[r.inst.words.start:][:n])
			r.inst.words.start = u32(at)
			at += n
		}
		c.clips[kept] = r
		kept += 1
		keep[i + 1] = u32(kept)
	}
	resize(&c.clips, kept)
	for &s in c.states {
		if s.clip != 0 {
			s.clip = keep[s.clip]
		}
	}
	return words
}

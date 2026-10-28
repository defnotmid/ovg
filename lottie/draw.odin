package lottie

import "core:math"

import vg ".."
import cv "deps:ocurves"

// Evaluating and drawing a `Document` (lottie.odin). Properties are
// interpolated at the frame each draw (no cached state), shape geometry is
// built per layer into the renderer's scratch buffers (cubic contours, then
// trimmed), and paints walk the shape tree bottom to top. Masks, mattes,
// blend modes, precomp opacity and effects (filter layers) go through the
// layer stack; text layers are laid out and drawn by text.odin. The
// document is read-only while drawing, so many canvases (threads) can draw
// one document at once, each with its own `Renderer`.

// Replaces properties of the layers named `name` (their `nm`; every layer
// with that name, in any composition) while drawing: how a host animates
// parts of an animation.
Override :: struct {
	name:      string,
	// Applied in the layer's own coordinates, inside its transform; layers
	// parented to it follow.
	transform: Maybe(vg.Transform2D),
	// Replaces the layer's opacity.
	opacity:   Maybe(f32),
	// Replace the color of the layer's fills / strokes (gradients
	// included; their opacity still applies) and of a solid layer, and
	// reach the layers of a precomp.
	fill:      Maybe(vg.Color),
	stroke:    Maybe(vg.Color),
	// false hides the layer; true shows a hidden one.
	visible:   Maybe(bool),
	// Replaces a text layer's string (every document keyframe).
	text:      Maybe(string),
}

// Per-canvas drawing state, reused across draws (no allocation once warm).
Renderer :: struct {
	path:     vg.Path,
	// Shape geometry of the layer being drawn, in each item's own space.
	using geo: cv.Contours,
	// Per document shape: its contours (geometry items).
	geometry: [dynamic]vg.Range,
	// Per document shape, for paints whose geometry nothing animates (no
	// keyframed path, transform, stroke width or dash in their scope, no
	// trim or repeater in their layer): the paint's shape, built the first
	// time it is drawn and drawn after that (`shaped`: 1 static, -1 not, 0
	// unchecked); dropped when another document is bound.
	shapes:     [dynamic]vg.Shape,
	shaped:     [dynamic]i8,
	scratch:    vg.Shape_Scratch,
	// Repeater scratch: the geometry its copies repeat (gather).
	copy_verbs:  [dynamic]vg.Verb,
	copy_coords: [dynamic]vg.Vec2,
	// Merge paths: the operands' geometry, one input each, and the boolean's
	// scratch; merges that fell back to concatenation (an inconsistent
	// arrangement) during the last draw, which tests expect to be 0.
	merge_in:        cv.Contours,
	merge_inputs:    [dynamic]cv.Bool_Input,
	merge:           cv.Bool_Scratch,
	merge_fallbacks: int,
	// Trim scratch: segment lengths.
	lengths:  [dynamic]f32,
	values:   [dynamic]f32,
	stops:    [dynamic]vg.Gradient_Stop,
	dashes:   [dynamic]f32,
	// Canvas images of the bound document's bitmaps (renderer_bind).
	images:   [dynamic]vg.Image_Id,
	// Per document layer: the override index, or -1.
	override_of: [dynamic]i32,
	// Text layers' fonts (set before drawing; borrowed). Without it text
	// draws with a collection of only the bundled default face.
	fonts:       ^vg.Font_Collection,
	// Families of text layers not in `fonts` (drawn with the fallback)
	// during the last draw; strings borrowed from the document.
	missing:     [dynamic]string,
	// The limits (`Document.limits`) the last draw reached; what
	// they guard was cut short.
	limited:     bit_set[vg.Limit],
	text:        Text_Scratch,
}

renderer_destroy :: proc(r: ^Renderer, c: ^vg.Canvas) {
	vg.path_destroy(&r.path)
	cv.contours_destroy(&r.geo)
	cv.contours_destroy(&r.merge_in)
	delete(r.merge_inputs)
	cv.bool_scratch_destroy(&r.merge)
	delete(r.geometry)
	delete(r.copy_verbs)
	delete(r.copy_coords)
	delete(r.lengths)
	delete(r.values)
	delete(r.stops)
	delete(r.dashes)
	delete(r.override_of)
	delete(r.missing)
	text_scratch_destroy(&r.text)
	drop_shapes(r)
	delete(r.shapes)
	delete(r.shaped)
	vg.shape_scratch_destroy(&r.scratch)
	renderer_unbind(r, c)
	delete(r.images)
	r^ = {}
}

// Makes the canvas images of `doc`'s image assets for drawing it on `c`,
// releasing those of the document bound before and the shapes its paints
// kept (render the frames that drew them first). A host drawing several
// documents keeps a renderer for each.
renderer_bind :: proc(r: ^Renderer, c: ^vg.Canvas, doc: ^Document) {
	renderer_unbind(r, c)
	drop_shapes(r)
	resize(&r.images, len(doc.bitmaps))
	for &b, i in doc.bitmaps {
		// Shared by pixel address: players of several recording canvases
		// share one texture.
		r.images[i], _ = vg.create_image_shared(c, vg.image_source_rgba(b.pixels, b.width, b.height), u64(uintptr(raw_data(b.pixels))), stable = true)
	}
}

// Releases the bound document's images (before destroying the document).
renderer_unbind :: proc(r: ^Renderer, c: ^vg.Canvas) {
	for id in r.images {
		if vg.image_id_valid(id) {
			vg.delete_image(c, id)
		}
	}
	clear(&r.images)
}

// Draws `doc` at `frame` (comp frames: `frame_at` maps seconds)
// into its `width x height` coordinate system, mapped by `transform`
// before the canvas's current transform. Masks, mattes and blending need
// the layer stack begun for the frame (`layer_stack_begin`, with a root
// layer when `doc.uses_blend` and the target is the screen). Nothing is
// clipped to the composition's bounds. `overrides` change layers by name
// (the last one for a name wins).
draw :: proc(c: ^vg.Canvas, ls: ^vg.Layer_Stack, r: ^Renderer, doc: ^Document, frame: f32, transform := vg.TRANSFORM_IDENTITY, overrides: []Override = nil) {
	if len(doc.comps) == 0 {
		return
	}
	if len(r.geometry) < len(doc.shapes) {
		resize(&r.geometry, len(doc.shapes))
	}
	if len(r.shapes) < len(doc.shapes) {
		resize(&r.shapes, len(doc.shapes))
		resize(&r.shaped, len(doc.shapes))
	}
	if len(overrides) > 0 {
		resize(&r.override_of, len(doc.layers))
		for &o, li in r.override_of {
			o = -1
			for ov, k in overrides {
				if ov.name == doc.layers[li].name {
					o = i32(k)
				}
			}
		}
	}
	clear(&r.missing)
	r.merge_fallbacks = 0
	d := Draw{c = c, ls = ls, r = r, doc = doc, overrides = overrides}
	vg.budget_init(&d.budget, &doc.limits)
	vg.save(c)
	vg.apply_transform(c, transform)
	draw_comp(&d, 0, frame, 0)
	vg.restore(c)
	r.limited = d.budget.hit
}

@(private)
Draw :: struct {
	c:            ^vg.Canvas,
	ls:           ^vg.Layer_Stack,
	r:            ^Renderer,
	doc:          ^Document,
	overrides:    []Override,
	// The fill / stroke override of the layer being drawn (or of the
	// precomp layer it is in).
	fill, stroke: Maybe(vg.Color),
	budget:       vg.Budget,
	// The layer being drawn has no trim or repeater (its paints may own
	// their shapes).
	unmodified:   bool,
}

// Frees the paints' shapes (drawn frames must have been rendered).
@(private)
drop_shapes :: proc(r: ^Renderer) {
	for &s in r.shapes {
		vg.shape_destroy(&s)
	}
	clear(&r.shapes)
	clear(&r.shaped)
}

// Whether any document layer has name `name` (an override's target).
has_layer :: proc(doc: ^Document, name: string) -> bool {
	for &l in doc.layers {
		if l.name == name {
			return true
		}
	}
	return false
}

@(private)
override :: proc(d: ^Draw, li: i32) -> ^Override {
	if len(d.overrides) == 0 {
		return nil
	}
	k := d.r.override_of[li]
	return &d.overrides[k] if k >= 0 else nil
}

// ---- evaluation --------------------------------------------------------------------

// Evaluates property `idx` at frame `t` into `out` (up to its length);
// returns the property's dimension count (0 when absent: `out` is left).
eval :: proc(doc: ^Document, idx: i32, t: f32, out: []f32) -> int {
	if idx < 0 {
		return 0
	}
	prop := &doc.props[idx]
	n := min(int(prop.dims), len(out))
	if prop.keys.count == 0 {
		copy(out[:n], doc.values[prop.value:][:n])
		return int(prop.dims)
	}
	keys := doc.keys[prop.keys.start:][:prop.keys.count]
	i, u := segment(keys, t)
	k0 := &keys[i]
	if u <= 0 || k0.hold || i + 1 >= len(keys) {
		copy(out[:n], doc.values[k0.value:][:n])
		return int(prop.dims)
	}
	k1 := &keys[i + 1]
	a := doc.values[k0.value:][:n]
	b := doc.values[k1.value:][:n]
	if k0.spatial != NONE && n >= 2 {
		sp := doc.values[k0.spatial:][:4]
		if sp[0] != 0 || sp[1] != 0 || sp[2] != 0 || sp[3] != 0 {
			e := key_ease(doc, k0, 0, u)
			q := spatial_point({a[0], a[1]}, {a[0] + sp[0], a[1] + sp[1]}, {b[0] + sp[2], b[1] + sp[3]}, {b[0], b[1]}, e)
			out[0], out[1] = q.x, q.y
			for d in 2 ..< n {
				out[d] = a[d] + (b[d] - a[d]) * e
			}
			return int(prop.dims)
		}
	}
	for d in 0 ..< n {
		e := key_ease(doc, k0, d, u)
		out[d] = a[d] + (b[d] - a[d]) * e
	}
	return int(prop.dims)
}

eval1 :: proc(doc: ^Document, idx: i32, t: f32, def: f32) -> f32 {
	v := [1]f32{def}
	eval(doc, idx, t, v[:])
	return v[0]
}

eval2 :: proc(doc: ^Document, idx: i32, t: f32, def: vg.Vec2) -> vg.Vec2 {
	v := [2]f32{def.x, def.y}
	if eval(doc, idx, t, v[:]) == 1 {
		v[1] = v[0]
	}
	return {v[0], v[1]}
}

// The key segment holding `t` and the linear progress through it.
@(private)
segment :: proc "contextless" (keys: []Key, t: f32) -> (int, f32) {
	if t <= keys[0].t {
		return 0, 0
	}
	last := len(keys) - 1
	if t >= keys[last].t {
		return last, 0
	}
	lo, hi := 0, last
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if keys[mid].t <= t {
			lo = mid
		} else {
			hi = mid
		}
	}
	span := keys[hi].t - keys[lo].t
	if span <= 0 {
		return hi, 0
	}
	return lo, (t - keys[lo].t) / span
}

@(private)
key_ease :: proc(doc: ^Document, k: ^Key, dim: int, u: f32) -> f32 {
	if k.ease == NONE {
		return u
	}
	e := doc.values[k.ease + 4 * u32(min(dim, int(k.ease_dims) - 1)):][:4]
	return ease(u, e[0], e[1], e[2], e[3])
}

// The cubic bezier timing curve (0,0) (x1,y1) (x2,y2) (1,1) at x = `u`.
ease :: proc "contextless" (u, x1, y1, x2, y2: f32) -> f32 {
	if x1 == y1 && x2 == y2 {
		return u
	}
	bez :: #force_inline proc "contextless" (s, a, b: f32) -> f32 {
		m := 1 - s
		return 3 * m * m * s * a + 3 * m * s * s * b + s * s * s
	}
	cx1, cx2 := clamp(x1, 0, 1), clamp(x2, 0, 1)
	s := u
	solved := false
	for _ in 0 ..< 8 {
		x := bez(s, cx1, cx2) - u
		if abs(x) < 1e-6 {
			solved = true
			break
		}
		m := 1 - s
		dx := 3 * m * m * cx1 + 6 * m * s * (cx2 - cx1) + 3 * s * s * (1 - cx2)
		if abs(dx) < 1e-6 {
			break
		}
		s -= x / dx
		if s < 0 || s > 1 {
			break
		}
	}
	if !solved {
		lo, hi: f32 = 0, 1
		s = u
		for _ in 0 ..< 32 {
			x := bez(s, cx1, cx2)
			if abs(x - u) < 1e-6 {
				break
			}
			if x < u {
				lo = s
			} else {
				hi = s
			}
			s = (lo + hi) * 0.5
		}
	}
	return bez(s, y1, y2)
}

// The point a fraction `e` of the way along the cubic by arc length (AE
// moves along a motion path at the eased speed).
@(private)
spatial_point :: proc "contextless" (p0, p1, p2, p3: vg.Vec2, e: f32) -> vg.Vec2 {
	N :: 24
	lens: [N + 1]f32
	prev := p0
	for i in 1 ..= N {
		q := cv.cubic_at([4]vg.Vec2{p0, p1, p2, p3}, f32(i) / N)
		lens[i] = lens[i - 1] + vg.vec_len(q - prev)
		prev = q
	}
	total := lens[N]
	if total <= 0 {
		return p0 + (p3 - p0) * e
	}
	target := clamp(e, 0, 1) * total
	for i in 1 ..= N {
		if lens[i] >= target {
			seg := lens[i] - lens[i - 1]
			f := (target - lens[i - 1]) / seg if seg > 0 else 0
			return cv.cubic_at([4]vg.Vec2{p0, p1, p2, p3}, (f32(i - 1) + f) / N)
		}
	}
	return p3
}

// The matrix of a transform at `t` and its opacity (0..1).
transform_matrix :: proc(doc: ^Document, idx: i32, t: f32) -> (m: vg.Transform2D, opacity: f32) {
	if idx < 0 {
		return vg.TRANSFORM_IDENTITY, 1
	}
	tr := &doc.transforms[idx]
	a := eval2(doc, tr.anchor, t, {})
	p: vg.Vec2
	if tr.position >= 0 {
		p = eval2(doc, tr.position, t, {})
	} else {
		p = {eval1(doc, tr.position_x, t, 0), eval1(doc, tr.position_y, t, 0)}
	}
	s := eval2(doc, tr.scale, t, {100, 100}) / 100
	r := eval1(doc, tr.rotation, t, 0) * math.RAD_PER_DEG
	sk := eval1(doc, tr.skew, t, 0) * math.RAD_PER_DEG
	opacity = clamp(eval1(doc, tr.opacity, t, 100) / 100, 0, 1)
	m = {s.x, 0, 0, s.y, -a.x * s.x, -a.y * s.y}
	if sk != 0 {
		sa := eval1(doc, tr.skew_axis, t, 0) * math.RAD_PER_DEG
		// Along the axis: turn it onto x, shear, turn back (lottie-web).
		m = vg.transform_multiply(m, vg.transform_rotation(sa))
		m = vg.transform_multiply(m, vg.transform_skew_x(-sk))
		m = vg.transform_multiply(m, vg.transform_rotation(-sa))
	}
	if r != 0 {
		m = vg.transform_multiply(m, vg.transform_rotation(r))
	}
	m[4] += p.x
	m[5] += p.y
	return
}

// A layer's matrix at comp frame `frame`, through its parents.
layer_matrix :: proc(doc: ^Document, li: i32, frame: f32) -> vg.Transform2D {
	d := Draw{doc = doc}
	return layer_matrix_overridden(&d, li, frame)
}

// The same with the override transforms of the layer and its parents.
@(private)
layer_matrix_overridden :: proc(d: ^Draw, li: i32, frame: f32) -> vg.Transform2D {
	local :: proc(d: ^Draw, li: i32, frame: f32) -> vg.Transform2D {
		m, _ := transform_matrix(d.doc, d.doc.layers[li].transform, frame)
		if ov := override(d, li); ov != nil {
			if t, ok := ov.transform.?; ok {
				m = vg.transform_multiply(t, m)
			}
		}
		return m
	}
	m := local(d, li, frame)
	p := d.doc.layers[li].parent
	for depth := 0; p >= 0 && depth < 64; depth += 1 {
		m = vg.transform_multiply(m, local(d, p, frame))
		p = d.doc.layers[p].parent
	}
	return m
}

// ---- compositions and layers -------------------------------------------------------

@(private)
draw_comp :: proc(d: ^Draw, comp: i32, frame: f32, depth: int) {
	if depth > 16 {
		return
	}
	cm := &d.doc.comps[comp]
	// The first layer is on top.
	for k := i32(cm.layers.count) - 1; k >= 0; k -= 1 {
		li := i32(cm.layers.start) + k
		l := &d.doc.layers[li]
		hidden := l.hidden
		if ov := override(d, li); ov != nil {
			if v, ok := ov.visible.?; ok {
				hidden = !v
			}
		}
		if hidden || l.matte_source {
			continue
		}
		draw_matted(d, li, frame, depth)
	}
}

// Draws a layer through its track matte (which may have its own).
@(private)
draw_matted :: proc(d: ^Draw, li: i32, frame: f32, depth: int) {
	l := &d.doc.layers[li]
	if frame < l.in_frame || frame >= l.out_frame {
		return
	}
	if l.matte == .None || l.matte_layer < 0 || l.matte_layer == li || depth > 32 {
		draw_layer(d, li, frame, depth, false)
		return
	}
	invert := l.matte == .Alpha_Inverted || l.matte == .Luma_Inverted
	vg.layer_push(d.ls, d.c, {mask_alpha = l.matte == .Alpha || l.matte == .Alpha_Inverted, mask_invert = invert, blend = l.blend})
	draw_layer(d, li, frame, depth, true)
	vg.layer_mask_begin(d.ls, d.c)
	vg.save(d.c)
	vg.set_global_alpha(d.c, 1)
	draw_matted(d, l.matte_layer, frame, depth + 1)
	vg.restore(d.c)
	vg.layer_mask_end(d.ls, d.c)
	vg.layer_pop(d.ls, d.c)
}

@(private)
draw_layer :: proc(d: ^Draw, li: i32, frame: f32, depth: int, blended: bool) {
	doc, c := d.doc, d.c
	l := &doc.layers[li]
	if l.kind == .Null || l.kind == .Other || !vg.budget_take(&d.budget, .Lottie_Layers) {
		return
	}
	// Effects as filter layers, innermost first (stack-held until the pops).
	fx: [MAX_EFFECTS]Effect_Filter
	n_fx := 0
	for ei in l.effects.start ..< l.effects.start + l.effects.count {
		if effect_filter(doc, &doc.effects[ei], frame, &fx[n_fx]) {
			n_fx += 1
		}
	}
	// Layer properties key in comp frames (lottie-web); the start time
	// shifts only a precomp's content.
	lt := frame
	_, opacity := transform_matrix(doc, l.transform, lt)
	ov := override(d, li)
	if ov != nil {
		if o, ok := ov.opacity.?; ok {
			opacity = clamp(o, 0, 1)
		}
	}
	if opacity <= 0 {
		return
	}
	vg.save(c)
	defer vg.restore(c)
	vg.apply_transform(c, layer_matrix_overridden(d, li, frame))
	// This layer's paint overrides (a precomp's reach its layers).
	fill, stroke := d.fill, d.stroke
	defer d.fill, d.stroke = fill, stroke
	if ov != nil {
		if f, ok := ov.fill.?; ok {
			d.fill = f
		}
		if st, ok := ov.stroke.?; ok {
			d.stroke = st
		}
	}
	pushes := 0
	// Opacity applies to the composite of a precomp's layers, or of a
	// shape layer's overlapping paints.
	group_opacity := opacity < 1 && (l.kind == .Precomp || l.kind == .Text || n_fx > 0 || (l.kind == .Shape && l.paints > 1))
	if (l.blend != .Normal && !blended) || group_opacity {
		vg.layer_push(d.ls, c, {opacity = opacity if group_opacity else 1, blend = l.blend if !blended else .Normal})
		pushes += 1
	}
	if !group_opacity {
		vg.set_global_alpha(c, vg.state(c).alpha * opacity)
	}
	if masks_apply(doc, l) {
		if !push_masks(d, l, lt) {
			for _ in 0 ..< pushes {
				vg.layer_pop(d.ls, c)
			}
			return
		}
		pushes += 1
	}
	// Filters apply before masks (SVG order, as lottie-web).
	for k := n_fx - 1; k >= 0; k -= 1 {
		vg.layer_push(d.ls, c, {filter = &fx[k].filter})
		pushes += 1
	}
	switch l.kind {
	case .Text:
		draw_text(d, l, li, lt)
	case .Shape:
		cv.contours_clear(&d.r.geo)
		d.unmodified = !has_modifier(doc, l.shapes)
		build_items(d, l.shapes, lt)
		draw_items(d, l.shapes, 0, l.shapes.count, lt)
	case .Solid:
		p := &d.r.path
		vg.path_reset(p)
		vg.path_rect(p, 0, 0, l.w, l.h)
		vg.fill_path(c, p, vg.paint_color(d.fill.? or_else l.color))
	case .Image:
		draw_image(d, l)
	case .Precomp:
		if l.ref > 0 {
			child := (frame - l.start) / l.stretch
			if l.time_remap >= 0 {
				child = eval1(doc, l.time_remap, lt, 0) * doc.fps
			}
			if l.w > 0 && l.h > 0 {
				vg.intersect_scissor(c, 0, 0, l.w, l.h)
			}
			draw_comp(d, l.ref, child, depth + 1)
		}
	case .Null, .Other:
	}
	for _ in 0 ..< pushes {
		vg.layer_pop(d.ls, c)
	}
}

@(private)
draw_image :: proc(d: ^Draw, l: ^Layer) {
	if l.ref < 0 {
		return
	}
	c, r := d.c, d.r
	if int(l.ref) >= len(r.images) || !vg.image_id_valid(r.images[l.ref]) {
		return // not bound to the document (renderer_bind)
	}
	b := &d.doc.bitmaps[l.ref]
	id := r.images[l.ref]
	w, h := f32(b.width), f32(b.height)
	if l.w > 0 && l.h > 0 {
		// @2x and downscaled assets stretch to their asset size (lottie-web).
		w, h = l.w, l.h
	}
	p := &r.path
	vg.path_reset(p)
	vg.path_rect(p, 0, 0, w, h)
	vg.fill_path(c, p, vg.paint_image(id, 0, 0, w, h, 0))
}

// Whether a layer's masks cut it: masks of mode None (paths for effects)
// and masks without a path do not (lottie-web shows the layer whole).
@(private)
masks_apply :: proc(doc: ^Document, l: ^Layer) -> bool {
	for m in doc.masks[l.masks.start:][:l.masks.count] {
		if m.mode != .None && m.path >= 0 {
			return true
		}
	}
	return false
}

// Pushes a layer masked by the layer's masks; false when nothing would show.
@(private)
push_masks :: proc(d: ^Draw, l: ^Layer, lt: f32) -> bool {
	doc, c, ls, r := d.doc, d.c, d.ls, d.r
	inv, ok := inverse(vg.current_transform(c))
	if !ok {
		return false
	}
	vg.layer_push(ls, c, {mask_alpha = true})
	vg.layer_mask_begin(ls, c)
	vg.save(c)
	vg.set_global_alpha(c, 1)
	// The canvas in layer coordinates: the complement of a mask is this
	// quad minus its path.
	w, h := f32(ls.width), f32(ls.height)
	quad := [4]vg.Vec2{vg.transform_point(inv, 0, 0), vg.transform_point(inv, w, 0), vg.transform_point(inv, w, h), vg.transform_point(inv, 0, h)}
	first := true
	p := &r.path
	for mi in l.masks.start ..< l.masks.start + l.masks.count {
		m := &doc.masks[mi]
		if m.mode == .None || m.path < 0 {
			continue
		}
		o := clamp(eval1(doc, m.opacity, lt, 100) / 100, 0, 1)
		if first && m.mode != .Add {
			quad_path(p, quad)
			vg.fill_path(c, p, vg.paint_color(vg.WHITE))
		}
		first = false
		// The covered area: the path, or (inverted) the rest of the canvas.
		vg.path_reset(p)
		if m.inverted {
			quad_path(p, quad)
		}
		append_path(p, doc, m.path, lt, m.inverted)
		paint := vg.paint_color({1, 1, 1, o})
		paint.fill_rule = .Even_Odd if m.inverted else .Non_Zero
		x := eval1(doc, m.expansion, lt, 0)
		switch m.mode {
		case .Add:
			vg.set_composite_operation(c, .Source_Over)
			vg.fill_path(c, p, paint)
			if x != 0 && !m.inverted {
				st := vg.paint_color({1, 1, 1, o})
				st.stroke.line_width = 2 * abs(x)
				st.stroke.line_join = .Round
				if x < 0 {
					st.flavor = vg.Color{1, 1, 1, 1}
					vg.set_composite_operation(c, .Destination_Out)
				}
				vg.stroke_path(c, p, st)
			}
		case .Subtract:
			vg.set_composite_operation(c, .Destination_Out)
			vg.fill_path(c, p, paint)
		case .Intersect:
			// Keep the covered area: remove what lies outside it.
			vg.set_composite_operation(c, .Destination_Out)
			vg.path_reset(p)
			if !m.inverted {
				quad_path(p, quad)
			}
			append_path(p, doc, m.path, lt, !m.inverted)
			out := vg.paint_color(vg.WHITE)
			out.fill_rule = .Non_Zero if m.inverted else .Even_Odd
			vg.fill_path(c, p, out)
			if o < 1 {
				// A translucent intersection keeps that much of the rest.
				vg.path_reset(p)
				if m.inverted {
					quad_path(p, quad)
				}
				append_path(p, doc, m.path, lt, m.inverted)
				part := vg.paint_color({1, 1, 1, 1 - o})
				part.fill_rule = paint.fill_rule
				vg.fill_path(c, p, part)
			}
		case .None:
		}
	}
	vg.restore(c)
	vg.layer_mask_end(ls, c)
	return true
}

@(private)
quad_path :: proc(p: ^vg.Path, q: [4]vg.Vec2) {
	vg.path_reset(p)
	vg.path_move_to(p, q[0].x, q[0].y)
	for i in 1 ..< 4 {
		vg.path_line_to(p, q[i].x, q[i].y)
	}
	vg.path_close(p)
}

@(private)
inverse :: proc "contextless" (t: vg.Transform2D) -> (vg.Transform2D, bool) {
	if vg.transform_singular(t) {
		return {}, false
	}
	return vg.transform_inverse(t), true
}

// Appends path property `idx` at `t` to `p`; `hole` marks it a hole (its
// antialiased edge then faces the right way inside a canvas quad).
@(private)
append_path :: proc(p: ^vg.Path, doc: ^Document, idx: i32, t: f32, hole := false) {
	a, b, f, ok := path_at(doc, idx, t)
	if !ok || a.count == 0 {
		return
	}
	pa := doc.points[a.start:][:a.count * 3]
	pb := doc.points[b.start:][:b.count * 3]
	pt :: #force_inline proc "contextless" (pa, pb: []vg.Vec2, i: u32, f: f32) -> vg.Vec2 {
		return pa[i] + (pb[i] - pa[i]) * f
	}
	v0 := pt(pa, pb, 0, f)
	vg.path_move_to(p, v0.x, v0.y)
	n := a.count
	segs := n if a.closed else n - 1
	for s in 0 ..< segs {
		i, j := s, (s + 1) % n
		v := pt(pa, pb, 3 * i, f)
		vo := v + pt(pa, pb, 3 * i + 2, f)
		w := pt(pa, pb, 3 * j, f)
		wi := w + pt(pa, pb, 3 * j + 1, f)
		vg.path_bezier_to(p, vo.x, vo.y, wi.x, wi.y, w.x, w.y)
	}
	if a.closed {
		vg.path_close(p)
	}
	if hole {
		vg.path_solidity(p, .Hole)
	}
}

// The two path values around `t` and the fraction between them (b == a
// when the path holds).
@(private)
path_at :: proc(doc: ^Document, idx: i32, t: f32) -> (a, b: Path, f: f32, ok: bool) {
	if idx < 0 {
		return
	}
	prop := &doc.props[idx]
	if prop.keys.count == 0 {
		a = doc.paths[prop.value]
		return a, a, 0, true
	}
	keys := doc.keys[prop.keys.start:][:prop.keys.count]
	i, u := segment(keys, t)
	k0 := &keys[i]
	a = doc.paths[k0.value]
	if u <= 0 || k0.hold || i + 1 >= len(keys) {
		return a, a, 0, true
	}
	b = doc.paths[keys[i + 1].value]
	if b.count != a.count {
		return a, a, 0, true
	}
	return a, b, key_ease(doc, k0, 0, u), true
}

// ---- shape geometry ----------------------------------------------------------------

// Builds the geometry of items (and their groups) into the renderer's
// contours, applying trims to the items above them.
@(private)
build_items :: proc(d: ^Draw, items: vg.Range, t: f32) {
	doc, r := d.doc, d.r
	for i in items.start ..< items.start + items.count {
		sh := &doc.shapes[i]
		r.geometry[i] = {}
		if .Hidden in sh.flags {
			continue
		}
		#partial switch sh.kind {
		case .Group:
			build_items(d, sh.children, t)
		case .Rect, .Ellipse, .Path, .Star:
			first := u32(len(r.contours))
			build_geometry(d, sh, t)
			r.geometry[i] = {first, u32(len(r.contours)) - first}
		case .Trim:
			trim(d, sh, {items.start, i - items.start}, t)
		case .Merge:
			first := u32(len(r.contours))
			merge(d, sh, {items.start, i - items.start}, t)
			r.geometry[i] = {first, u32(len(r.contours)) - first}
		}
	}
}

// Merge paths (as Skottie): each geometry item above the merge in its
// scope (in file order, through visible groups under their transforms) is
// an operand; mode 1 concatenates them, 2-5 combine them in one boolean
// (union, the first minus the rest, intersection, odd count). The operands'
// own geometry is cleared, so paints see only the result. A boolean that
// runs out of budget or doesn't hold together falls back to concatenation.
@(private)
merge :: proc(d: ^Draw, sh: ^Shape, items: vg.Range, t: f32) {
	r := d.r
	cv.contours_clear(&r.merge_in)
	clear(&r.merge_inputs)
	collect :: proc(d: ^Draw, items: vg.Range, m: vg.Transform2D, t: f32) {
		doc, r := d.doc, d.r
		for i in items.start ..< items.start + items.count {
			s := &doc.shapes[i]
			if .Hidden in s.flags {
				continue
			}
			#partial switch s.kind {
			case .Group:
				g, _ := transform_matrix(doc, s.transform, t)
				collect(d, s.children, vg.transform_multiply(g, m), t)
			case .Rect, .Ellipse, .Path, .Star, .Merge:
				g := r.geometry[i]
				first := u32(len(r.merge_in.contours))
				for ci in g.start ..< g.start + g.count {
					ct := r.contours[ci]
					at :: proc(m: vg.Transform2D, p: vg.Vec2) -> vg.Vec2 {return vg.transform_point(m, p.x, p.y)}
					cv.contours_begin(&r.merge_in, at(m, r.pts[ct.start]))
					for k in 0 ..< ct.segs {
						q := r.pts[ct.start + 3 * k:][:4]
						cv.contours_segment(&r.merge_in, r.kinds[ct.seg + k], at(m, q[1]), at(m, q[2]), at(m, q[3]))
					}
					cv.contours_end(&r.merge_in, ct.closed, false)
				}
				append(&r.merge_inputs, cv.Bool_Input{first, u32(len(r.merge_in.contours)) - first, .Non_Zero})
				r.geometry[i] = {}
			}
		}
	}
	collect(d, items, vg.TRANSFORM_IDENTITY, t)
	src := &r.merge_in
	if mode := sh.stops; mode >= 2 && len(r.merge_inputs) > 0 {
		ops := [5]cv.Bool_Op{.Union, .Union, .Difference, .Intersection, .Xor}
		left := d.budget.limits[.Boolean_Steps] - d.budget.used[.Boolean_Steps]
		steps := left
		err := cv.bool_run(&r.merge, &r.merge_in, r.merge_inputs[:], ops[mode - 1], &steps)
		d.budget.used[.Boolean_Steps] += left - max(steps, 0)
		switch err {
		case .None:
			src = &r.merge.out
		case .Limit:
			d.budget.hit += {.Boolean_Steps}
		case .Inconsistent:
			r.merge_fallbacks += 1
		case .Non_Finite:
			return
		}
	}
	for ct in src.contours {
		cv.contours_begin(&r.geo, src.pts[ct.start])
		for k in 0 ..< ct.segs {
			q := src.pts[ct.start + 3 * k:][:4]
			cv.contours_segment(&r.geo, src.kinds[ct.seg + k], q[1], q[2], q[3])
		}
		cv.contours_end(&r.geo, ct.closed, false)
	}
}

@(private)
build_geometry :: proc(d: ^Draw, sh: ^Shape, t: f32) {
	doc, r := d.doc, d.r
	reversed := .Reversed in sh.flags
	K :: 1 - vg.KAPPA90
	switch sh.kind {
	case .Rect:
		c := eval2(doc, sh.props[POSITION], t, {})
		s := eval2(doc, sh.props[SIZE], t, {})
		rad := min(eval1(doc, sh.props[ROUNDNESS], t, 0), abs(s.x) / 2, abs(s.y) / 2)
		l, tp, rt, b := c.x - s.x / 2, c.y - s.y / 2, c.x + s.x / 2, c.y + s.y / 2
		// From the top of the right edge, clockwise (as AE).
		cv.contours_begin(&r.geo, {rt, tp + rad})
		cv.contours_line(&r.geo, {rt, b - rad})
		if rad > 0 {
			cv.contours_cubic(&r.geo, {rt, b - rad * K}, {rt - rad * K, b}, {rt - rad, b})
		}
		cv.contours_line(&r.geo, {l + rad, b})
		if rad > 0 {
			cv.contours_cubic(&r.geo, {l + rad * K, b}, {l, b - rad * K}, {l, b - rad})
		}
		cv.contours_line(&r.geo, {l, tp + rad})
		if rad > 0 {
			cv.contours_cubic(&r.geo, {l, tp + rad * K}, {l + rad * K, tp}, {l + rad, tp})
		}
		cv.contours_line(&r.geo, {rt - rad, tp})
		if rad > 0 {
			cv.contours_cubic(&r.geo, {rt - rad * K, tp}, {rt, tp + rad * K}, {rt, tp + rad})
		}
		cv.contours_end(&r.geo, true, reversed)
	case .Ellipse:
		c := eval2(doc, sh.props[POSITION], t, {})
		s := eval2(doc, sh.props[SIZE], t, {}) / 2
		k := vg.Vec2{s.x * vg.KAPPA90, s.y * vg.KAPPA90}
		// From the top, clockwise.
		cv.contours_begin(&r.geo, {c.x, c.y - s.y})
		cv.contours_cubic(&r.geo, {c.x + k.x, c.y - s.y}, {c.x + s.x, c.y - k.y}, {c.x + s.x, c.y})
		cv.contours_cubic(&r.geo, {c.x + s.x, c.y + k.y}, {c.x + k.x, c.y + s.y}, {c.x, c.y + s.y})
		cv.contours_cubic(&r.geo, {c.x - k.x, c.y + s.y}, {c.x - s.x, c.y + k.y}, {c.x - s.x, c.y})
		cv.contours_cubic(&r.geo, {c.x - s.x, c.y - k.y}, {c.x - k.x, c.y - s.y}, {c.x, c.y - s.y})
		cv.contours_end(&r.geo, true, reversed)
	case .Path:
		a, b, f, ok := path_at(doc, sh.props[PATH], t)
		if !ok || a.count == 0 {
			return
		}
		pa := doc.points[a.start:][:a.count * 3]
		pb := doc.points[b.start:][:b.count * 3]
		pt :: #force_inline proc "contextless" (pa, pb: []vg.Vec2, i: u32, f: f32) -> vg.Vec2 {
			return pa[i] + (pb[i] - pa[i]) * f
		}
		n := a.count
		cv.contours_begin(&r.geo, pt(pa, pb, 0, f))
		segs := n if a.closed else n - 1
		for s in 0 ..< segs {
			i, j := s, (s + 1) % n
			v := pt(pa, pb, 3 * i, f)
			w := pt(pa, pb, 3 * j, f)
			cv.contours_cubic(&r.geo, v + pt(pa, pb, 3 * i + 2, f), w + pt(pa, pb, 3 * j + 1, f), w)
		}
		cv.contours_end(&r.geo, a.closed, false)
	case .Star:
		c := eval2(doc, sh.props[POSITION], t, {})
		rot := eval1(doc, sh.props[STAR_ROTATION], t, 0) * math.RAD_PER_DEG
		points := f32(vg.budget_cap(&d.budget, .Star_Points, int(math.floor(clamp(eval1(doc, sh.props[STAR_POINTS], t, 5), 0, 1e9)))))
		outer := eval1(doc, sh.props[STAR_OUTER_RADIUS], t, 0)
		outer_round := eval1(doc, sh.props[STAR_OUTER_ROUNDNESS], t, 0) / 100
		inner := eval1(doc, sh.props[STAR_INNER_RADIUS], t, 0)
		inner_round := eval1(doc, sh.props[STAR_INNER_ROUNDNESS], t, 0) / 100
		if points < 1 {
			return
		}
		polygon := .Polygon in sh.flags
		n := int(points) if polygon else int(points) * 2
		step := 2 * math.PI / f32(n)
		ang := -math.PI / 2 + rot
		// Vertices with their tangent handles (lottie-web's construction).
		vert :: proc "contextless" (c: vg.Vec2, rad, ang, perim, round: f32) -> (v, tin, tout: vg.Vec2) {
			v = {rad * math.cos(ang), rad * math.sin(ang)}
			o: vg.Vec2
			if l := vg.vec_len(v); l > 0 {
				o = {v.y / l, -v.x / l}
			}
			v += c
			return v, v + o * (perim * round), v - o * (perim * round)
		}
		perim_of :: proc "contextless" (rad: f32, n: int, polygon: bool) -> f32 {
			return 2 * math.PI * rad / f32(n * (4 if polygon else 2))
		}
		first_v, first_in, prev_out: vg.Vec2
		for i in 0 ..< n {
			long := polygon || i % 2 == 0
			rad := outer if long else inner
			round := outer_round if long else inner_round
			v, tin, tout := vert(c, rad, ang, perim_of(rad, n, polygon), round)
			if i == 0 {
				first_v, first_in = v, tin
				cv.contours_begin(&r.geo, v)
			} else {
				cv.contours_cubic(&r.geo, prev_out, tin, v)
			}
			prev_out = tout
			ang += step
		}
		cv.contours_cubic(&r.geo, prev_out, first_in, first_v)
		cv.contours_end(&r.geo, true, reversed)
	case .Group, .Fill, .Stroke, .Gradient_Fill, .Gradient_Stroke, .Trim, .Repeater, .Merge, .Ignored:
	}
}

// Every geometry item in `items` (and their groups), in order.
@(private)
scope_each :: proc(d: ^Draw, items: vg.Range, data: rawptr, fn: proc(d: ^Draw, item: u32, data: rawptr)) {
	for i in items.start ..< items.start + items.count {
		sh := &d.doc.shapes[i]
		if .Hidden in sh.flags {
			continue
		}
		#partial switch sh.kind {
		case .Group:
			scope_each(d, sh.children, data, fn)
		case .Rect, .Ellipse, .Path, .Star, .Merge:
			fn(d, i, data)
		}
	}
}

@(private)
Trim :: struct {
	// Windows along the length (fractions; a second one when it wraps).
	w:        [2][2]f32,
	count:      int,
	// One path along all the shapes: its total length and how much of it
	// came before the contour being trimmed.
	sequential: bool,
	total:      f32,
	at:         f32,
}

// Trims the geometry of `scope` (the items above the trim).
@(private)
trim :: proc(d: ^Draw, sh: ^Shape, scope: vg.Range, t: f32) {
	doc := d.doc
	s := eval1(doc, sh.props[TRIM_START], t, 0) / 100
	e := eval1(doc, sh.props[TRIM_END], t, 100) / 100
	o := eval1(doc, sh.props[TRIM_OFFSET], t, 0) / 360
	s, e = clamp(s, 0, 1), clamp(e, 0, 1)
	if s > e {
		s, e = e, s
	}
	tr: Trim
	if e - s >= 1 - 1e-6 {
		return
	}
	if e - s > 1e-6 {
		o -= math.floor(o)
		s += o
		e += o
		if s >= 1 {
			s -= 1
			e -= 1
		}
		if e > 1 {
			tr.w = {{s, 1}, {0, e - 1}}
			tr.count = 2
		} else {
			tr.w[0] = {s, e}
			tr.count = 1
		}
	}
	if .Trim_Sequential in sh.flags {
		tr.sequential = true
		scope_each(d, scope, &tr, proc(d: ^Draw, item: u32, data: rawptr) {
			tr := (^Trim)(data)
			g := d.r.geometry[item]
			for ci in g.start ..< g.start + g.count {
				tr.total += contour_length(d.r, ci)
			}
		})
	}
	scope_each(d, scope, &tr, proc(d: ^Draw, item: u32, data: rawptr) {
		tr := (^Trim)(data)
		r := d.r
		g := r.geometry[item]
		first := u32(len(r.contours))
		for ci in g.start ..< g.start + g.count {
			trim_contour(r, ci, tr)
		}
		r.geometry[item] = {first, u32(len(r.contours)) - first}
	})
}

// Fills r.lengths with the contour's segment lengths; returns their sum.
@(private)
contour_length :: proc(r: ^Renderer, ci: u32) -> f32 {
	ct := r.contours[ci]
	clear(&r.lengths)
	total: f32
	for s in 0 ..< ct.segs {
		p := r.pts[ct.start + 3 * s:][:4]
		l := cubic_length(p[0], p[1], p[2], p[3])
		append(&r.lengths, l)
		total += l
	}
	return total
}

// A cubic's length by CHORDS chords, as cubic_param walks it.
@(private)
cubic_length :: proc "contextless" (p0, p1, p2, p3: vg.Vec2) -> f32 {
	N :: CHORDS
	total: f32
	prev := p0
	for i in 1 ..= N {
		q := cv.cubic_at([4]vg.Vec2{p0, p1, p2, p3}, f32(i) / N)
		total += vg.vec_len(q - prev)
		prev = q
	}
	return total
}

@(private)
CHORDS :: 16

// The parameter at arc length `l` along a cubic of length `total`
// (cubic_length: the same chords, so l = total lands on t = 1).
@(private)
cubic_param :: proc "contextless" (p0, p1, p2, p3: vg.Vec2, l, total: f32) -> f32 {
	if l <= 0 || total <= 0 {
		return 0
	}
	if l >= total {
		return 1
	}
	N :: CHORDS
	acc: f32
	prev := p0
	for i in 1 ..= N {
		q := cv.cubic_at([4]vg.Vec2{p0, p1, p2, p3}, f32(i) / N)
		seg := vg.vec_len(q - prev)
		if acc + seg >= l {
			f := (l - acc) / seg if seg > 0 else 0
			return (f32(i - 1) + f) / N
		}
		acc += seg
		prev = q
	}
	return 1
}

// Appends the parts of contour `ci` inside the trim's windows.
@(private)
trim_contour :: proc(r: ^Renderer, ci: u32, tr: ^Trim) {
	total := contour_length(r, ci)
	// Windows in this contour's length units.
	base: f32 = 0
	scale := total
	if tr.sequential {
		base = tr.at
		scale = tr.total
		tr.at += total
	}
	if total <= 0 || scale <= 0 || tr.count == 0 {
		return
	}
	ct := r.contours[ci]
	joined := false
	for wi in 0 ..< tr.count {
		a := tr.w[wi][0] * scale - base
		b := tr.w[wi][1] * scale - base
		a, b = max(a, 0), min(b, total)
		if b <= a {
			continue
		}
		// A closed contour's wrap-around continues the previous part.
		cont := joined && ct.closed && a <= 0 && !tr.sequential
		if !cont {
			cv.contours_begin(&r.geo, r.pts[ct.start])
		}
		first := true
		acc: f32
		for s in 0 ..< ct.segs {
			l := r.lengths[s]
			s0, s1 := acc, acc + l
			acc = s1
			if s1 <= a || s0 >= b {
				continue
			}
			src := r.pts[ct.start + 3 * s:][:4]
			p := [4]vg.Vec2{src[0], src[1], src[2], src[3]}
			t0 := cubic_param(p[0], p[1], p[2], p[3], a - s0, l) if a > s0 else 0
			t1 := cubic_param(p[0], p[1], p[2], p[3], b - s0, l) if b < s1 else 1
			// A whole segment is copied as it is.
			q := p if t0 == 0 && t1 == 1 else cv.cubic_range(p, t0, t1)
			if first && !cont {
				r.pts[len(r.pts) - 1] = q[0]
			}
			first = false
			cv.contours_segment(&r.geo, r.kinds[ct.seg + s], q[1], q[2], q[3])
		}
		joined = b >= total
	}
}

// ---- effects -----------------------------------------------------------------------

// A layer effect as a filter, its primitives and tables held inline.
@(private)
Effect_Filter :: struct {
	filter: vg.Filter,
	prims:  [5]vg.Filter_Primitive,
	refs:   [3]vg.Filter_Ref,
	// Two 16-entry sRGB <-> linear tables, then tritone tables.
	values: [2 * GAMMA_N + 9]f32,
}

@(private)
GAMMA_N :: 16

// Effect `e`'s parameters at `t`, by its kind's slots (EFFECTS):
// each as many floats as the control has, over the table's default.
@(private)
effect_values :: proc(doc: ^Document, e: ^Effect, t: f32) -> (v: [EFFECT_MAX_PARAMS][4]f32) {
	info := EFFECTS
	row := info[e.kind]
	for k in 0 ..< int(row.count) {
		v[k] = row.params[k].default
		if u32(k) < e.params.count {
			eval(doc, doc.effect_params[e.params.start + u32(k)], t, v[k][:])
		}
	}
	return
}

// Builds the filter of effect `e` at `t` into `fx` (as lottie-web's SVG
// effects); false when it changes nothing.
@(private)
effect_filter :: proc(doc: ^Document, e: ^Effect, t: f32, fx: ^Effect_Filter) -> bool {
	n := 0
	prim :: proc(fx: ^Effect_Filter, n: ^int, op: vg.Filter_Op, in1 := vg.Filter_Ref{}) -> ^vg.Filter_Primitive {
		p := &fx.prims[n^]
		p^ = {op = op, in1 = in1}
		for &f in p.transfer {
			f = vg.TRANSFER_IDENTITY
		}
		n^ += 1
		return p
	}
	// Gray from the average of linear RGB (lottie-web's linearRGB matrix),
	// with sRGB tables around a matrix in the sRGB filter.
	gray :: proc(fx: ^Effect_Filter, n: ^int, alpha: f32) {
		for i in 0 ..< GAMMA_N {
			v := f32(i) / (GAMMA_N - 1)
			fx.values[i] = vg.srgb_to_linear(v)
			fx.values[GAMMA_N + i] = vg.linear_to_srgb(v)
		}
		to_lin := prim(fx, n, .Component_Transfer, {kind = .Source_Graphic})
		for c in 0 ..< 3 {
			to_lin.transfer[c] = {kind = .Table, first = 0, count = GAMMA_N}
		}
		avg := prim(fx, n, .Color_Matrix)
		third :: f32(1.0 / 3.0)
		avg.color_matrix = {third, third, third, 0, 0, third, third, third, 0, 0, third, third, third, 0, 0, 0, 0, 0, alpha, 0}
		to_srgb := prim(fx, n, .Component_Transfer)
		for c in 0 ..< 3 {
			to_srgb.transfer[c] = {kind = .Table, first = GAMMA_N, count = GAMMA_N}
		}
	}
	fx.filter = {srgb = true}
	v := effect_values(doc, e, t)
	color :: proc "contextless" (v: [4]f32) -> vg.Color {
		return {v[0], v[1], v[2], 1}
	}
	switch e.kind {
	case .Fill:
		col, o := color(v[0]), v[1].x
		p := prim(fx, &n, .Color_Matrix)
		p.color_matrix = {0, 0, 0, 0, col.r, 0, 0, 0, 0, col.g, 0, 0, 0, 0, col.b, 0, 0, 0, o, 0}
	case .Tint:
		black, white, amount := color(v[0]), color(v[1]), v[2].x / 100
		if amount == 0 {
			return false
		}
		// Gray at `amount`, then mapped black -> white, both over the source.
		gray(fx, &n, amount)
		m := prim(fx, &n, .Color_Matrix)
		m.color_matrix = {white.r - black.r, 0, 0, 0, black.r, white.g - black.g, 0, 0, 0, black.g, white.b - black.b, 0, 0, 0, black.b, 0, 0, 0, 1, 0}
		fx.refs = {{kind = .Source_Graphic}, {kind = .Result, index = 2}, {kind = .Result, index = 3}}
		merge := prim(fx, &n, .Merge)
		merge.merge_count = 3
		fx.filter.merge_refs = fx.refs[:]
	case .Tritone:
		cols := [3]vg.Color{color(v[0]), color(v[1]), color(v[2])}
		gray(fx, &n, 1)
		tones := prim(fx, &n, .Component_Transfer)
		for c in 0 ..< 3 {
			for k in 0 ..< 3 {
				fx.values[2 * GAMMA_N + c * 3 + k] = (transmute([4]f32)cols[k])[c]
			}
			tones.transfer[c] = {kind = .Table, first = u16(2 * GAMMA_N + c * 3), count = 3}
		}
	case .Drop_Shadow:
		col := color(v[0])
		col.a = clamp(v[1].x / 255, 0, 1)
		angle := (v[2].x - 90) * math.RAD_PER_DEG
		dist := v[3].x
		sigma := max(v[4].x, 0) / 4
		if col.a <= 0 {
			return false
		}
		p := prim(fx, &n, .Drop_Shadow)
		p.color = col
		p.std = {sigma, sigma}
		p.dx, p.dy = dist * math.cos(angle), dist * math.sin(angle)
		fx.filter.srgb = false
	case .Gaussian_Blur:
		sigma := max(v[0].x, 0) * 0.3
		dims := int(v[1].x)
		std := [2]f32{0 if dims == 3 else sigma, 0 if dims == 2 else sigma}
		if std == {} {
			return false
		}
		p := prim(fx, &n, .Gaussian_Blur)
		p.std = std
		fx.filter.srgb = false
	}
	fx.filter.primitives = fx.prims[:n]
	fx.filter.values = fx.values[:]
	return n > 0
}

// ---- painting ----------------------------------------------------------------------

// Draws items [lo, hi) of a group, bottom (last) to top.
@(private)
draw_items :: proc(d: ^Draw, items: vg.Range, lo, hi: u32, t: f32) {
	doc, c := d.doc, d.c
	for k := i64(hi) - 1; k >= i64(lo); k -= 1 {
		i := items.start + u32(k)
		sh := &doc.shapes[i]
		if .Hidden in sh.flags {
			continue
		}
		#partial switch sh.kind {
		case .Group:
			m, opacity := transform_matrix(doc, sh.transform, t)
			if opacity <= 0 {
				continue
			}
			vg.save(c)
			vg.apply_transform(c, m)
			// Overlapping paints fade as one (a group's opacity).
			group := opacity < 1 && sh.paints > 1
			if group {
				vg.layer_push(d.ls, c, {opacity = opacity})
			} else {
				vg.set_global_alpha(c, vg.state(c).alpha * opacity)
			}
			draw_items(d, sh.children, 0, sh.children.count, t)
			if group {
				vg.layer_pop(d.ls, c)
			}
			vg.restore(c)
		case .Fill, .Stroke, .Gradient_Fill, .Gradient_Stroke:
			paint(d, sh, items, u32(k), t)
		case .Repeater:
			repeat(d, sh, items, lo, u32(k), t)
			return
		}
	}
}

// A repeater's copies at one frame.
@(private)
Repeat :: struct {
	copies:          int,
	offset, rot:     f32,
	so, eo:          f32,
	anchor, pos, sc: vg.Vec2,
}

// Evaluates repeater `sh` at `t`, taking its copies from the budget
// (nested repeaters multiply); false when it makes none.
@(private)
repeat_eval :: proc(d: ^Draw, sh: ^Shape, t: f32) -> (rep: Repeat, ok: bool) {
	doc := d.doc
	rep.copies = int(math.ceil(clamp(eval1(doc, sh.props[COPIES], t, 1), 0, 1000)))
	rep.offset = eval1(doc, sh.props[COPY_OFFSET], t, 0)
	rep.copies = vg.budget_take_up_to(&d.budget, .Repeater_Copies, rep.copies)
	if rep.copies <= 0 {
		return
	}
	rep.so, rep.eo, rep.sc = 1, 1, {1, 1}
	if tr := sh.transform; tr >= 0 {
		x := &doc.transforms[tr]
		rep.anchor = eval2(doc, x.anchor, t, {})
		rep.pos = eval2(doc, x.position, t, {})
		rep.sc = eval2(doc, x.scale, t, {100, 100}) / 100
		rep.rot = eval1(doc, x.rotation, t, 0) * math.RAD_PER_DEG
		rep.so = eval1(doc, x.start_opacity, t, 100) / 100
		rep.eo = eval1(doc, x.end_opacity, t, 100) / 100
	}
	return rep, true
}

// Copy n's transform, `offset` steps before it, as lottie-web composes it:
// turned about the anchor, then scaled about it, then moved, each by n +
// offset steps. Scale steps multiply; the offset's fraction is one step
// scaled linearly from 1 (inverse for a negative offset).
@(private)
repeat_copy :: proc "contextless" (rep: ^Repeat, n: int) -> vg.Transform2D {
	a, s := rep.anchor, rep.sc
	whole := math.trunc(rep.offset)
	k := f32(n) + rep.offset
	sc := vg.Vec2{math.pow(s.x, whole + f32(n)), math.pow(s.y, whole + f32(n))}
	if f := rep.offset - whole; f != 0 {
		part := s + (1 - s) * (1 - abs(f))
		sc = sc * part if f > 0 else sc / part
	}
	m := vg.transform_multiply(vg.transform_translation(-a.x, -a.y), vg.transform_rotation(rep.rot * k))
	m = vg.transform_multiply(m, vg.transform_scaling(sc.x, sc.y))
	m[4] += a.x + rep.pos.x * k
	m[5] += a.y + rep.pos.y * k
	return m
}

// Draws items [lo, k) once per repeater copy.
@(private)
repeat :: proc(d: ^Draw, sh: ^Shape, items: vg.Range, lo, k: u32, t: f32) {
	doc, c := d.doc, d.c
	rep, ok := repeat_eval(d, sh, t)
	if !ok {
		return
	}
	copies, so, eo := rep.copies, rep.so, rep.eo
	below := .Repeat_Below in sh.flags
	// A copy with overlapping paints fades as one.
	group := count_paints(doc, {items.start + lo, k - lo}) > 1
	for j in 0 ..< copies {
		// Above: copy 0 on top; below: copy 0 at the bottom. The opacity
		// ramps from the top copy (start) to the bottom one (end).
		n := j if below else copies - 1 - j
		pos := copies - 1 - n if below else n
		m := repeat_copy(&rep, n)
		alpha := so + (eo - so) * (f32(pos) / f32(copies - 1) if copies > 1 else 0)
		alpha = clamp(alpha, 0, 1)
		if alpha <= 0 {
			continue
		}
		vg.save(c)
		vg.apply_transform(c, m)
		if group && alpha < 1 {
			vg.layer_push(d.ls, c, {opacity = alpha})
		} else {
			vg.set_global_alpha(c, vg.state(c).alpha * alpha)
		}
		draw_items(d, items, lo, k, t)
		if group && alpha < 1 {
			vg.layer_pop(d.ls, c)
		}
		vg.restore(c)
	}
}

// Appends the geometry above item `k` of a group (its groups' too, in
// their transforms relative to `rel`) to r.path. A repeater replaces the
// group's geometry above it with its copies (lottie-web clones those items
// into the group), so paints below it fill every copy.
@(private)
gather :: proc(d: ^Draw, items: vg.Range, k: u32, rel: vg.Transform2D, t: f32) {
	doc, r := d.doc, d.r
	first_verb, first_coord := len(r.path.verbs), len(r.path.coords)
	for i in items.start ..< items.start + k {
		sh := &doc.shapes[i]
		if .Hidden in sh.flags {
			continue
		}
		#partial switch sh.kind {
		case .Repeater:
			gather_copies(d, sh, first_verb, first_coord, rel, t)
		case .Group:
			// A group's opacity fades only its own paints (lottie-web): a
			// paint above it still fills its paths.
			m, _ := transform_matrix(doc, sh.transform, t)
			gather(d, sh.children, sh.children.count, vg.transform_multiply(m, rel), t)
		case .Rect, .Ellipse, .Path, .Star, .Merge:
			g := r.geometry[i]
			vg.path_append_contours(&r.path, &r.geo, g.start, g.count, rel)
		}
	}
}

// Replaces r.path from (first_verb, first_coord) on, geometry in the
// group's space mapped by `rel`, with one copy per repeater copy.
@(private)
gather_copies :: proc(d: ^Draw, sh: ^Shape, first_verb, first_coord: int, rel: vg.Transform2D, t: f32) {
	r := d.r
	p := &r.path
	inv, invertible := inverse(rel)
	rep, ok := repeat_eval(d, sh, t)
	if !ok || !invertible {
		resize(&p.verbs, first_verb)
		resize(&p.coords, first_coord)
		return
	}
	clear(&r.copy_verbs)
	clear(&r.copy_coords)
	append(&r.copy_verbs, ..p.verbs[first_verb:])
	append(&r.copy_coords, ..p.coords[first_coord:])
	resize(&p.verbs, first_verb)
	resize(&p.coords, first_coord)
	for n in 0 ..< rep.copies {
		// The copy's transform acts in the group's space: undo `rel`, apply
		// it, redo `rel`.
		m := vg.transform_multiply(vg.transform_multiply(inv, repeat_copy(&rep, n)), rel)
		append(&p.verbs, ..r.copy_verbs[:])
		for q in r.copy_coords {
			append(&p.coords, vg.transform_point(m, q.x, q.y))
		}
	}
	if len(p.coords) > 0 {
		p.last_pos = p.coords[len(p.coords) - 1]
	}
}

@(private)
paint :: proc(d: ^Draw, sh: ^Shape, items: vg.Range, k: u32, t: f32) {
	doc, c, r := d.doc, d.c, d.r
	opacity := clamp(eval1(doc, sh.props[OPACITY], t, 100) / 100, 0, 1)
	if opacity <= 0 {
		return
	}
	stroke := sh.kind == .Stroke || sh.kind == .Gradient_Stroke
	width: f32
	if stroke {
		width = eval1(doc, sh.props[WIDTH], t, 0)
		if width <= 0 {
			return
		}
	}
	paint: vg.Paint
	if over, ok := (d.stroke if stroke else d.fill).?; ok {
		paint = vg.paint_color({over.r, over.g, over.b, over.a * opacity})
	} else if sh.kind == .Fill || sh.kind == .Stroke {
		col := [4]f32{0, 0, 0, 1}
		eval(doc, sh.props[COLOR], t, col[:])
		if col[0] > 1 || col[1] > 1 || col[2] > 1 {
			// 0..255 components (old exports).
			col.rgb /= 255
		}
		paint = vg.paint_color({clamp(col[0], 0, 1), clamp(col[1], 0, 1), clamp(col[2], 0, 1), opacity})
	} else {
		has: bool
		paint, has = gradient(d, sh, t, opacity)
		if !has {
			return
		}
	}
	if !stroke {
		paint.fill_rule = .Even_Odd if .Even_Odd in sh.flags else .Non_Zero
	} else {
		stroke_settings(d, sh, &paint, width, t)
	}
	// The paint's geometry: its own shape when nothing in it animates.
	i := items.start + k
	if r.shaped[i] == 0 {
		r.shaped[i] = 1 if d.unmodified && scope_static(doc, sh, items, k) else -1
	}
	owned := &r.shapes[i]
	if r.shaped[i] > 0 && owned.data == nil {
		vg.path_reset(&r.path)
		gather(d, items, k, vg.TRANSFORM_IDENTITY, t)
		ok: bool
		if stroke {
			owned^, ok, _ = vg.shape_from_stroke(&r.path, paint.stroke, search = false, scratch = &r.scratch)
		} else {
			owned^, ok = vg.shape_from_path(&r.path, search = false, scratch = &r.scratch)
		}
		if !ok {
			r.shaped[i] = -1
		}
	}
	if owned.data != nil {
		if stroke {
			paint.fill_rule = .Non_Zero
		}
		vg.fill_shape(c, owned, paint)
		return
	}
	vg.path_reset(&r.path)
	gather(d, items, k, vg.TRANSFORM_IDENTITY, t)
	if len(r.path.verbs) == 0 {
		return
	}
	if stroke {
		vg.stroke_path(c, &r.path, paint)
	} else {
		vg.fill_path(c, &r.path, paint)
	}
}

// A stroke paint's settings at `t`.
@(private)
stroke_settings :: proc(d: ^Draw, sh: ^Shape, paint: ^vg.Paint, width, t: f32) {
	doc, r := d.doc, d.r
	paint.stroke.line_width = width
	paint.stroke.line_join = sh.join
	paint.stroke.miter_limit = sh.miter
	vg.paint_set_line_cap(paint, sh.cap)
	if sh.dash.count > 0 {
		clear(&r.dashes)
		offset: f32
		for di in sh.dash.start ..< sh.dash.start + sh.dash.count {
			ds := doc.dashes[di]
			v := eval1(doc, ds.prop, t, 0)
			if ds.offset {
				offset = v
			} else {
				append(&r.dashes, max(v, 0))
			}
		}
		sum: f32
		for v in r.dashes {
			sum += v
		}
		if len(r.dashes) > 0 && sum > 0 {
			if len(r.dashes) % 2 == 1 {
				// An odd list repeats (SVG).
				n := len(r.dashes)
				for i in 0 ..< n {
					append(&r.dashes, r.dashes[i])
				}
			}
			paint.stroke.dash = r.dashes[:]
			paint.stroke.dash_offset = offset
		}
	}
}

// Whether a trim or repeater is in `items` (or their groups).
@(private)
has_modifier :: proc(doc: ^Document, items: vg.Range) -> bool {
	for i in items.start ..< items.start + items.count {
		sh := &doc.shapes[i]
		#partial switch sh.kind {
		case .Trim, .Repeater:
			return true
		case .Group:
			if has_modifier(doc, sh.children) {
				return true
			}
		}
	}
	return false
}

// Whether paint `sh`'s geometry (items [0, k) of its group, their groups'
// transforms, a stroke's width and dashes) is the same at every frame.
@(private)
scope_static :: proc(doc: ^Document, sh: ^Shape, items: vg.Range, k: u32) -> bool {
	fixed :: proc(doc: ^Document, idx: i32) -> bool {
		return idx < 0 || doc.props[idx].keys.count <= 1
	}
	items_fixed :: proc(doc: ^Document, items: vg.Range, k: u32) -> bool {
		for i in items.start ..< items.start + k {
			s := &doc.shapes[i]
			#partial switch s.kind {
			case .Group:
				if s.transform >= 0 {
					x := &doc.transforms[s.transform]
					for p in ([?]i32{x.anchor, x.position, x.position_x, x.position_y, x.scale, x.rotation, x.skew, x.skew_axis}) {
						if !fixed(doc, p) {
							return false
						}
					}
				}
				if !items_fixed(doc, s.children, s.children.count) {
					return false
				}
			case .Rect, .Ellipse, .Path, .Star:
				for p in s.props {
					if !fixed(doc, p) {
						return false
					}
				}
			}
		}
		return true
	}
	if sh.kind == .Stroke || sh.kind == .Gradient_Stroke {
		if !fixed(doc, sh.props[WIDTH]) {
			return false
		}
		for di in sh.dash.start ..< sh.dash.start + sh.dash.count {
			if !fixed(doc, doc.dashes[di].prop) {
				return false
			}
		}
	}
	return items_fixed(doc, items, k)
}

// A gradient fill / stroke's paint: color stops merged with opacity stops.
@(private)
gradient :: proc(d: ^Draw, sh: ^Shape, t: f32, opacity: f32) -> (vg.Paint, bool) {
	doc, r := d.doc, d.r
	idx := sh.props[COLOR]
	if idx < 0 || sh.stops == 0 {
		return {}, false
	}
	dims := int(doc.props[idx].dims)
	resize(&r.values, dims)
	eval(doc, idx, t, r.values[:])
	v := r.values[:]
	nc := min(int(sh.stops), dims / 4)
	colors := v[:nc * 4]
	alphas := v[nc * 4:]
	na := len(alphas) / 2
	clear(&r.stops)
	// Merge the two sorted offset lists. A stop keeps its own color (or
	// opacity), so coincident stops make hard edges.
	ic, ia := 0, 0
	for ic < nc || ia < na {
		col: vg.Color
		off: f32
		if ia >= na || (ic < nc && colors[ic * 4] <= alphas[ia * 2]) {
			off = colors[ic * 4]
			col = {colors[ic * 4 + 1], colors[ic * 4 + 2], colors[ic * 4 + 3], 1}
			if ia < na && alphas[ia * 2] == off {
				col.a = alphas[ia * 2 + 1]
				ia += 1
			} else {
				col.a = stop_alpha(alphas, na, off)
			}
			ic += 1
		} else {
			off = alphas[ia * 2]
			col = stop_color(colors, nc, off)
			col.a = alphas[ia * 2 + 1]
			ia += 1
		}
		col.a *= opacity
		append(&r.stops, vg.Gradient_Stop{clamp(off, 0, 1), col})
	}
	s := eval2(doc, sh.props[START], t, {})
	e := eval2(doc, sh.props[END], t, {})
	if .Radial not_in sh.flags {
		return vg.paint_linear_gradient_stops(s.x, s.y, e.x, e.y, r.stops[:]), true
	}
	rad := vg.vec_len(e - s)
	h := clamp(eval1(doc, sh.props[HIGHLIGHT], t, 0) / 100, -0.99, 0.99)
	a := eval1(doc, sh.props[HIGHLIGHT_ANGLE], t, 0) * math.RAD_PER_DEG
	ang := math.atan2(e.y - s.y, e.x - s.x) + a
	f := s + vg.Vec2{math.cos(ang), math.sin(ang)} * (rad * h)
	return vg.paint_radial_gradient_focal_stops(s.x, s.y, rad, f.x, f.y, 0, r.stops[:]), true
}

@(private)
stop_color :: proc "contextless" (colors: []f32, n: int, off: f32) -> vg.Color {
	if n == 0 {
		return vg.BLACK
	}
	at :: #force_inline proc "contextless" (colors: []f32, i: int) -> vg.Color {
		return {colors[i * 4 + 1], colors[i * 4 + 2], colors[i * 4 + 3], 1}
	}
	if off <= colors[0] {
		return at(colors, 0)
	}
	for i in 1 ..< n {
		o0, o1 := colors[(i - 1) * 4], colors[i * 4]
		if off <= o1 {
			f := (off - o0) / (o1 - o0) if o1 > o0 else 1
			a, b := at(colors, i - 1), at(colors, i)
			return {a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f, 1}
		}
	}
	return at(colors, n - 1)
}

@(private)
stop_alpha :: proc "contextless" (alphas: []f32, n: int, off: f32) -> f32 {
	if n == 0 {
		return 1
	}
	if off <= alphas[0] {
		return alphas[1]
	}
	for i in 1 ..< n {
		o0, o1 := alphas[(i - 1) * 2], alphas[i * 2]
		if off <= o1 {
			f := (off - o0) / (o1 - o0) if o1 > o0 else 1
			return alphas[(i - 1) * 2 + 1] + (alphas[i * 2 + 1] - alphas[(i - 1) * 2 + 1]) * f
		}
	}
	return alphas[(n - 1) * 2 + 1]
}

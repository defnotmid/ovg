package ovg

import "core:math"

// Offscreen layers for group effects, like Skia's saveLayer: drawing between
// `layer_push` and `layer_pop` goes to a transparent layer, which is then
// blurred, clipped by a path, masked and composited onto what was there
// with an opacity (SVG group opacity, feGaussianBlur, clip-path, mask).
//
// A layer covers only its window: the device-space bounds of what was drawn
// into it, grown by how far its filter and blur reach, cut to its clip path,
// its mask and the canvas. The window is known only at the pop, so drawing
// is recorded against a stand-in target the size of the canvas, and the pop
// points those commands at the window's image, placed at the window's
// corner (`Cmd_Set_Render_Target.origin`): everything is still drawn in
// canvas coordinates. A layer with nothing to show drops what it recorded. Wide blurs downscale on the grid a whole-canvas
// layer would use, so the pixels match a full-frame layer's. A layer that a
// child blends with (`blend` other than Normal) covers the whole canvas.
// Inside an offscreen image (a pattern tile or `layer_image_begin`) the
// "canvas" is that image: layers are sized and placed within it.
//
// The stack keeps a pool of layer images, sized in steps (see
// `layer_bucket`) and reused across frames; images unused for a while are
// freed. Commands run in order at flush, so a layer released mid-frame can
// be reused by later commands of the same frame.

Layer_Params :: struct {
	// The layer's group opacity, 0 meaning 1. The global alpha is not a
	// group opacity: it applies to each draw recorded into the layer.
	opacity:   f32,
	// Gaussian blur of the layer, standard deviation in current units.
	blur:      f32,
	// Clip to this path (current units, current transform); nil for none.
	clip_path: ^Path,
	clip_rule: Fill_Rule,
	// SVG filter effects, applied before the clip and mask (SVG order:
	// filter, clipping, masking, opacity). Must stay valid until the pop.
	filter:    ^Filter,
	// The mask (`layer_mask_begin`) counts by its alpha instead of its
	// luminance times alpha (SVG mask-type="alpha"; luminance is SVG's
	// default).
	mask_alpha: bool,
	// The layer shows where the mask is transparent instead (inverted
	// track mattes).
	mask_invert: bool,
	// How the layer combines with what is under it (CSS mix-blend-mode).
	// Anything but Normal needs the backdrop as an image: begin the stack
	// with `root_layer` when the target is the screen.
	blend:     Blend_Mode,
}

@(private)
Pooled_Layer :: struct {
	id:        Image_Id,
	w, h:      u32,
	in_use:    bool,
	// `Layer_Stack.frame` when last acquired.
	last_used: u32,
	// `Layer_Stack.releases` when last released.
	released:  u32,
}

// Where a layer's image sits on the canvas: it covers device pixels
// [x, x + w) x [y, y + h), inside the canvas.
Layer_Window :: struct {
	x, y, w, h: u32,
}

@(private)
Layer_Target :: struct {
	target: Render_Target,
	origin: [2]i32,
	// The layer stack's size to restore when this offscreen image ends.
	outer:  [2]u32,
}

// Stand-in render targets of one depth (`image_store_alloc_virtual`).
@(private)
Layer_Stand_In :: struct {
	content: Image_Id,
	mask:    Image_Id,
}

@(private)
Layer_Frame :: struct {
	// The canvas before the push: what was recorded since is the layer's.
	mark:       Canvas_Mark,
	// `Layer_Stack.releases` at the push. Images released since were drawn
	// in the layer's commands, so they can't hold the layer itself.
	releases:   u32,
	opacity:    f32,
	blur_px:    f32,
	has_clip:   bool,
	clip_rule:  Fill_Rule,
	clip_xform: Transform2D,
	masked:     bool,
	// A child blends with the layer, which then covers the whole canvas.
	full:       bool,
	filter:     ^Filter,
	xform:      Transform2D,
	blend:      Blend_Mode,
	mask_alpha: bool,
	mask_invert: bool,
}

@(private)
Lattice_Image :: struct {
	seed:      i32,
	id:        Image_Id,
	last_used: u32,
}

Layer_Stack :: struct {
	pool:      [dynamic]Pooled_Layer,
	frames:    [dynamic]Layer_Frame,
	// One pair per depth, reused across frames.
	stand_ins: [dynamic]Layer_Stand_In,
	// Clip path copies, one per depth, reused across frames.
	clips:     [dynamic]Path,
	// Repeating pattern tiles.
	tiles:     [dynamic]Pooled_Layer,
	// Offscreen images (`layer_image_begin`): shader children.
	images:    [dynamic]Pooled_Layer,
	// Images filled from the CPU (`layer_upload`): filter lookup tables
	// and noise. Uploads happen before the frame's commands run, so each
	// is used once per frame.
	uploads:   [dynamic]Pooled_Layer,
	// CPU pixels for uploads, reused across frames.
	upload_pixels: [dynamic]u8,
	// feTurbulence lattice images by seed (`layer_turbulence_lattice`),
	// kept across frames.
	lattices:  [dynamic]Lattice_Image,
	root:      Image_Id,
	targets:   [dynamic]Layer_Target,
	width:     u32,
	height:    u32,
	// The window of the layer being popped; its effects work at its size.
	window:    Layer_Window,
	// Counts `layer_stack_begin` calls.
	frame:     u32,
	// Counts `layer_release` calls.
	releases:  u32,
	scratch:   Path,
}

// Pooled images and tiles unused for this many frames are freed.
@(private = "file")
LAYER_KEEP_FRAMES :: 30

// The widest blur `layer_blur` runs at full size (wider ones downscale).
@(private = "file")
LAYER_MAX_EXACT_SIGMA :: 6

layer_stack_destroy :: proc(ls: ^Layer_Stack, c: ^Canvas) {
	for l in ls.pool {
		delete_image(c, l.id)
	}
	for t in ls.tiles {
		delete_image(c, t.id)
	}
	delete(ls.tiles)
	for t in ls.images {
		delete_image(c, t.id)
	}
	delete(ls.images)
	for t in ls.uploads {
		delete_image(c, t.id)
	}
	delete(ls.uploads)
	delete(ls.upload_pixels)
	for l in ls.lattices {
		delete_image(c, l.id)
	}
	delete(ls.lattices)
	for si in ls.stand_ins {
		delete_image(c, si.content)
		delete_image(c, si.mask)
	}
	delete(ls.stand_ins)
	for &p in ls.clips {
		path_destroy(&p)
	}
	delete(ls.clips)
	delete(ls.pool)
	delete(ls.frames)
	delete(ls.targets)
	path_destroy(&ls.scratch)
	ls^ = {}
}

// Starts a frame: layers are sized `width x height` and composite onto
// `target` (nil = screen). With `root_layer`, the frame itself is drawn into
// a layer (so blend modes can read it) and `layer_stack_end` copies it to
// the target.
layer_stack_begin :: proc(ls: ^Layer_Stack, c: ^Canvas, width, height: u32, target: Render_Target = nil, root_layer := false) {
	ls.width, ls.height = width, height
	ls.frame += 1
	clear(&ls.targets)
	append(&ls.targets, Layer_Target{target, {}, {}})
	clear(&ls.frames)
	layer_pool_reset(c, &ls.pool, ls.frame)
	layer_pool_reset(c, &ls.tiles, ls.frame)
	layer_pool_reset(c, &ls.images, ls.frame)
	layer_pool_reset(c, &ls.uploads, ls.frame)
	for i := 0; i < len(ls.lattices); {
		if ls.frame - ls.lattices[i].last_used > LAYER_KEEP_FRAMES {
			delete_image(c, ls.lattices[i].id)
			unordered_remove(&ls.lattices, i)
			continue
		}
		i += 1
	}
	ls.root = {}
	if root_layer {
		ls.root = layer_acquire(ls, c, width, height)
		layer_target_begin(ls, c, ls.root)
	}
}

// Ends a frame begun with `root_layer`: draws the root layer onto the target.
layer_stack_end :: proc(ls: ^Layer_Stack, c: ^Canvas) {
	if !image_id_valid(ls.root) {
		return
	}
	layer_target_end(ls, c)
	save(c)
	set_global_alpha(c, 1)
	layer_blit(ls, c, ls.root, 0, 0, ls.width, ls.height, 1)
	restore(c)
	layer_release(ls, ls.root)
	ls.root = {}
}

// A repeating tile image (`w x h` pixels) to draw a pattern into: drawing
// goes to it until `layer_pattern_end`, which returns it for an image paint.
// Tiles sample nearest-neighbour (as resvg's pattern shader), so tile edges
// stay sharp. Tiles are pooled with the layers.
layer_pattern_begin :: proc(ls: ^Layer_Stack, c: ^Canvas, w, h: u32) -> Image_Id {
	return layer_offscreen_begin(ls, c, &ls.tiles, w, h, {.Premultiplied, .Repeat_X, .Repeat_Y, .Nearest})
}

layer_pattern_end :: proc(ls: ^Layer_Stack, c: ^Canvas) {
	layer_offscreen_end(ls, c)
}

// A transparent `w x h` image (edges clamped) to draw into until
// `layer_image_end`; it holds what was drawn for the rest of the frame
// (commands run in order, so later commands of the frame can sample it, as
// a shader child). Pooled like the layers; nests.
layer_image_begin :: proc(ls: ^Layer_Stack, c: ^Canvas, w, h: u32) -> Image_Id {
	return layer_offscreen_begin(ls, c, &ls.images, w, h, {.Premultiplied})
}

layer_image_end :: proc(ls: ^Layer_Stack, c: ^Canvas) {
	layer_offscreen_end(ls, c)
}

// An image of `pool` free this frame (exact size), else a new one, made
// the render target. Layers pushed until `layer_offscreen_end` work in it:
// a blend reads it as the backdrop, so its layers must be its size.
@(private = "file")
layer_offscreen_begin :: proc(ls: ^Layer_Stack, c: ^Canvas, pool: ^[dynamic]Pooled_Layer, w, h: u32, flags: Image_Flags) -> Image_Id {
	id := Image_Id{}
	for &t in pool {
		if !t.in_use && t.w == w && t.h == h {
			t.in_use = true
			t.last_used = ls.frame
			id = t.id
			break
		}
	}
	if !image_id_valid(id) {
		id, _ = create_image_empty(c, w, h, .RGBA8, flags)
		append(pool, Pooled_Layer{id, w, h, true, ls.frame, 0})
	}
	layer_target_begin(ls, c, id)
	ls.targets[len(ls.targets) - 1].outer = {ls.width, ls.height}
	ls.width, ls.height = w, h
	return id
}

@(private = "file")
layer_offscreen_end :: proc(ls: ^Layer_Stack, c: ^Canvas) {
	outer := ls.targets[len(ls.targets) - 1].outer
	ls.width, ls.height = outer.x, outer.y
	layer_target_end(ls, c)
}

layer_depth :: proc(ls: ^Layer_Stack) -> int {
	return len(ls.frames)
}

// Redirects drawing into a new layer until the matching `layer_pop`.
layer_push :: proc(ls: ^Layer_Stack, c: ^Canvas, params: Layer_Params) {
	depth := len(ls.frames)
	f: Layer_Frame
	f.mark = canvas_mark(c)
	f.releases = ls.releases
	f.opacity = params.opacity if params.opacity > 0 else 1
	t := current_transform(c)
	f.blur_px = params.blur * transform_average_scale(t)
	f.filter = params.filter
	f.xform = t
	f.blend = params.blend
	f.mask_alpha = params.mask_alpha
	f.mask_invert = params.mask_invert
	if params.blend != .Normal {
		// Blending reads the target as an image of the canvas size.
		f.full = true
		if depth > 0 {
			ls.frames[depth - 1].full = true
		}
	}
	if params.clip_path != nil {
		for len(ls.clips) <= depth {
			append(&ls.clips, Path{})
		}
		clip := &ls.clips[depth]
		path_reset(clip)
		append(&clip.verbs, ..params.clip_path.verbs[:])
		append(&clip.coords, ..params.clip_path.coords[:])
		f.has_clip = true
		f.clip_rule = params.clip_rule
		f.clip_xform = t
	}
	for len(ls.stand_ins) <= depth {
		info := Image_Info{{.Premultiplied}, ls.width, ls.height, .RGBA8}
		append(&ls.stand_ins, Layer_Stand_In{image_store_alloc_virtual(&c.images, info), image_store_alloc_virtual(&c.images, info)})
	}
	// Sized to what the layer works in: the canvas or an offscreen image.
	for id in ([2]Image_Id{ls.stand_ins[depth].content, ls.stand_ins[depth].mask}) {
		if e := image_store_get(&c.images, id); e != nil {
			e.info.width, e.info.height = ls.width, ls.height
		}
	}
	append(&ls.frames, f)
	layer_target_begin(ls, c, ls.stand_ins[depth].content)
}

// Starts drawing the top layer's mask: until `layer_mask_end`, drawing
// goes to the mask, and the layer shows where the mask is opaque (alpha).
layer_mask_begin :: proc(ls: ^Layer_Stack, c: ^Canvas) {
	depth := len(ls.frames) - 1
	ls.frames[depth].masked = true
	layer_target_end(ls, c)
	layer_target_begin(ls, c, ls.stand_ins[depth].mask)
}

layer_mask_end :: proc(ls: ^Layer_Stack, c: ^Canvas) {
	layer_target_end(ls, c)
	layer_target_begin(ls, c, ls.stand_ins[len(ls.frames) - 1].content, keep = true)
}

// Ends the top layer: blurs, clips, masks and composites it.
layer_pop :: proc(ls: ^Layer_Stack, c: ^Canvas) {
	depth := len(ls.frames) - 1
	f := pop(&ls.frames)
	layer_target_end(ls, c)
	si := ls.stand_ins[depth]
	win, visible := layer_window(ls, c, &f, si, depth)
	if !visible {
		canvas_truncate(c, f.mark)
		return
	}
	// The global alpha applied to the draws recorded into the layer; the
	// filter, clip, mask and composite run at alpha 1, the layer's own
	// opacity applied once.
	save(c)
	set_global_alpha(c, 1)
	defer restore(c)
	w, h := win.w, win.h
	content := layer_acquire(ls, c, w, h, f.releases)
	mask := Image_Id{}
	if f.masked {
		mask = layer_acquire(ls, c, w, h, f.releases)
	}
	layer_relocate(c, f.mark.commands, si, content, mask, win)
	ls.window = win
	x, y := f32(win.x), f32(win.y)
	if f.filter != nil {
		// The region cuts what the filter sees and what it makes.
		filter_region_clip(ls, c, f.filter, f.xform, content)
		content = apply_filter(ls, c, f.filter, content, f.xform)
		filter_region_clip(ls, c, f.filter, f.xform, content)
	}
	if f.blur_px > 0 {
		content = layer_blur(ls, c, content, f.blur_px)
	}
	if f.masked && !f.mask_alpha {
		// Luminance mask: luminance of the (straight) color times alpha.
		lum := layer_acquire(ls, c, w, h)
		filter_image(c, lum, color_matrix_luminance_to_alpha(), mask)
		filter_image(c, mask, Composite{.In, {}, mask}, lum)
		layer_release(ls, lum)
	}
	if f.has_clip || f.masked {
		keep := layer_acquire(ls, c, w, h)
		layer_target_begin(ls, c, keep, origin = {i32(win.x), i32(win.y)})
		save(c)
		if f.has_clip {
			set_transform(c, f.clip_xform)
			p := paint_color(WHITE)
			p.fill_rule = f.clip_rule
			fill_path(c, &ls.clips[depth], p)
		}
		masks := f.masked && !f.mask_invert
		if masks {
			// Clip and mask both apply: the mask is drawn in the clip.
			if f.has_clip {
				set_composite_operation(c, .Source_In)
			}
			layer_blit(ls, c, mask, x, y, w, h, 1)
		}
		set_composite_operation(c, .Source_In if f.has_clip || masks else .Source_Over)
		layer_blit(ls, c, content, x, y, w, h, 1)
		if f.masked && f.mask_invert {
			// What the mask covers comes out.
			set_composite_operation(c, .Destination_Out)
			layer_blit(ls, c, mask, x, y, w, h, 1)
		}
		restore(c)
		layer_target_end(ls, c)
		layer_release(ls, content)
		if f.masked {
			layer_release(ls, mask)
		}
		content = keep
	}
	if f.blend != .Normal {
		layer_blend_onto_target(ls, c, content, f.opacity, f.blend)
	} else {
		layer_blit(ls, c, content, x, y, w, h, f.opacity)
	}
	layer_release(ls, content)
}

// The window of the layer `f` ending at `depth`, false when nothing of it
// would show.
@(private = "file")
layer_window :: proc(ls: ^Layer_Stack, c: ^Canvas, f: ^Layer_Frame, si: Layer_Stand_In, depth: int) -> (win: Layer_Window, visible: bool) {
	cw, ch := ls.width, ls.height
	if cw == 0 || ch == 0 {
		return {}, false
	}
	if f.full {
		return {0, 0, cw, ch}, true
	}
	drawn, mask := layer_scan(c, f.mark.commands, si)
	// How far the effects move or spread a pixel; a pixel of the result
	// depends only on what was drawn that close to it.
	reach: Vec2
	bounded := true
	region := Bounds{0, 0, f32(cw), f32(ch)}
	if f.filter != nil {
		reach, bounded = filter_reach(f.filter, f.xform)
		if rb, ok := filter_region_device(f.filter, f.xform); ok {
			region = rb
		}
	}
	if f.blur_px > 0 {
		reach += blur_reach({f.blur_px, f.blur_px}, LAYER_MAX_EXACT_SIGMA)
	}
	area := region
	if bounded {
		area = bounds_intersect(area, bounds_grow(drawn, reach))
	}
	if f.has_clip {
		// Plus the clip's antialiased edge.
		clip := tessellate(c, &ls.clips[depth], f.clip_xform).bounds
		area = bounds_intersect(area, bounds_grow(clip, reach + 2))
	}
	if f.masked && !f.mask_invert {
		area = bounds_intersect(area, bounds_grow(mask, reach))
	}
	x0 := max(math.floor(area.minx), 0)
	y0 := max(math.floor(area.miny), 0)
	x1 := min(math.ceil(area.maxx), f32(cw))
	y1 := min(math.ceil(area.maxy), f32(ch))
	if x1 <= x0 || y1 <= y0 {
		return {}, false
	}
	// A bucket-sized image, moved back inside the canvas where it would
	// stick out (so it never holds what lies beyond the canvas edge).
	win.w = layer_bucket(u32(x1 - x0), cw)
	win.h = layer_bucket(u32(y1 - y0), ch)
	win.x = min(u32(x0), cw - win.w)
	win.y = min(u32(y0), ch - win.h)
	return win, true
}

// Bounds (device pixels) of what the commands since `start` drew into the
// stand-ins of `si`.
@(private = "file")
layer_scan :: proc(c: ^Canvas, start: int, si: Layer_Stand_In) -> (content, mask: Bounds) {
	content, mask = EMPTY_BOUNDS, EMPTY_BOUNDS
	into: ^Bounds
	for &cmd in c.commands[start:] {
		if rt, ok := cmd.type.(Cmd_Set_Render_Target); ok {
			id, _ := rt.target.(Image_Id)
			into = &content if id == si.content else (&mask if id == si.mask else nil)
			continue
		}
		if into == nil {
			continue
		}
		if b, ok := command_bounds(c, &cmd); ok {
			into^ = bounds_union(into^, b)
		}
	}
	return
}

// The device-space bounds of the pixels a command can change on its
// target; false for commands that draw nothing there.
@(private = "file")
command_bounds :: proc(c: ^Canvas, cmd: ^Command) -> (b: Bounds, ok: bool) {
	b = EMPTY_BOUNDS
	#partial switch v in cmd.type {
	case Cmd_Clear_Rect:
		// Clearing to transparent adds nothing.
		if v.color.a <= 0 {
			return
		}
		b = {f32(v.x), f32(v.y), f32(v.x + v.w), f32(v.y + v.h)}
	case Cmd_Draw:
		for piece in c.pieces[cmd.pieces.start:][:cmd.pieces.count] {
			b = verts_bounds(b, c.verts[piece.verts.start:][:piece.verts.count])
		}
	case Cmd_Draw_Shapes:
		for inst in c.shapes[v.instances.start:][:v.instances.count] {
			b = bounds_union(b, shape_device_bounds(inst.shape, inst.transform))
		}
	case:
		return
	}
	if sr, has := cmd.scissor_rect.?; has {
		b = bounds_intersect(b, {sr.x, sr.y, sr.x + sr.w, sr.y + sr.h})
	}
	return b, b.minx < b.maxx && b.miny < b.maxy
}

@(private = "file")
verts_bounds :: proc "contextless" (b: Bounds, verts: []Vertex) -> Bounds {
	b := b
	for v in verts {
		b.minx = min(b.minx, v.x)
		b.miny = min(b.miny, v.y)
		b.maxx = max(b.maxx, v.x)
		b.maxy = max(b.maxy, v.y)
	}
	return b
}

@(private = "file")
bounds_union :: proc "contextless" (a, b: Bounds) -> Bounds {
	return {min(a.minx, b.minx), min(a.miny, b.miny), max(a.maxx, b.maxx), max(a.maxy, b.maxy)}
}

@(private)
bounds_intersect :: proc "contextless" (a, b: Bounds) -> Bounds {
	return {max(a.minx, b.minx), max(a.miny, b.miny), min(a.maxx, b.maxx), min(a.maxy, b.maxy)}
}

@(private = "file")
bounds_grow :: proc "contextless" (b: Bounds, d: Vec2) -> Bounds {
	return {b.minx - d.x, b.miny - d.y, b.maxx + d.x, b.maxy + d.y}
}

// Points the commands since `start` that use the stand-ins of `si` at
// `content` and `mask`, placed at the window's corner. Nested layers were
// relocated by their own pop.
@(private = "file")
layer_relocate :: proc(c: ^Canvas, start: int, si: Layer_Stand_In, content, mask: Image_Id, win: Layer_Window) {
	swap :: #force_inline proc "contextless" (id: ^Image_Id, si: Layer_Stand_In, content, mask: Image_Id) -> bool {
		if id^ == si.content {
			id^ = content
		} else if id^ == si.mask {
			id^ = mask
		} else {
			return false
		}
		return true
	}
	for &cmd in c.commands[start:] {
		// A stand-in read as an image: the backdrop of a blending child.
		swap(&cmd.image, si, content, mask)
		#partial switch &v in cmd.type {
		case Cmd_Set_Render_Target:
			if id, ok := &v.target.(Image_Id); ok && swap(id, si, content, mask) {
				v.origin = {i32(win.x), i32(win.y)}
			}
		case Cmd_Filter_Image:
			swap(&v.target_image, si, content, mask)
			#partial switch &fv in c.filters[v.filter] {
			case Blend:
				swap(&fv.backdrop, si, content, mask)
			case Composite:
				swap(&fv.backdrop, si, content, mask)
			}
		case Cmd_Run_Program:
			run := &c.runs[v.run]
			swap(&run.target, si, content, mask)
			for &ch in run.channels {
				swap(&ch, si, content, mask)
			}
		}
	}
}

// Blends `src` onto the current target, which must be a layer image. The
// layer covers the whole canvas (see `Layer_Frame.full`).
@(private = "file")
layer_blend_onto_target :: proc(ls: ^Layer_Stack, c: ^Canvas, src: Image_Id, opacity: f32, mode: Blend_Mode) {
	w, h := ls.window.w, ls.window.h
	backdrop, is_image := ls.targets[len(ls.targets) - 1].target.(Image_Id)
	if !is_image {
		// No backdrop image to read: composite normally.
		layer_blit(ls, c, src, 0, 0, w, h, opacity)
		return
	}
	source := src
	faded := Image_Id{}
	if opacity < 1 {
		faded = layer_acquire(ls, c, w, h)
		m := COLOR_MATRIX_IDENTITY
		m.m[18] = opacity
		filter_image(c, faded, m, src)
		source = faded
	}
	blended := layer_acquire(ls, c, w, h)
	filter_image(c, blended, Blend{mode, backdrop}, source)
	save(c)
	set_composite_operation(c, .Copy)
	layer_blit(ls, c, blended, 0, 0, w, h, 1)
	restore(c)
	layer_release(ls, blended)
	if image_id_valid(faded) {
		layer_release(ls, faded)
	}
}

// Draws a `w x h` layer image at (x, y) on the current target, untransformed
// and unclipped, at `opacity` times the global alpha.
layer_blit :: proc(ls: ^Layer_Stack, c: ^Canvas, layer: Image_Id, x, y: f32, w, h: u32, opacity: f32) {
	alpha := opacity * state(c).alpha
	save(c)
	set_global_alpha(c, 1)
	reset_transform(c)
	reset_scissor(c)
	fw, fh := f32(w), f32(h)
	path_reset(&ls.scratch)
	path_rect(&ls.scratch, x, y, fw, fh)
	p := paint_image(layer, x, y, fw, fh, 0, alpha)
	p.anti_alias = false
	fill_path(c, &ls.scratch, p)
	restore(c)
}

// Blurs `src` (released) into a new layer of the window's size. Above the
// backends' exact range the blur runs on a downscaled copy, which loses
// nothing for a blur that wide.
layer_blur :: proc(ls: ^Layer_Stack, c: ^Canvas, src: Image_Id, sigma: f32) -> Image_Id {
	dst := layer_acquire(ls, c, ls.window.w, ls.window.h)
	layer_blur_into(ls, c, dst, src, {sigma, sigma}, LAYER_MAX_EXACT_SIGMA)
	layer_release(ls, src)
	return dst
}

// Blurs `src` into `dst` (both of the window's size) with per-axis sigma in
// pixels. Above `max_exact` the blur runs on a copy downscaled by
// sigma / max_exact, on the grid a whole-canvas copy would use, so the
// result does not depend on where the window is.
@(private)
layer_blur_into :: proc(ls: ^Layer_Stack, c: ^Canvas, dst, src: Image_Id, sigma: [2]f32, max_exact: f32) {
	s := max(sigma.x, sigma.y)
	if s <= max_exact {
		filter_image(c, dst, Blur_XY{sigma.x, sigma.y, .Transparent}, src)
		return
	}
	win := ls.window
	f := s / max_exact
	// The canvas in gw x gh cells; cells under the window plus one each
	// side for the bilinear filtering.
	cw, ch := f32(ls.width), f32(ls.height)
	gw := max(u32(math.ceil(cw / f)), 1)
	gh := max(u32(math.ceil(ch / f)), 1)
	c0 := u32(max(math.floor(f32(win.x) * f32(gw) / cw) - 1, 0))
	c1 := u32(min(math.ceil(f32(win.x + win.w) * f32(gw) / cw) + 1, f32(gw)))
	r0 := u32(max(math.floor(f32(win.y) * f32(gh) / ch) - 1, 0))
	r1 := u32(min(math.ceil(f32(win.y + win.h) * f32(gh) / ch) + 1, f32(gh)))
	sw := layer_bucket(c1 - c0, gw)
	sh := layer_bucket(r1 - r0, gh)
	c0 = min(c0, gw - sw)
	r0 = min(r0, gh - sh)
	// Cell (i, j) of `small` is cell (c0 + i, r0 + j) of the canvas.
	small := layer_acquire(ls, c, sw, sh)
	layer_draw_image(
		ls,
		c,
		small,
		sw,
		sh,
		src,
		f32(win.x) * f32(gw) / cw - f32(c0),
		f32(win.y) * f32(gh) / ch - f32(r0),
		f32(win.w) * f32(gw) / cw,
		f32(win.h) * f32(gh) / ch,
	)
	blurred := layer_acquire(ls, c, sw, sh)
	filter_image(c, blurred, Blur_XY{sigma.x / f, sigma.y / f, .Transparent}, small)
	layer_release(ls, small)
	layer_draw_image(
		ls,
		c,
		dst,
		win.w,
		win.h,
		blurred,
		f32(c0) * cw / f32(gw) - f32(win.x),
		f32(r0) * ch / f32(gh) - f32(win.y),
		f32(sw) * cw / f32(gw),
		f32(sh) * ch / f32(gh),
	)
	layer_release(ls, blurred)
}

// How far (pixels per axis) a blur of `sigma` reads: its taps, plus the
// cells of the downscaled copy above `max_exact`.
@(private)
blur_reach :: proc "contextless" (sigma: Vec2, max_exact: f32) -> Vec2 {
	r := Vec2{math.ceil(3 * max(sigma.x, 0)) + 1, math.ceil(3 * max(sigma.y, 0)) + 1}
	if s := max(sigma.x, sigma.y); s > max_exact {
		r += 3 * math.ceil(s / max_exact) + 2
	}
	return r
}

// The image size for `n` pixels: steps of an eighth of the next power of
// two (16 at least), at most `limit`, so a layer whose size changes from
// frame to frame mostly finds its image in the pool.
@(private = "file")
layer_bucket :: proc "contextless" (n, limit: u32) -> u32 {
	step := max(u32(math.next_power_of_two(int(n))) / 8, 16)
	return min((n + step - 1) / step * step, limit)
}

// A transparent `w x h` layer image from the pool, one not released after
// release number `released_by`.
layer_acquire :: proc(ls: ^Layer_Stack, c: ^Canvas, w, h: u32, released_by := max(u32)) -> Image_Id {
	for &l in ls.pool {
		if !l.in_use && l.w == w && l.h == h && l.released <= released_by {
			l.in_use = true
			l.last_used = ls.frame
			return l.id
		}
	}
	id, _ := create_image_empty(c, w, h, .RGBA8, {.Premultiplied})
	append(&ls.pool, Pooled_Layer{id, w, h, true, ls.frame, 0})
	return id
}

// An image holding `src` (RGBA8) for the rest of the frame: one of the
// upload pool not used yet this frame (exact size), else a new one.
@(private)
layer_upload :: proc(ls: ^Layer_Stack, c: ^Canvas, src: Image_Source, flags: Image_Flags) -> Image_Id {
	id := Image_Id{}
	for &t in ls.uploads {
		if !t.in_use && t.w == src.width && t.h == src.height {
			info, _ := image_info(c, t.id)
			if info.flags != flags {
				continue
			}
			t.in_use = true
			t.last_used = ls.frame
			id = t.id
			break
		}
	}
	if !image_id_valid(id) {
		id, _ = create_image_empty(c, src.width, src.height, .RGBA8, flags)
		append(&ls.uploads, Pooled_Layer{id, src.width, src.height, true, ls.frame, 0})
	}
	update_image(c, id, src, 0, 0)
	return id
}

// The lattice image of a `Turbulence` filter with `seed`, made once and
// kept while used.
layer_turbulence_lattice :: proc(ls: ^Layer_Stack, c: ^Canvas, seed: i32) -> Image_Id {
	for &l in ls.lattices {
		if l.seed == seed {
			l.last_used = ls.frame
			return l.id
		}
	}
	px := turbulence_lattice_pixels(seed)
	id, _ := create_image_empty(c, TURBULENCE_LATTICE_W, TURBULENCE_LATTICE_H, .RGBA8, {.Premultiplied, .Nearest})
	update_image(c, id, image_source_rgba(px[:], TURBULENCE_LATTICE_W, TURBULENCE_LATTICE_H), 0, 0)
	append(&ls.lattices, Lattice_Image{seed, id, ls.frame})
	return id
}

layer_release :: proc(ls: ^Layer_Stack, id: Image_Id) {
	ls.releases += 1
	for &l in ls.pool {
		if l.id == id {
			l.in_use = false
			l.released = ls.releases
		}
	}
}

// Marks a pool's images free and frees those unused for LAYER_KEEP_FRAMES.
@(private = "file")
layer_pool_reset :: proc(c: ^Canvas, pool: ^[dynamic]Pooled_Layer, frame: u32) {
	for i := 0; i < len(pool); {
		if frame - pool[i].last_used > LAYER_KEEP_FRAMES {
			delete_image(c, pool[i].id)
			unordered_remove(pool, i)
			continue
		}
		pool[i].in_use = false
		i += 1
	}
}

// Replaces `dst` (dw x dh) with `src` painted as an image at (x, y, w, h).
@(private = "file")
layer_draw_image :: proc(ls: ^Layer_Stack, c: ^Canvas, dst: Image_Id, dw, dh: u32, src: Image_Id, x, y, w, h: f32) {
	layer_target_begin(ls, c, dst)
	save(c)
	set_global_alpha(c, 1)
	reset_transform(c)
	reset_scissor(c)
	path_reset(&ls.scratch)
	path_rect(&ls.scratch, 0, 0, f32(dw), f32(dh))
	p := paint_image(src, x, y, w, h, 0)
	p.anti_alias = false
	fill_path(c, &ls.scratch, p)
	restore(c)
	layer_target_end(ls, c)
}

// Directs drawing into `layer`, its top-left pixel at `origin` (cleared
// unless `keep`).
@(private)
layer_target_begin :: proc(ls: ^Layer_Stack, c: ^Canvas, layer: Image_Id, keep := false, origin := [2]i32{}) {
	append(&ls.targets, Layer_Target{layer, origin, {}})
	set_render_target(c, layer, origin)
	if !keep {
		info, _ := image_info(c, layer)
		save(c)
		reset_scissor(c)
		clear_rect(c, u32(origin.x), u32(origin.y), info.width, info.height, TRANSPARENT)
		restore(c)
	}
}

@(private)
layer_target_end :: proc(ls: ^Layer_Stack, c: ^Canvas) {
	pop(&ls.targets)
	t := ls.targets[len(ls.targets) - 1]
	set_render_target(c, t.target, t.origin)
}

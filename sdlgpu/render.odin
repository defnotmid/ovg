package ovg_sdlgpu

import "core:math"
import sdl "vendor:sdl3"

import vg ".."

// A frame is planned, uploaded, then recorded. Planning turns the commands
// into rows (one GPU operation each), adding the quads and paints of
// clears, filters and programs after the frame's. The upload writes each
// stream once, in place in its mapped transfer buffer: the canvas's
// vertices (each naming its paint), the packed paints and the shape
// instances; shapes new to the store go up first. Recording merges neighbouring rows that
// share a pipeline, textures, scissor and target into one draw call.

Pipeline_Key :: struct {
	blend:   vg.Composite_Operation_State,
	format:  sdl.GPUTextureFormat,
	// The shape pipeline (shapes.odin) instead of the triangle one, its
	// box variant (instances without rotation or skew) and its group one.
	shapes:  bool,
	box:     bool,
	group:   bool,
}

// `vg.Params` as the shader reads it (`vg.pack_frag_uniforms`).
Paint :: [14][4]f32

Row_Kind :: enum u8 {
	// Triangles from `verts` into `target`.
	Draw,
	// Shape instances `verts` (a range of the frame's shapes), one quad
	// each.
	Shapes,
	// `textures[0]`'s texture copied into `target`.
	Copy,
	// A custom program over `target` (`program`), its quad at `verts`.
	Program,
	// Host work (`external`) recorded between passes.
	External,
}

// One GPU operation of the frame.
Row :: struct {
	kind:     Row_Kind,
	target:   Image,
	// Drawing coordinates of the target's top-left pixel.
	origin:   [2]i32,
	key:      Pipeline_Key,
	textures: [2]sdl.GPUTextureSamplerBinding,
	scissor:  sdl.Rect,
	// Vertices (the canvas's, then the planner's own quads after them), or
	// for Shapes instances.
	verts:    vg.Range,
	// Filter passes run in a render pass of their own.
	own_pass: bool,
	program:  ^vg.Program_Run,
	external: ^vg.Cmd_Run_External,
}

// A GPU buffer and the transfer buffer that fills it, grown to the largest
// frame so far.
Stream :: struct {
	buffer:   ^sdl.GPUBuffer,
	transfer: ^sdl.GPUTransferBuffer,
	capacity: u32,
}

@(private)
sdl_render :: proc(data: rawptr, out: vg.Render_Output, images: ^vg.Image_Store, frame: vg.Frame) {
	b := (^SDL_Backend)(data)
	o := (^Output)(uintptr(out))
	b.frame += 1
	b.stats = {shape_instances = len(frame.shapes)}
	evict_textures(b, &b.scratch)

	screen: Image
	if o != nil {
		screen = {texture = o.texture, format = o.format, width = o.width, height = o.height}
	} else {
		if b.offscreen == nil || b.offscreen.width != b.screen_width || b.offscreen.height != b.screen_height {
			release_image(b, b.offscreen)
			img, err := create_texture(b, b.screen_width, b.screen_height, .R8G8B8A8_UNORM, {.COLOR_TARGET, .SAMPLER})
			if err != nil {
				b.offscreen = nil
				return
			}
			b.offscreen = img
		}
		screen = b.offscreen^
	}
	b.last_screen = screen

	// Every texture the frame needs (filter intermediates, the streams) is created while planning, before the command buffer is
	// recorded: SDL_GPU submits when it creates a texture, and a submit may
	// move textures a recording frame had already bound.
	if !plan_frame(b, images, frame, screen) {
		return
	}
	vert_count := len(frame.verts) + len(b.verts)
	paint_count := len(frame.paints) + len(b.paints)
	instance_count := len(frame.shapes) + len(b.groups)
	// A frame whose buffers the device can't provide (out of memory, a lost
	// device) is dropped, not drawn from nil buffers.
	if !stream_reserve(b, &b.vertex_stream, vert_count * size_of(vg.Vertex), {.VERTEX}) ||
	   !stream_reserve(b, &b.paint_stream, paint_count * size_of(Paint), {.GRAPHICS_STORAGE_READ}) ||
	   !stream_reserve(b, &b.instance_stream, instance_count * size_of(Gpu_Shape_Instance), {.GRAPHICS_STORAGE_READ}) {
		return
	}

	owned := o == nil || o.command_buffer == nil
	cmd := sdl.AcquireGPUCommandBuffer(b.device) if owned else o.command_buffer
	if cmd == nil {
		return
	}
	drop :: proc(cmd: ^sdl.GPUCommandBuffer, owned: bool) {
		if owned {
			_ = sdl.CancelGPUCommandBuffer(cmd)
		}
	}
	// New shapes go into the store first (passes of their own).
	if !store_upload(b, cmd) {
		drop(cmd, owned)
		return
	}
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	if copy_pass == nil {
		drop(cmd, owned)
		return
	}
	uploaded := true
	if vert_count > 0 {
		if verts := ([^]vg.Vertex)(stream_map(b, &b.vertex_stream, vert_count)); verts != nil {
			copy(verts[:len(frame.verts)], frame.verts)
			copy(verts[len(frame.verts):vert_count], b.verts[:])
			stream_commit(b, &b.vertex_stream, copy_pass, vert_count * size_of(vg.Vertex))
		} else {
			uploaded = false
		}
	}
	if paint_count > 0 {
		if paints := ([^]Paint)(stream_map(b, &b.paint_stream, paint_count)); paints != nil {
			for params, i in frame.paints {
				paints[i] = vg.pack_frag_uniforms(params)
			}
			copy(paints[len(frame.paints):paint_count], b.paints[:])
			stream_commit(b, &b.paint_stream, copy_pass, paint_count * size_of(Paint))
		} else {
			uploaded = false
		}
	}
	if instance_count > 0 {
		// Written once, straight into the mapped transfer buffer.
		if out := ([^]Gpu_Shape_Instance)(stream_map(b, &b.instance_stream, instance_count)); out != nil {
			for inst, i in frame.shapes {
				out[i] = gpu_shape_instance(inst, vg.instance_words(inst, frame.shape_words), b.shape_offsets[i])
			}
			copy(out[len(frame.shapes):instance_count], b.groups[:])
			stream_commit(b, &b.instance_stream, copy_pass, instance_count * size_of(Gpu_Shape_Instance))
		} else {
			uploaded = false
		}
	}
	sdl.EndGPUCopyPass(copy_pass)
	if !uploaded {
		drop(cmd, owned)
		return
	}
	record_rows(b, cmd, images, frame)

	if !owned {
		return
	}
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil {
		return
	}
	// Leave up to `frames_in_flight` frames running: wait for the oldest
	// beyond that (by default this one).
	limit := clamp(b.frames_in_flight, 0, MAX_FRAMES_IN_FLIGHT - 1)
	b.fences[(b.fence_head + b.fence_count) % MAX_FRAMES_IN_FLIGHT] = fence
	b.fence_count += 1
	for b.fence_count > limit {
		oldest := &b.fences[b.fence_head]
		_ = sdl.WaitForGPUFences(b.device, true, oldest, 1)
		sdl.ReleaseGPUFence(b.device, oldest^)
		oldest^ = nil
		b.fence_head = (b.fence_head + 1) % MAX_FRAMES_IN_FLIGHT
		b.fence_count -= 1
	}
}

// ---- streams --------------------------------------------------------------------------

// Grows the stream to hold `size` bytes; false (the stream left empty) when
// the device can't make its buffers.
@(private)
stream_reserve :: proc(b: ^SDL_Backend, s: ^Stream, size: int, usage: sdl.GPUBufferUsageFlags) -> bool {
	if u32(size) <= s.capacity && s.buffer != nil {
		return true
	}
	stream_release(b, s)
	s.capacity = u32(math.next_power_of_two(max(size, 64 * 1024)))
	s.buffer = sdl.CreateGPUBuffer(b.device, {usage = usage, size = s.capacity})
	s.transfer = sdl.CreateGPUTransferBuffer(b.device, {usage = .UPLOAD, size = s.capacity})
	if s.buffer == nil || s.transfer == nil {
		stream_release(b, s)
		return false
	}
	return true
}

@(private)
stream_release :: proc(b: ^SDL_Backend, s: ^Stream) {
	if s.buffer != nil {
		sdl.ReleaseGPUBuffer(b.device, s.buffer)
	}
	if s.transfer != nil {
		sdl.ReleaseGPUTransferBuffer(b.device, s.transfer)
	}
	s^ = {}
}

// The stream's transfer buffer, mapped (cycling) for `count` elements;
// nil when there are none.
@(private = "file")
stream_map :: proc(b: ^SDL_Backend, s: ^Stream, count: int) -> rawptr {
	if count == 0 || s.buffer == nil {
		return nil
	}
	return sdl.MapGPUTransferBuffer(b.device, s.transfer, true)
}

// Unmaps the stream's transfer buffer and uploads its first `size` bytes.
@(private = "file")
stream_commit :: proc(b: ^SDL_Backend, s: ^Stream, pass: ^sdl.GPUCopyPass, size: int) {
	sdl.UnmapGPUTransferBuffer(b.device, s.transfer)
	sdl.UploadToGPUBuffer(pass, {transfer_buffer = s.transfer}, {buffer = s.buffer, size = u32(size)}, true)
}

// ---- planning -------------------------------------------------------------------------

@(private = "file")
Planner :: struct {
	b:      ^SDL_Backend,
	images: ^vg.Image_Store,
	frame:  vg.Frame,
	screen: Image,
	target: Image,
	origin: [2]i32,
}

// Where the planner's next quad starts in the vertex buffer: its quads
// follow the frame's vertices.
@(private = "file")
extra_base :: proc(p: ^Planner) -> u32 {
	return u32(len(p.frame.verts) + len(p.b.verts))
}

// False when the frame's shapes don't fit the store.
@(private = "file")
plan_frame :: proc(b: ^SDL_Backend, images: ^vg.Image_Store, frame: vg.Frame, screen: Image) -> bool {
	clear(&b.verts)
	clear(&b.paints)
	clear(&b.rows)
	p := Planner {
		b      = b,
		images = images,
		frame  = frame,
		screen = screen,
		target = screen,
	}
	clear(&b.groups)
	clear(&b.group_words)
	for &cmd in frame.commands {
		switch &c in cmd.type {
		case vg.Cmd_Set_Render_Target:
			p.target = screen
			p.origin = c.origin
			if id, ok := c.target.(vg.Image_Id); ok {
				if img := lookup(&p, id); img != nil {
					p.target = img^
				}
			}
		case vg.Cmd_Clear_Rect:
			plan_clear(&p, cmd, c)
		case vg.Cmd_Draw:
			row := draw_row(&p, cmd)
			row.verts = cmd.verts
			if row.verts.count > 0 {
				append(&b.rows, row)
			}
		case vg.Cmd_Draw_Shapes:
			if c.instances.count == 0 {
				continue
			}
			if c.group != 0 {
				plan_group(&p, cmd, c)
				continue
			}
			plan_shape_rows(&p, draw_row(&p, cmd), c.instances)
		case vg.Cmd_Filter_Image:
			plan_filter(&p, cmd, c)
		case vg.Cmd_Run_Program:
			run := &frame.runs[c.run]
			target := lookup(&p, run.target)
			if target == nil || run.program.user == nil {
				continue
			}
			info, _ := vg.image_store_info(images, run.target)
			append(&b.rows, Row{kind = .Program, target = target^, verts = {extra_base(&p), 6}, program = run})
			emit_quad(&p, f32(info.width), f32(info.height), 0)
		case vg.Cmd_Run_External:
			append(&b.rows, Row{kind = .External, external = &c})
		}
	}
	grids, placed := store_place(b, frame)
	for &g in b.groups {
		g.data.x += grids
	}
	return placed
}

@(private = "file")
lookup :: proc(p: ^Planner, id: vg.Image_Id) -> ^Image {
	entry := vg.image_store_get(p.images, id)
	return (^Image)(entry.image.user) if entry != nil else nil
}

@(private = "file")
add_paint :: proc(p: ^Planner, paint: Paint) -> u32 {
	append(&p.b.paints, paint)
	return u32(len(p.frame.paints) + len(p.b.paints) - 1)
}

// A row drawing `cmd` into the current target; the caller sets its
// vertices.
@(private = "file")
draw_row :: proc(p: ^Planner, cmd: vg.Command) -> Row {
	glyph: ^Image
	if cmd.glyph_texture.kind != .None {
		glyph = lookup(p, cmd.glyph_texture.image)
	}
	scissor := sdl.Rect{0, 0, i32(p.target.width), i32(p.target.height)}
	if sr, has := cmd.scissor_rect.?; has {
		scissor = target_rect(p.target, p.origin, sr)
	}
	return {
		kind = .Draw,
		target = p.target,
		origin = p.origin,
		key = {blend = cmd.composite_operation, format = p.target.format},
		textures = {texture_binding(p.b, lookup(p, cmd.image)), texture_binding(p.b, glyph)},
		scissor = scissor,
	}
}

// Two triangles over (0, 0)..(w, h), texture coordinates 0..1.
@(private = "file")
emit_quad :: proc(p: ^Planner, w, h: f32, paint: u32) {
	append(&p.b.verts, vg.vertex(0, 0, 0, 0, paint), vg.vertex(w, 0, 1, 0, paint), vg.vertex(w, h, 1, 1, paint))
	append(&p.b.verts, vg.vertex(0, 0, 0, 0, paint), vg.vertex(w, h, 1, 1, paint), vg.vertex(0, h, 0, 1, paint))
}

// `rect` (drawing coordinates) in target pixels, clipped to the target.
@(private = "file")
target_rect :: proc(target: Image, origin: [2]i32, rect: vg.Rect) -> sdl.Rect {
	x0 := clamp(i32(math.floor(rect.x)) - origin.x, 0, i32(target.width))
	y0 := clamp(i32(math.floor(rect.y)) - origin.y, 0, i32(target.height))
	x1 := clamp(i32(math.ceil(rect.x + rect.w)) - origin.x, x0, i32(target.width))
	y1 := clamp(i32(math.ceil(rect.y + rect.h)) - origin.y, y0, i32(target.height))
	return {x0, y0, x1 - x0, y1 - y0}
}

@(private = "file")
texture_binding :: proc(b: ^SDL_Backend, img: ^Image) -> sdl.GPUTextureSamplerBinding {
	img := img if img != nil else b.white
	i := 0
	if .Repeat_X in img.flags {i |= 1}
	if .Repeat_Y in img.flags {i |= 2}
	if .Nearest in img.flags {i |= 4}
	return {texture = img.texture, sampler = b.samplers[i]}
}

// SDL_GPU clears only whole targets, so a clear is a quad drawn with the
// command's Copy blend, scissored to the rectangle.
@(private = "file")
plan_clear :: proc(p: ^Planner, cmd: vg.Command, c: vg.Cmd_Clear_Rect) {
	rect := vg.Rect{f32(c.x), f32(c.y), f32(c.w), f32(c.h)}
	if sr, ok := cmd.scissor_rect.?; ok {
		rect = vg.rect_intersect(rect, sr)
	}
	area := target_rect(p.target, p.origin, rect)
	if area.w <= 0 || area.h <= 0 {
		return
	}
	params := vg.default_params()
	params.shader_type = .Fill_Color
	params.inner_col = vg.color_to_array(vg.premultiplied(c.color))
	params.outer_col = params.inner_col
	params.stroke_mult = 1
	params.stroke_thr = -1
	paint := add_paint(p, vg.pack_frag_uniforms(params))
	row := draw_row(p, cmd)
	row.scissor = area
	row.verts = {extra_base(p), 6}
	append(&p.b.rows, row)
	x0, y0 := f32(c.x), f32(c.y)
	x1, y1 := x0 + f32(c.w), y0 + f32(c.h)
	append(&p.b.verts, vg.vertex(x0, y0, 0.5, 1, paint), vg.vertex(x1, y0, 0.5, 1, paint), vg.vertex(x1, y1, 0.5, 1, paint))
	append(&p.b.verts, vg.vertex(x0, y0, 0.5, 1, paint), vg.vertex(x1, y1, 0.5, 1, paint), vg.vertex(x0, y1, 0.5, 1, paint))
}

// Rows drawing `instances` with `base`'s state: one per stretch of
// instances that are all boxes (no rotation or skew: the box shader) or
// all not.
@(private = "file")
plan_shape_rows :: proc(p: ^Planner, base: Row, instances: vg.Range) {
	row := base
	row.kind = .Shapes
	row.key.shapes = true
	start := instances.start
	for i in instances.start ..< instances.start + instances.count {
		t := p.frame.shapes[i].transform
		box := t[1] == 0 && t[2] == 0
		if i > start && box != row.key.box {
			row.verts = {start, i - start}
			append(&p.b.rows, row)
			start = i
		}
		row.key.box = box
	}
	row.verts = {start, instances.start + instances.count - start}
	append(&p.b.rows, row)
}

// A group (`Cmd_Draw_Shapes.group`): records after the frame's instances
// whose pixels composite the instances (the group shader). Their bounds
// are a grid of cells about one instance in size, each listing the
// instances whose bounds meet it, in order, so a pixel looks at the few
// near it; a record covers a row's run of cells that list any. Records map
// cell units to drawing coordinates and share the grid (`group_words`,
// placed in the store): each cell's first list entry, one more for the
// end, then the lists (instances from the first).
@(private = "file")
plan_group :: proc(p: ^Planner, cmd: vg.Command, c: vg.Cmd_Draw_Shapes) {
	b := p.b
	n := int(c.instances.count)
	bounds := make([]vg.Bounds, n, context.temp_allocator)
	area := vg.EMPTY_BOUNDS
	for inst, k in p.frame.shapes[c.instances.start:][:n] {
		bounds[k] = vg.instance_bounds(inst, p.frame.shape_words)
		area = {min(area.minx, bounds[k].minx), min(area.miny, bounds[k].miny), max(area.maxx, bounds[k].maxx), max(area.maxy, bounds[k].maxy)}
	}
	w, h := max(area.maxx - area.minx, 1), max(area.maxy - area.miny, 1)
	side: f32
	for ib in bounds {
		side += (ib.maxx - ib.minx) + (ib.maxy - ib.miny)
	}
	side = max(side / f32(2 * n), 1)
	nx := clamp(int(math.ceil(w / side)), 1, GROUP_MAX_CELLS)
	ny := clamp(int(math.ceil(h / side)), 1, GROUP_MAX_CELLS)
	cw, ch := w / f32(nx), h / f32(ny)
	cells :: proc(b: vg.Bounds, area: vg.Bounds, cw, ch: f32, nx, ny: int) -> (i0, j0, i1, j1: int) {
		i0 = clamp(int((b.minx - area.minx) / cw), 0, nx - 1)
		j0 = clamp(int((b.miny - area.miny) / ch), 0, ny - 1)
		i1 = clamp(int((b.maxx - area.minx) / cw), 0, nx - 1)
		j1 = clamp(int((b.maxy - area.miny) / ch), 0, ny - 1)
		return
	}
	// Indices into `group_words` (it grows below): its starts, then lists.
	at := len(b.group_words)
	lists := at + nx * ny + 1
	resize(&b.group_words, lists)
	words := &b.group_words
	for k in at ..< lists {
		words[k] = 0
	}
	for ib in bounds {
		i0, j0, i1, j1 := cells(ib, area, cw, ch, nx, ny)
		for j in j0 ..= j1 {
			for i in i0 ..= i1 {
				words[at + j * nx + i + 1] += 1
			}
		}
	}
	for k in at ..< lists - 1 {
		words[k + 1] += words[k]
	}
	resize(words, lists + int(words[lists - 1]))
	fill := make([]u32, nx * ny, context.temp_allocator)
	copy(fill, words[at:lists - 1])
	for ib, k in bounds {
		i0, j0, i1, j1 := cells(ib, area, cw, ch, nx, ny)
		for j in j0 ..= j1 {
			for i in i0 ..= i1 {
				words[lists + int(fill[j * nx + i])] = u32(k)
				fill[j * nx + i] += 1
			}
		}
	}
	row := draw_row(p, cmd)
	row.kind = .Shapes
	row.key.shapes, row.key.group = true, true
	first := len(b.groups)
	listed :: proc(words: ^[dynamic]u32, cell: int) -> bool {
		return words[cell] != words[cell + 1]
	}
	for j in 0 ..< ny {
		for i := 0; i < nx; {
			if !listed(words, at + j * nx + i) {
				i += 1
				continue
			}
			i0 := i
			for i < nx && listed(words, at + j * nx + i) {
				i += 1
			}
			append(&b.groups, Gpu_Shape_Instance {
				m = {cw, 0, 0, ch},
				t = {area.minx, area.miny, 0, 0},
				bounds = {f32(i0), f32(j), f32(i), f32(j + 1)},
				data = {u32(at), c.group - 1, c.instances.start, u32(nx) | u32(ny) << 16},
			})
		}
	}
	row.verts = {u32(len(p.frame.shapes) + first), u32(len(b.groups) - first)}
	append(&b.rows, row)
}

// A group's grid is at most this many cells a side.
@(private = "file")
GROUP_MAX_CELLS :: 64

// One filter quad from `src` (and `backdrop`) into `dst`, a pass of its own
// with Copy blend.
@(private = "file")
plan_filter_pass :: proc(p: ^Planner, src, backdrop, dst: ^Image, paint: Paint) {
	if dst == nil {
		return
	}
	append(&p.b.rows, Row {
		kind     = .Draw,
		target   = dst^,
		key      = {blend = vg.composite_state_from_op(.Copy), format = dst.format},
		textures = {texture_binding(p.b, src), texture_binding(p.b, backdrop)},
		scissor  = {0, 0, i32(dst.width), i32(dst.height)},
		verts    = {extra_base(p), 6},
		own_pass = true,
	})
	emit_quad(p, f32(dst.width), f32(dst.height), add_paint(p, paint))
}

@(private = "file")
plan_copy :: proc(p: ^Planner, src, dst: ^Image) {
	if src == nil || dst == nil {
		return
	}
	append(&p.b.rows, Row{kind = .Copy, target = dst^, textures = {{texture = src.texture}, {}}})
}

// Image filters: full-target quads drawn with Copy blend. Blurs run two
// passes through a temporary image; single-pass filters render into a
// temporary first when the target is also an input, then copy.
@(private = "file")
plan_filter :: proc(p: ^Planner, cmd: vg.Command, c: vg.Cmd_Filter_Image) {
	filter := p.frame.filters[c.filter]
	src_info, ok := vg.image_store_info(p.images, cmd.image)
	dst_info, dst_ok := vg.image_store_info(p.images, c.target_image)
	if !ok || !dst_ok {
		return
	}
	extent := [2]f32{f32(src_info.width), f32(src_info.height)}
	if t, is_turbulence := filter.(vg.Turbulence); is_turbulence {
		// The source is the lattice image, not the target's size.
		frag := turbulence_uniforms(t)
		frag[9] = {f32(dst_info.width), f32(dst_info.height), 0, 0}
		frag[10] = {0, 0, 0, f32(vg.Shader_Type.Filter_Turbulence)}
		plan_filter_pass(p, lookup(p, cmd.image), nil, lookup(p, c.target_image), frag)
		return
	}
	if src_info.width != dst_info.width || src_info.height != dst_info.height {
		return
	}

	if sx, sy, edge, is_blur := vg.blur_params(filter); is_blur {
		mid := scratch_image(p.b, src_info)
		if mid == nil {
			return
		}
		Pass :: struct {
			src, dst: ^Image,
			dir:      [2]f32,
			sigma:    f32,
			tex_type: f32,
		}
		passes := [2]Pass {
			{lookup(p, cmd.image), mid, {1, 0}, sx, vg.tex_type_for(src_info)},
			// The intermediate already holds premultiplied color.
			{mid, lookup(p, c.target_image), {0, 1}, sy, 2 if src_info.format == .Gray8 else 0},
		}
		for pass in passes {
			coeff, taps := vg.blur_pass_coefficients(pass.sigma)
			params := vg.default_params()
			params.shader_type = .Filter_Image
			params.extent = extent
			params.paint_mat = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0}
			params.image_blur_filter_coeff = coeff
			params.image_blur_filter_taps = f32(taps)
			params.image_blur_filter_edge = f32(edge)
			params.image_blur_filter_direction = pass.dir
			params.tex_type = pass.tex_type
			plan_filter_pass(p, pass.src, nil, pass.dst, vg.pack_frag_uniforms(params))
		}
		return
	}

	if m, is_morph := filter.(vg.Morphology); is_morph {
		mid := scratch_image(p.b, src_info)
		if mid == nil {
			return
		}
		srcs := [2]^Image{lookup(p, cmd.image), mid}
		dsts := [2]^Image{mid, lookup(p, c.target_image)}
		tts := [2]f32{vg.tex_type_for(src_info), 2 if src_info.format == .Gray8 else 0}
		for axis in 0 ..< 2 {
			frag: Paint
			frag[0] = {m.radius[axis], 1 if m.dilate else 0, f32(axis), 0}
			frag[9] = {extent.x, extent.y, m.valid[0], m.valid[1]}
			frag[10] = {m.valid[2], m.valid[3], tts[axis], f32(vg.Shader_Type.Filter_Morphology)}
			plan_filter_pass(p, srcs[axis], nil, dsts[axis], frag)
		}
		return
	}

	backdrop := vg.filter_backdrop(filter)
	back_tt: f32
	if vg.image_id_valid(backdrop) {
		back_info, back_ok := vg.image_store_info(p.images, backdrop)
		_, is_lut := filter.(vg.Component_Transfer)
		if !back_ok || (!is_lut && (back_info.width != src_info.width || back_info.height != src_info.height)) {
			return
		}
		back_tt = vg.tex_type_for(back_info)
	}

	// Paint rows: frag[0..3] matrix rows, frag[4] offsets or k1..k4,
	// frag[9] = (extent, op), frag[10].zw = (tex type, shader type),
	// frag[13].x = the backdrop's tex type.
	frag: Paint
	frag[9] = {extent.x, extent.y, 0, 0}
	frag[10] = {0, 0, vg.tex_type_for(src_info), 0}
	frag[13] = {back_tt, 0, 0, 0}
	switch v in filter {
	case vg.Color_Matrix:
		frag[10].w = f32(vg.Shader_Type.Filter_Color_Matrix)
		for row in 0 ..< 4 {
			frag[row] = {v.m[row * 5], v.m[row * 5 + 1], v.m[row * 5 + 2], v.m[row * 5 + 3]}
			frag[4][row] = v.m[row * 5 + 4]
		}
	case vg.Color_Space_Convert:
		frag[10].w = f32(vg.Shader_Type.Filter_Color_Space)
		frag[9].z = 1 if v.to_linear else 0
	case vg.Blend:
		frag[10].w = f32(vg.Shader_Type.Filter_Blend)
		frag[9].z = f32(v.mode)
	case vg.Composite:
		frag[10].w = f32(vg.Shader_Type.Filter_Composite)
		frag[9].z = f32(v.op)
		frag[4] = v.k
	case vg.Component_Transfer:
		frag[10].w = f32(vg.Shader_Type.Filter_Component_Transfer)
	case vg.Lighting:
		frag[10].w = f32(vg.Shader_Type.Filter_Lighting)
		frag[0] = {v.color.r, v.color.g, v.color.b, v.surface_scale}
		frag[1] = {1 if v.specular else 0, f32(v.light), v.constant, v.specular_exponent}
		frag[2] = {v.position.x, v.position.y, v.position.z, v.spot_exponent}
		frag[3] = {v.points_at.x, v.points_at.y, v.points_at.z, v.cone_cos}
		set_valid(&frag, v.valid)
	case vg.Tile:
		frag[10].w = f32(vg.Shader_Type.Filter_Tile)
		frag[0] = v.rect
	case vg.Displacement_Map:
		frag[10].w = f32(vg.Shader_Type.Filter_Displacement)
		frag[0] = {v.scale.x, v.scale.y, f32(v.channels.x), f32(v.channels.y)}
		set_valid(&frag, v.valid)
	case vg.Convolve_Matrix:
		frag[10].w = f32(vg.Shader_Type.Filter_Convolve)
		for k, i in v.kernel {
			frag[i / 4][i % 4] = k
		}
		frag[11] = {f32(v.order.x), f32(v.order.y), f32(v.target.x), f32(v.target.y)}
		frag[12] = {v.divisor, v.bias, f32(v.edge), 1 if v.preserve_alpha else 0}
		set_valid(&frag, v.valid)
	case vg.Gaussian_Blur, vg.Blur_XY, vg.Morphology, vg.Turbulence:
		return
	}

	src, back, target := lookup(p, cmd.image), lookup(p, backdrop), lookup(p, c.target_image)
	if c.target_image == cmd.image || c.target_image == backdrop {
		tmp := scratch_image(p.b, dst_info)
		if tmp == nil {
			return
		}
		plan_filter_pass(p, src, back, tmp, frag)
		plan_copy(p, tmp, target)
		return
	}
	plan_filter_pass(p, src, back, target, frag)
}

// ---- recording ------------------------------------------------------------------------

@(private = "file")
Recorder :: struct {
	b:        ^SDL_Backend,
	images:   ^vg.Image_Store,
	frame:    vg.Frame,
	cmd:      ^sdl.GPUCommandBuffer,
	pass:     ^sdl.GPURenderPass,
	// The open pass's target and origin.
	target:   ^sdl.GPUTexture,
	origin:   [2]i32,
	// State set in the open pass.
	pipeline: ^sdl.GPUGraphicsPipeline,
	textures: [2]sdl.GPUTextureSamplerBinding,
	scissor:  sdl.Rect,
	// The draw being gathered: rows merge into it while they continue it.
	pending:   Row,
	gathering: bool,
}

@(private = "file")
record_rows :: proc(b: ^SDL_Backend, cmd: ^sdl.GPUCommandBuffer, images: ^vg.Image_Store, frame: vg.Frame) {
	r := Recorder {
		b      = b,
		images = images,
		frame  = frame,
		cmd    = cmd,
	}
	for row in b.rows {
		switch row.kind {
		case .Draw, .Shapes:
			if r.gathering && continues(r.pending, row) {
				r.pending.verts.count += row.verts.count
				continue
			}
			flush(&r)
			r.pending, r.gathering = row, true
		case .Copy:
			flush(&r)
			end_pass(&r)
			if pass := sdl.BeginGPUCopyPass(cmd); pass != nil {
				sdl.CopyGPUTextureToTexture(pass, {texture = row.textures[0].texture}, {texture = row.target.texture}, row.target.width, row.target.height, 1, false)
				sdl.EndGPUCopyPass(pass)
			}
		case .Program:
			flush(&r)
			end_pass(&r)
			run_program(&r, row)
		case .External:
			flush(&r)
			end_pass(&r)
			row.external.fn(row.external.user, cmd)
		}
	}
	flush(&r)
	end_pass(&r)
}

// `row` draws right after `pending` with the same state, so one draw call
// covers both.
@(private = "file")
continues :: proc(pending, row: Row) -> bool {
	return(
		row.kind == pending.kind &&
		!pending.own_pass &&
		!row.own_pass &&
		row.verts.start == pending.verts.start + pending.verts.count &&
		row.target.texture == pending.target.texture &&
		row.origin == pending.origin &&
		row.key == pending.key &&
		row.textures == pending.textures &&
		row.scissor == pending.scissor \
	)
}

// Draws the pending row.
@(private = "file")
flush :: proc(r: ^Recorder) {
	if !r.gathering {
		return
	}
	row := r.pending
	r.gathering = false
	if row.own_pass || r.target != row.target.texture || r.origin != row.origin {
		end_pass(r)
	}
	if !begin_pass(r, row.target, row.origin) {
		return
	}
	pipeline := get_pipeline(r.b, row.key)
	if pipeline == nil {
		return
	}
	if pipeline != r.pipeline {
		sdl.BindGPUGraphicsPipeline(r.pass, pipeline)
		r.pipeline = pipeline
		r.b.stats.pipeline_binds += 1
	}
	r.b.stats.draws += 1
	if r.textures != row.textures {
		textures := row.textures
		sdl.BindGPUFragmentSamplers(r.pass, 0, &textures[0], 2)
		r.textures = row.textures
	}
	if r.scissor != row.scissor {
		sdl.SetGPUScissor(r.pass, row.scissor)
		r.scissor = row.scissor
	}
	if row.kind == .Shapes {
		// The instances index from the draw's first (SV_InstanceID counts
		// from 0 in every draw).
		base := [4]u32{row.verts.start, 0, 0, 0}
		sdl.PushGPUVertexUniformData(r.cmd, 1, &base, size_of(base))
		sdl.DrawGPUPrimitives(r.pass, 6, row.verts.count, 0, 0)
	} else {
		sdl.DrawGPUPrimitives(r.pass, row.verts.count, 1, row.verts.start, 0)
	}
	if row.own_pass {
		end_pass(r)
	}
}

// Starts a render pass on `target` if none is open.
@(private = "file")
begin_pass :: proc(r: ^Recorder, target: Image, origin: [2]i32) -> bool {
	if r.pass != nil {
		return true
	}
	color := sdl.GPUColorTargetInfo {
		texture  = target.texture,
		load_op  = .LOAD,
		store_op = .STORE,
	}
	r.pass = sdl.BeginGPURenderPass(r.cmd, &color, 1, nil)
	if r.pass == nil {
		return false
	}
	r.b.stats.render_passes += 1
	r.target, r.origin = target.texture, origin
	vertices := sdl.GPUBufferBinding {
		buffer = r.b.vertex_stream.buffer,
	}
	sdl.BindGPUVertexBuffers(r.pass, 0, &vertices, 1)
	// The group shader reads the instances too.
	storage := [3]^sdl.GPUBuffer{r.b.paint_stream.buffer, r.b.shapes.buffer, r.b.instance_stream.buffer}
	sdl.BindGPUFragmentStorageBuffers(r.pass, 0, &storage[0], 3 if storage[1] != nil && storage[2] != nil else 1)
	if instances := r.b.instance_stream.buffer; instances != nil {
		sdl.BindGPUVertexStorageBuffers(r.pass, 0, &instances, 1)
	}
	// The vertex shader subtracts the origin (zw) before mapping to NDC.
	view := [4]f32{f32(target.width), f32(target.height), f32(origin.x), f32(origin.y)}
	sdl.PushGPUVertexUniformData(r.cmd, 0, &view, size_of(view))
	r.pipeline = nil
	r.textures = {}
	r.scissor = {-1, -1, -1, -1}
	return true
}

@(private = "file")
end_pass :: proc(r: ^Recorder) {
	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
		r.target = nil
	}
}

@(private = "file")
lookup_image :: proc(images: ^vg.Image_Store, id: vg.Image_Id) -> ^Image {
	entry := vg.image_store_get(images, id)
	return (^Image)(entry.image.user) if entry != nil else nil
}

// A custom program over its whole target: a pass of its own, cleared
// first, one quad with Copy semantics.
@(private = "file")
run_program :: proc(r: ^Recorder, row: Row) {
	c := row.program
	p := (^Program)(c.program.user)
	target := row.target
	opaque := .Opaque in c.flags
	pipeline := program_pipeline(r.b, p, target.format, opaque)
	if pipeline == nil {
		return
	}
	color := sdl.GPUColorTargetInfo {
		texture     = target.texture,
		load_op     = .CLEAR,
		store_op    = .STORE,
		clear_color = {0, 0, 0, 1 if opaque else 0},
	}
	pass := sdl.BeginGPURenderPass(r.cmd, &color, 1, nil)
	if pass == nil {
		return
	}
	defer sdl.EndGPURenderPass(pass)
	sdl.BindGPUGraphicsPipeline(pass, pipeline)
	binding := sdl.GPUBufferBinding {
		buffer = r.b.vertex_stream.buffer,
	}
	sdl.BindGPUVertexBuffers(pass, 0, &binding, 1)

	view := [4]f32{f32(target.width), f32(target.height), 0, 0}
	sdl.PushGPUVertexUniformData(r.cmd, 0, &view, size_of(view))
	if p.uniform_size > 0 {
		block := vg.frame_bytes(r.frame, c.uniforms)
		if len(block) < p.uniform_size {
			padded := make([]u8, p.uniform_size, context.temp_allocator)
			copy(padded, block)
			block = padded
		}
		sdl.PushGPUFragmentUniformData(r.cmd, 0, raw_data(block), u32(p.uniform_size))
	}
	if p.num_samplers > 0 {
		bindings: [vg.PROGRAM_MAX_CHANNELS]sdl.GPUTextureSamplerBinding
		for i in 0 ..< p.num_samplers {
			img := lookup_image(r.images, c.channels[i]) if vg.image_id_valid(c.channels[i]) else nil
			bindings[i] = texture_binding(r.b, img if img != nil else r.b.transparent)
		}
		sdl.BindGPUFragmentSamplers(pass, 0, &bindings[0], u32(p.num_samplers))
	}
	sdl.DrawGPUPrimitives(pass, 6, 1, row.verts.start, 0)
}

@(private = "file")
program_pipeline :: proc(b: ^SDL_Backend, p: ^Program, format: sdl.GPUTextureFormat, opaque: bool) -> ^sdl.GPUGraphicsPipeline {
	for pp in p.pipelines {
		if pp.format == format && pp.opaque == opaque {
			return pp.pipeline
		}
	}
	buffer := sdl.GPUVertexBufferDescription {
		slot       = 0,
		pitch      = size_of(vg.Vertex),
		input_rate = .VERTEX,
	}
	attrs := [2]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(vg.Vertex, x))},
		{location = 1, buffer_slot = 0, format = .USHORT2_NORM, offset = u32(offset_of(vg.Vertex, u))},
	}
	color := sdl.GPUColorTargetDescription {
		format = format,
		blend_state = {
			// Opaque runs keep the cleared alpha of 1.
			color_write_mask = {.R, .G, .B} if opaque else {.R, .G, .B, .A},
			enable_color_write_mask = true,
		},
	}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = p.vert,
		fragment_shader = p.frag,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffer,
			num_vertex_buffers = 1,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = 2,
		},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE},
		multisample_state = {sample_count = ._1},
		target_info = {color_target_descriptions = &color, num_color_targets = 1},
	}
	pipeline := sdl.CreateGPUGraphicsPipeline(b.device, info)
	if pipeline != nil {
		append(&p.pipelines, Program_Pipeline{format, opaque, pipeline})
	}
	return pipeline
}

// ---- textures -------------------------------------------------------------------------

// Cached textures unused for this many frames are released.
@(private = "file")
TEXTURE_KEEP_FRAMES :: 30

@(private = "file")
evict_textures :: proc(b: ^SDL_Backend, cache: ^[dynamic]Cached_Texture) {
	for i := 0; i < len(cache); {
		if b.frame - cache[i].last_used > TEXTURE_KEEP_FRAMES {
			// SDL defers the release until submitted work no longer uses it.
			sdl.ReleaseGPUTexture(b.device, cache[i].image.texture)
			unordered_remove(cache, i)
			continue
		}
		i += 1
	}
}

// A texture shaped like `info` for a filter's intermediate result. Passes
// run in order, so one per shape serves every filter of a frame.
@(private = "file")
scratch_image :: proc(b: ^SDL_Backend, info: vg.Image_Info) -> ^Image {
	format := texture_format(info.format)
	for &t in b.scratch {
		img := &t.image
		if img.width == info.width && img.height == info.height && img.format == format && img.flags == info.flags {
			t.last_used = b.frame
			return img
		}
	}
	img, err := create_texture(b, info.width, info.height, format, {.SAMPLER, .COLOR_TARGET})
	if err != nil {
		return nil
	}
	img.flags = info.flags
	append(&b.scratch, Cached_Texture{img^, b.frame})
	free(img, b.allocator)
	return &b.scratch[len(b.scratch) - 1].image
}

// feTurbulence's uniforms (see `turbulence` in ovg.slang): frag[0] the
// lattice coordinate of target pixel x, y as (x + a) * b, frag[1] =
// (octaves, fractal, stitch, 0); stitching: frag[2] the tile size in
// cells and the region origin, frag[3].xy the frequencies. Computed in
// f64 here, so the shader's f32 starts from rounded exact values.
@(private = "file")
turbulence_uniforms :: proc "contextless" (t: vg.Turbulence) -> (frag: [14][4]f32) {
	freq, cells := vg.turbulence_frequency(t.params, {t.region[2], t.region[3]})
	frag[0] = {f32(t.offset.x), f32(t.offset.y), f32(freq.x / t.scale.x), f32(freq.y / t.scale.y)}
	frag[1] = {f32(t.params.octaves), 1 if t.params.fractal_noise else 0, 1 if t.params.stitch else 0, 0}
	frag[2] = {f32(cells.x), f32(cells.y), f32(t.region[0]), f32(t.region[1])}
	frag[3] = {f32(freq.x), f32(freq.y), 0, 0}
	return
}

// The neighbourhood filters' valid rectangle: frag[9].zw, frag[10].xy.
@(private = "file")
set_valid :: proc "contextless" (frag: ^[14][4]f32, v: [4]f32) {
	frag[9].zw = v.xy
	frag[10].xy = v.zw
}

// ---- pipelines ------------------------------------------------------------------------

@(private = "file")
blend_factor :: proc(f: vg.Blend_Factor) -> sdl.GPUBlendFactor {
	switch f {
	case .Zero:
		return .ZERO
	case .One:
		return .ONE
	case .Src_Color:
		return .SRC_COLOR
	case .One_Minus_Src_Color:
		return .ONE_MINUS_SRC_COLOR
	case .Dst_Color:
		return .DST_COLOR
	case .One_Minus_Dst_Color:
		return .ONE_MINUS_DST_COLOR
	case .Src_Alpha:
		return .SRC_ALPHA
	case .One_Minus_Src_Alpha:
		return .ONE_MINUS_SRC_ALPHA
	case .Dst_Alpha:
		return .DST_ALPHA
	case .One_Minus_Dst_Alpha:
		return .ONE_MINUS_DST_ALPHA
	case .Src_Alpha_Saturate:
		return .SRC_ALPHA_SATURATE
	}
	return .ONE
}

@(private = "file")
get_pipeline :: proc(b: ^SDL_Backend, key: Pipeline_Key) -> ^sdl.GPUGraphicsPipeline {
	if p, ok := b.pipelines[key]; ok {
		return p
	}
	buffer := sdl.GPUVertexBufferDescription {
		slot       = 0,
		pitch      = size_of(vg.Vertex),
		input_rate = .VERTEX,
	}
	attrs := [3]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(vg.Vertex, x))},
		{location = 1, buffer_slot = 0, format = .USHORT2_NORM, offset = u32(offset_of(vg.Vertex, u))},
		{location = 2, buffer_slot = 0, format = .UINT, offset = u32(offset_of(vg.Vertex, paint))},
	}
	s := key.blend
	color := sdl.GPUColorTargetDescription {
		format = key.format,
		blend_state = {
			enable_blend = true,
			src_color_blendfactor = blend_factor(s.src_rgb),
			dst_color_blendfactor = blend_factor(s.dst_rgb),
			color_blend_op = .ADD,
			src_alpha_blendfactor = blend_factor(s.src_alpha),
			dst_alpha_blendfactor = blend_factor(s.dst_alpha),
			alpha_blend_op = .ADD,
		},
	}
	if key.shapes {
		// No vertex input: the shader pulls its instances.
		info := sdl.GPUGraphicsPipelineCreateInfo {
			vertex_shader = b.shape_vert,
			fragment_shader = b.shape_group_frag if key.group else (b.shape_box_frag if key.box else b.shape_frag),
			primitive_type = .TRIANGLELIST,
			rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE},
			multisample_state = {sample_count = ._1},
			target_info = {color_target_descriptions = &color, num_color_targets = 1},
		}
		p := sdl.CreateGPUGraphicsPipeline(b.device, info)
		if p != nil {
			b.pipelines[key] = p
		}
		return p
	}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = b.vert,
		fragment_shader = b.frag,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffer,
			num_vertex_buffers = 1,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = 3,
		},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE},
		multisample_state = {sample_count = ._1},
		target_info = {color_target_descriptions = &color, num_color_targets = 1},
	}
	p := sdl.CreateGPUGraphicsPipeline(b.device, info)
	if p != nil {
		b.pipelines[key] = p
	}
	return p
}

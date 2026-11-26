package ovg_sdlgpu

import "base:runtime"
import "core:math"
import sdl "vendor:sdl3"

import vg ".."

// A frame is planned, uploaded, then recorded. Planning turns the commands
// into rows (one GPU operation each), adding the quads and paints of
// clears, filters and programs after the frame's paints. The upload writes
// each stream once, in place in its mapped transfer buffer: the quads'
// vertices (each naming its paint), the packed paints and the shape
// instances; shapes new to the store go up first. Recording merges neighbouring rows that
// share a pipeline, textures, scissor and target into one draw call. Shape
// rows aren't scissored: each instance carries its scissor's pixels, which
// the shader keeps to where the instance's quad reaches out of them, so
// instances under any scissors draw together.

Pipeline_Key :: struct {
	blend:  vg.Composite_Operation_State,
	format: sdl.GPUTextureFormat,
	// The fragment shader: the shape ones (shapes.odin) pull their
	// instances, the others draw quads.
	frag:   Frag,
	// A second colour target's format (INVALID: none): a twinned target's
	// velocity twin (TWIN_FORMAT, the shader's motion variant), or the
	// resolve's nearness.
	second: sdl.GPUTextureFormat,
}

// `vg.Params` as the shader reads it (`vg.pack_frag_uniforms`).
Paint :: [14][4]f32

// A quad's vertex as the triangle pipeline takes it: the position, a (u, v)
// pair in 0..1 as 16-bit fractions, and the row of the frame's paints it is
// drawn with.
Vertex :: struct {
	x, y:  f32,
	u, v:  u16,
	paint: u32,
}

@(private = "file")
vertex :: #force_inline proc "contextless" (x, y, u, v: f32, paint: u32) -> Vertex {
	unorm16 :: #force_inline proc "contextless" (f: f32) -> u16 {
		return u16(clamp(f, 0, 1) * 65535 + 0.5)
	}
	return {x, y, unorm16(u), unorm16(v), paint}
}

Row_Kind :: enum u8 {
	// The planner's quads `verts` (clears, filters) into `target`.
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
	// The second colour target (`Pipeline_Key.second`; texture nil: none).
	second:   Image,
	// Drawing coordinates of the target's top-left pixel.
	origin:   [2]i32,
	key:      Pipeline_Key,
	textures: [2]sdl.GPUTextureSamplerBinding,
	scissor:  sdl.Rect,
	// The planner's quad vertices, or for Shapes instances.
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
	// What this puts on the temp allocator goes when it returns.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	b := (^SDL_Backend)(data)
	o := (^Output)(uintptr(out))
	b.frame += 1
	b.stats = {shape_instances = len(frame.shapes)}
	evict_textures(b, &b.scratch)
	evict_textures(b, &b.twins)

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
	vert_count := len(b.verts)
	paint_count := len(frame.paints) + len(b.paints)
	instance_count := len(frame.shapes) + len(b.groups)
	motion_count := len(frame.motions)
	// A frame whose buffers the device can't provide (out of memory, a lost
	// device) is dropped, not drawn from nil buffers.
	if !stream_reserve(b, &b.vertex_stream, vert_count * size_of(Vertex), {.VERTEX}) ||
	   !stream_reserve(b, &b.paint_stream, paint_count * size_of(Paint), {.GRAPHICS_STORAGE_READ}) ||
	   !stream_reserve(b, &b.instance_stream, instance_count * size_of(vg.Shader_Instance), {.GRAPHICS_STORAGE_READ}) ||
	   (motion_count > 0 && !stream_reserve(b, &b.motion_stream, motion_count * size_of(vg.Shader_Motion), {.GRAPHICS_STORAGE_READ})) {
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
		if verts := ([^]Vertex)(stream_map(b, &b.vertex_stream, vert_count)); verts != nil {
			copy(verts[:vert_count], b.verts[:])
			stream_commit(b, &b.vertex_stream, copy_pass, vert_count * size_of(Vertex))
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
		if out := ([^]vg.Shader_Instance)(stream_map(b, &b.instance_stream, instance_count)); out != nil {
			for inst, i in frame.shapes {
				out[i] = vg.shader_instance(inst, frame.shape_words, b.shape_offsets[i], b.shape_clips[i])
			}
			copy(out[len(frame.shapes):instance_count], b.groups[:])
			stream_commit(b, &b.instance_stream, copy_pass, instance_count * size_of(vg.Shader_Instance))
		} else {
			uploaded = false
		}
	}
	if motion_count > 0 {
		if out := ([^]vg.Shader_Motion)(stream_map(b, &b.motion_stream, motion_count)); out != nil {
			for m, i in frame.motions {
				out[i] = vg.shader_motion(m)
			}
			stream_commit(b, &b.motion_stream, copy_pass, motion_count * size_of(vg.Shader_Motion))
		} else {
			uploaded = false
		}
	}
	sdl.EndGPUCopyPass(copy_pass)
	if !uploaded {
		drop(cmd, owned)
		return
	}
	clear(&b.shapes.pending)
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
	retire_buffer(b.device, b.retired, s.buffer)
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
	// The target's velocity twin (texture nil: none).
	twin:   Image,
}

// Where the planner's next quad starts in the vertex buffer.
@(private = "file")
extra_base :: proc(p: ^Planner) -> u32 {
	return u32(len(p.b.verts))
}

// False when the frame's shapes don't fit the store.
@(private = "file")
plan_frame :: proc(b: ^SDL_Backend, images: ^vg.Image_Store, frame: vg.Frame, screen: Image) -> bool {
	clear(&b.verts)
	clear(&b.paints)
	clear(&b.rows)
	clear(&b.groups)
	clear(&b.group_words)
	clear(&b.twin_of)
	b.motion_frame = frame.motion
	p := Planner {
		b      = b,
		images = images,
		frame  = frame,
		screen = screen,
		target = screen,
	}
	if frame.motion {
		p.twin = plan_twin(&p, screen)
	}
	resize(&b.shape_clips, len(frame.shapes))
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
			p.twin = plan_twin(&p, p.target) if c.velocity else {}
		case vg.Cmd_Composite_Velocity:
			plan_composite_velocity(&p, c)
		case vg.Cmd_Clear_Rect:
			plan_clear(&p, cmd, c)
		case vg.Cmd_Draw_Shapes:
			if c.instances.count == 0 {
				continue
			}
			row := draw_row(&p, cmd)
			// The whole target cuts nothing a draw would draw: no quad
			// reaches out of it.
			sc := row.scissor
			clip := [4]f32{-math.F32_MAX, -math.F32_MAX, math.F32_MAX, math.F32_MAX}
			if sc != {0, 0, i32(p.target.width), i32(p.target.height)} {
				clip = {f32(sc.x), f32(sc.y), f32(sc.x + sc.w), f32(sc.y + sc.h)}
			}
			for &k in b.shape_clips[c.instances.start:][:c.instances.count] {
				k = clip
			}
			row.kind = .Shapes
			row.scissor = {0, 0, i32(p.target.width), i32(p.target.height)}
			if c.group != 0 {
				plan_group(&p, row, c, clip)
				continue
			}
			plan_shape_rows(&p, row, c.instances)
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
	plan_resolve_velocity(&p)
	grids, placed := store_place(b, frame)
	for &g in b.groups {
		g.data.x += grids
	}
	return placed
}

// ---- motion blur ----------------------------------------------------------------------

// The twin of `target` this frame: one the frame gave it already, else a
// free one of its size (made if none is), the screen's cleared first (a
// layer clears its own). Texture nil when none can be made: its motion is
// lost.
@(private = "file")
plan_twin :: proc(p: ^Planner, target: Image) -> Image {
	b := p.b
	for t in b.twin_of {
		if t.target == target.texture {
			return b.twins[t.twin].image
		}
	}
	at := -1
	for t, i in b.twins {
		if t.last_used != b.frame && t.image.width == target.width && t.image.height == target.height {
			at = i
			break
		}
	}
	if at < 0 {
		img, err := create_texture(b, target.width, target.height, TWIN_FORMAT, {.SAMPLER, .COLOR_TARGET})
		if err != nil {
			return {}
		}
		append(&b.twins, Cached_Texture{img^, b.frame})
		free(img, b.allocator)
		at = len(b.twins) - 1
	}
	b.twins[at].last_used = b.frame
	append(&b.twin_of, Twin_Of{target.texture, at})
	twin := b.twins[at].image
	if target.texture == p.screen.texture {
		plan_quad(p, twin, {}, {blend = vg.composite_state_from_op(.Copy), format = TWIN_FORMAT, frag = .Main}, {texture_binding(b, nil), texture_binding(b, nil)}, {0, 0, f32(twin.width), f32(twin.height)}, add_paint(p, solid_paint({})))
	}
	return twin
}

// A layer's motion onto the target's twin (vg.Cmd_Composite_Velocity): a
// quad over its window sampling its twin and its coverage, blended
// source-over.
@(private = "file")
plan_composite_velocity :: proc(p: ^Planner, c: vg.Cmd_Composite_Velocity) {
	src, alpha := lookup(p, c.source), lookup(p, c.alpha)
	if p.twin.texture == nil || src == nil || alpha == nil {
		return
	}
	for t in p.b.twin_of {
		if t.target != src.texture {
			continue
		}
		// The opacity rides in the paint's first word (fs_composite_velocity).
		paint := add_paint(p, {0 = {c.opacity, 0, 0, 0}})
		nearest := p.b.samplers[4]
		key := Pipeline_Key{blend = vg.composite_state_from_op(.Source_Over), format = TWIN_FORMAT, frag = .Composite_Velocity}
		plan_quad(p, p.twin, p.origin, key, {{p.b.twins[t.twin].image.texture, nearest}, {alpha.texture, nearest}}, {c.x, c.y, c.w, c.h}, paint)
		return
	}
}

// The screen's twin as the velocity and nearness textures, after the
// frame's drawing.
@(private = "file")
plan_resolve_velocity :: proc(p: ^Planner) {
	b := p.b
	twin: Image
	for t in b.twin_of {
		if t.target == p.screen.texture {
			twin = b.twins[t.twin].image
		}
	}
	if twin.texture == nil {
		b.motion_frame = false
		return
	}
	for out, k in ([2]^^Image{&b.velocity, &b.nearness}) {
		format := VELOCITY_FORMAT if k == 0 else NEARNESS_FORMAT
		if out^ != nil && (out^.width != twin.width || out^.height != twin.height) {
			release_image(b, out^)
			out^ = nil
		}
		if out^ == nil {
			img, err := create_texture(b, twin.width, twin.height, format, {.SAMPLER, .COLOR_TARGET})
			if err != nil {
				b.motion_frame = false
				return
			}
			out^ = img
		}
	}
	key := Pipeline_Key{blend = vg.composite_state_from_op(.Copy), format = VELOCITY_FORMAT, frag = .Resolve_Velocity, second = NEARNESS_FORMAT}
	plan_quad(p, b.velocity^, {}, key, {{twin.texture, b.samplers[4]}, texture_binding(b, nil)}, {0, 0, f32(twin.width), f32(twin.height)}, 0, b.nearness^)
}

// A row drawing one quad over `rect` (drawing coordinates, texture
// coordinates 0..1) into `target` placed at `origin`.
@(private = "file")
plan_quad :: proc(p: ^Planner, target: Image, origin: [2]i32, key: Pipeline_Key, textures: [2]sdl.GPUTextureSamplerBinding, rect: vg.Rect, paint: u32, second := Image{}) {
	append(&p.b.rows, Row{kind = .Draw, target = target, second = second, origin = origin, key = key, textures = textures, scissor = {0, 0, i32(target.width), i32(target.height)}, verts = {extra_base(p), 6}})
	x0, y0 := rect.x, rect.y
	x1, y1 := x0 + rect.w, y0 + rect.h
	append(&p.b.verts, vertex(x0, y0, 0, 0, paint), vertex(x1, y0, 1, 0, paint), vertex(x1, y1, 1, 1, paint))
	append(&p.b.verts, vertex(x0, y0, 0, 0, paint), vertex(x1, y1, 1, 1, paint), vertex(x0, y1, 0, 1, paint))
}

// A paint filling with premultiplied `color`.
@(private = "file")
solid_paint :: proc(color: [4]f32) -> Paint {
	params := vg.default_params()
	params.shader_type = .Fill_Color
	params.inner_col = color
	params.outer_col = color
	params.stroke_mult = 1
	params.stroke_thr = -1
	return vg.pack_frag_uniforms(params)
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

// A row drawing `cmd` into the current target (and its twin); the caller
// sets its vertices.
@(private = "file")
draw_row :: proc(p: ^Planner, cmd: vg.Command) -> Row {
	scissor := sdl.Rect{0, 0, i32(p.target.width), i32(p.target.height)}
	if sr, has := cmd.scissor_rect.?; has {
		scissor = target_rect(p.target, p.origin, sr)
	}
	return {
		kind = .Draw,
		target = p.target,
		second = p.twin,
		origin = p.origin,
		key = {blend = cmd.composite_operation, format = p.target.format, second = TWIN_FORMAT if p.twin.texture != nil else .INVALID},
		textures = {texture_binding(p.b, lookup(p, cmd.image)), texture_binding(p.b, nil)},
		scissor = scissor,
	}
}

// Two triangles over (0, 0)..(w, h), texture coordinates 0..1.
@(private = "file")
emit_quad :: proc(p: ^Planner, w, h: f32, paint: u32) {
	append(&p.b.verts, vertex(0, 0, 0, 0, paint), vertex(w, 0, 1, 0, paint), vertex(w, h, 1, 1, paint))
	append(&p.b.verts, vertex(0, 0, 0, 0, paint), vertex(w, h, 1, 1, paint), vertex(0, h, 0, 1, paint))
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
	paint := add_paint(p, solid_paint(vg.color_to_array(vg.premultiplied(c.color))))
	row := draw_row(p, cmd)
	row.scissor = area
	row.verts = {extra_base(p), 6}
	append(&p.b.rows, row)
	x0, y0 := f32(c.x), f32(c.y)
	x1, y1 := x0 + f32(c.w), y0 + f32(c.h)
	append(&p.b.verts, vertex(x0, y0, 0.5, 1, paint), vertex(x1, y0, 0.5, 1, paint), vertex(x1, y1, 0.5, 1, paint))
	append(&p.b.verts, vertex(x0, y0, 0.5, 1, paint), vertex(x1, y1, 0.5, 1, paint), vertex(x0, y1, 0.5, 1, paint))
}

// Rows drawing `instances` with `base`'s state: one per stretch of
// instances that are all boxes (no rotation or skew: the box shader) or
// all not. Fills and hairlines share both shaders, so mixing them costs no
// row.
@(private = "file")
plan_shape_rows :: proc(p: ^Planner, base: Row, instances: vg.Range) {
	row := base
	start := instances.start
	for i in instances.start ..< instances.start + instances.count {
		inst := &p.frame.shapes[i]
		frag := Frag.Shape_Box if inst.transform[1] == 0 && inst.transform[2] == 0 else .Shape
		if i > start && frag != row.key.frag {
			row.verts = {start, i - start}
			append(&p.b.rows, row)
			start = i
		}
		row.key.frag = frag
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
// placed in the store): its columns and rows (nx | ny << 16), each cell's
// first list entry, one more for the end, then the lists (instances from
// the first).
@(private = "file")
plan_group :: proc(p: ^Planner, base: Row, c: vg.Cmd_Draw_Shapes, clip: [4]f32) {
	b := p.b
	g := vg.group_grid(&b.group_grid, &b.group_words, p.frame.shapes[c.instances.start:][:c.instances.count], p.frame.shape_words)
	row := base
	row.key.frag = .Marker_Group if p.frame.shapes[c.instances.start].marker != .None else .Shape_Group
	first := len(b.groups)
	for j in 0 ..< g.ny {
		for i := 0; i < g.nx; {
			if !vg.group_cell_listed(b.group_words[:], g, i, j) {
				i += 1
				continue
			}
			i0 := i
			for i < g.nx && vg.group_cell_listed(b.group_words[:], g, i, j) {
				i += 1
			}
			append(&b.groups, vg.Shader_Instance {
				m = {g.cell.x, 0, 0, g.cell.y},
				t = {g.area.minx, g.area.miny, 0, 0},
				bounds = {f32(i0), f32(j), f32(i), f32(j + 1)},
				data = {u32(g.head), c.group - 1, c.instances.start, 0},
				clip = clip,
			})
		}
	}
	row.verts = {u32(len(p.frame.shapes) + first), u32(len(b.groups) - first)}
	append(&b.rows, row)
}

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
		key      = {blend = vg.composite_state_from_op(.Copy), format = dst.format, frag = .Filter},
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

// Image filters: full-target quads drawn with Copy blend, as
// `vg.filter_plan` lays out their passes and paints.
@(private = "file")
plan_filter :: proc(p: ^Planner, cmd: vg.Command, c: vg.Cmd_Filter_Image) {
	filter := p.frame.filters[c.filter]
	src_info, ok := vg.image_store_info(p.images, cmd.image)
	dst_info, dst_ok := vg.image_store_info(p.images, c.target_image)
	if !ok || !dst_ok {
		return
	}
	backdrop := vg.filter_backdrop(filter)
	back: Maybe(vg.Image_Info)
	if info, back_ok := vg.image_store_info(p.images, backdrop); vg.image_id_valid(backdrop) && back_ok {
		back = info
	}
	plan, plan_ok := vg.filter_plan(filter, src_info, dst_info, back, c.target_image == cmd.image || c.target_image == backdrop)
	if !plan_ok {
		return
	}
	src, target := lookup(p, cmd.image), lookup(p, c.target_image)
	mid: ^Image
	if plan.count == 2 || plan.copy {
		mid = scratch_image(p.b, src_info if plan.count == 2 else dst_info)
		if mid == nil {
			return
		}
	}
	for pass in plan.passes[:plan.count] {
		plan_filter_pass(p, mid if pass.from_mid else src, lookup(p, backdrop), mid if pass.to_mid else target, pass.paint)
	}
	if plan.copy {
		plan_copy(p, mid, target)
	}
}

// ---- recording ------------------------------------------------------------------------

@(private = "file")
Recorder :: struct {
	b:        ^SDL_Backend,
	images:   ^vg.Image_Store,
	frame:    vg.Frame,
	cmd:      ^sdl.GPUCommandBuffer,
	pass:     ^sdl.GPURenderPass,
	// The open pass's targets and origin.
	target:   ^sdl.GPUTexture,
	second:   ^sdl.GPUTexture,
	origin:   [2]i32,
	// The open pass's vertex uniforms (shape.vert's view and first).
	view:     Shape_Uniforms,
	// State set in the open pass.
	pipeline: ^sdl.GPUGraphicsPipeline,
	textures: [2]sdl.GPUTextureSamplerBinding,
	scissor:  sdl.Rect,
	// The draw being gathered: rows merge into it while they continue it.
	pending:   Row,
	gathering: bool,
}

@(private = "file")
Shape_Uniforms :: struct {
	view:  [4]f32,
	first: u32,
	_:     [3]u32,
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
			row.external.fn(row.external.user, cmd, images)
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
		row.second.texture == pending.second.texture &&
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
	if row.own_pass || r.target != row.target.texture || r.second != row.second.texture || r.origin != row.origin {
		end_pass(r)
	}
	if !begin_pass(r, row.target, row.second, row.origin) {
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
		// Six vertices an instance, from 0: first + gl_VertexID / 6 is the
		// instance's row (shape.vert).
		if r.view.first != u32(row.verts.start) {
			r.view.first = u32(row.verts.start)
			sdl.PushGPUVertexUniformData(r.cmd, 0, &r.view, size_of(r.view))
		}
		sdl.DrawGPUPrimitives(r.pass, 6 * row.verts.count, 1, 0, 0)
	} else {
		sdl.DrawGPUPrimitives(r.pass, row.verts.count, 1, row.verts.start, 0)
	}
	if row.own_pass {
		end_pass(r)
	}
}

// Starts a render pass on `target` (and `second`) if none is open.
@(private = "file")
begin_pass :: proc(r: ^Recorder, target, second: Image, origin: [2]i32) -> bool {
	if r.pass != nil {
		return true
	}
	color := [2]sdl.GPUColorTargetInfo{{texture = target.texture, load_op = .LOAD, store_op = .STORE}, {texture = second.texture, load_op = .LOAD, store_op = .STORE}}
	r.pass = sdl.BeginGPURenderPass(r.cmd, &color[0], 2 if second.texture != nil else 1, nil)
	if r.pass == nil {
		return false
	}
	r.b.stats.render_passes += 1
	r.target, r.second, r.origin = target.texture, second.texture, origin
	vertices := sdl.GPUBufferBinding {
		buffer = r.b.vertex_stream.buffer,
	}
	sdl.BindGPUVertexBuffers(r.pass, 0, &vertices, 1)
	// The group shader reads the instances too, and the motion variants
	// their motions.
	storage := [4]^sdl.GPUBuffer{r.b.paint_stream.buffer, r.b.shapes.buffer, r.b.instance_stream.buffer, r.b.motion_stream.buffer}
	bound: u32 = 1
	if storage[1] != nil && storage[2] != nil {
		bound = 4 if second.texture != nil && storage[3] != nil else 3
	}
	sdl.BindGPUFragmentStorageBuffers(r.pass, 0, &storage[0], bound)
	if instances := r.b.instance_stream.buffer; instances != nil {
		sdl.BindGPUVertexStorageBuffers(r.pass, 0, &instances, 1)
	}
	// The vertex shader subtracts the origin (zw) before mapping to NDC.
	r.view = {view = {f32(target.width), f32(target.height), f32(origin.x), f32(origin.y)}}
	sdl.PushGPUVertexUniformData(r.cmd, 0, &r.view, size_of(r.view))
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
		r.target, r.second = nil, nil
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
		pitch      = size_of(Vertex),
		input_rate = .VERTEX,
	}
	attrs := [2]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Vertex, x))},
		{location = 1, buffer_slot = 0, format = .USHORT2_NORM, offset = u32(offset_of(Vertex, u))},
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
			retire_texture(b.device, b.retired, cache[i].image.texture)
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
		pitch      = size_of(Vertex),
		input_rate = .VERTEX,
	}
	attrs := [3]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Vertex, x))},
		{location = 1, buffer_slot = 0, format = .USHORT2_NORM, offset = u32(offset_of(Vertex, u))},
		{location = 2, buffer_slot = 0, format = .UINT, offset = u32(offset_of(Vertex, paint))},
	}
	blend :: proc(s: vg.Composite_Operation_State) -> sdl.GPUColorTargetBlendState {
		return {
			enable_blend = true,
			src_color_blendfactor = blend_factor(s.src_rgb),
			dst_color_blendfactor = blend_factor(s.dst_rgb),
			color_blend_op = .ADD,
			src_alpha_blendfactor = blend_factor(s.src_alpha),
			dst_alpha_blendfactor = blend_factor(s.dst_alpha),
			alpha_blend_op = .ADD,
		}
	}
	// A draw's motion goes over the twin's source-over, whatever its blend;
	// a clear's (Main) and the resolve's copy as the colour does.
	color := [2]sdl.GPUColorTargetDescription{{format = key.format, blend_state = blend(key.blend)}, {format = key.second, blend_state = blend(key.blend if key.frag == .Main || key.frag == .Resolve_Velocity else vg.composite_state_from_op(.Source_Over))}}
	targets: u32 = 1 if key.second == .INVALID else 2
	frag := b.frags[key.frag][1] if targets == 2 && b.frags[key.frag][1] != nil else b.frags[key.frag][0]
	if key.frag >= .Shape && key.frag <= .Marker_Group {
		// No vertex input: the shader pulls its instances.
		info := sdl.GPUGraphicsPipelineCreateInfo {
			vertex_shader = b.shape_vert,
			fragment_shader = frag,
			primitive_type = .TRIANGLELIST,
			rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE},
			multisample_state = {sample_count = ._1},
			target_info = {color_target_descriptions = &color[0], num_color_targets = targets},
		}
		p := sdl.CreateGPUGraphicsPipeline(b.device, info)
		if p != nil {
			b.pipelines[key] = p
		}
		return p
	}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = b.vert,
		fragment_shader = frag,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffer,
			num_vertex_buffers = 1,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = 3,
		},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE},
		multisample_state = {sample_count = ._1},
		target_info = {color_target_descriptions = &color[0], num_color_targets = targets},
	}
	p := sdl.CreateGPUGraphicsPipeline(b.device, info)
	if p != nil {
		b.pipelines[key] = p
	}
	return p
}

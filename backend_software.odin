package ovg

import "base:runtime"
import "core:math"
import "core:mem"
import "core:simd"
import "core:slice"
import "core:strings"
import "core:sync"
import common "deps:oicut/common"
import "deps:oksl"

// CPU rasterizer writing RGBA8. It runs the GPU backends' shaders
// (shaders/) on oksl's CPU program, textures bound to oksl as images, so its
// output is a pixel reference for GPU backends: one sample at each pixel
// center, blending in [0, 1] with rounding to 8 bits.
Software_Backend :: struct {
	allocator: mem.Allocator,
	pixels:    []u8,
	width:     u32,
	height:    u32,
	target:    Image_Id,
	// The target's `Cmd_Set_Render_Target.origin`.
	origin:    [2]i32,
	// A filter's intermediate (filter_plan), reused.
	blur_tmp:  []u8,
	// A run's draws by band (sw_draw_run): band k's are
	// `binned[starts[k]:starts[k + 1]]`, in drawing order; `bounds` holds
	// the run's instances' bounds by their index in the frame's shapes.
	binned:    [dynamic]Sw_Binned,
	starts:    [dynamic]u32,
	bounds:    [dynamic]Bounds,
	// `.Transient` images' pixels, one block carved in order for a render
	// (sw_lend) and kept at the largest render's size.
	transient: []u8,
	// The caller's pool a frame's row bands run on (oicut's Work_Pool: one
	// band a range); nil runs them all on the calling thread. A band takes
	// its shading memory from `lanes_free`.
	pool:      ^common.Work_Pool,
	// Motion blur (Frame.motion): the velocity twins of the screen and of
	// each image a frame draws into with `velocity`, one block carved for a
	// render (sw_twins) and kept at the largest render's size; `twin_at`
	// holds an image's span start by its slot (-1: none). A twin pixel is
	// (a * velocity, a * nearness, a): premultiplied by coverage.
	twins:     [][4]f32,
	twin_at:   [dynamic]int,
	// The screen's twin and the current target's (pixels nil: none).
	screen_twin: Sw_Twin,
	twin:      Sw_Twin,
	// The last frame's velocity and nearness (software_backend_velocity).
	velocity:  [dynamic][2]f32,
	nearness:  [dynamic]f32,
	// The units (shaders.odin) as oksl's CPU programs, [1] each's motion
	// variant: the shading the SDL_GPU backend's shaders do, from the same
	// source. Each is compiled the first time a run draws with it.
	programs:  [Sw_Unit][2]Sw_Program_Unit,
	// The frame's paints and motions as the shaders read them.
	paint_rows:  [dynamic][14][4]f32,
	motion_rows: [dynamic]Shader_Motion,
	// A run's groups (Cmd_Draw_Shapes.group), built before its bands: their
	// grids and members' words, the members' rows and motions as the shaders
	// read them, each group's grid and first row, and each command's group.
	group_words:   [dynamic]u32,
	group_rows:    [dynamic]Shader_Instance,
	group_motions: [dynamic]Shader_Motion,
	groups:        [dynamic]Sw_Group,
	group_of:      [dynamic]i32,
	group_grid:    Group_Grid_Scratch,
	// The bands' shading memory, kept warm across frames: a band takes a set
	// off `lanes_free` (making one when none is) and puts it back, so there
	// are as many as bands ever drew at once. On the heap, which the pool's
	// threads can grow from together, and not in their temp arenas, where a
	// band's 150 KB or so would open a first block of 4 MiB, zeroed.
	lanes_free:    [dynamic]^Sw_Lanes,
	lanes_lock:    sync.Mutex,
}

// The units the software backend runs on oksl's CPU program: every one but
// the clears' (sw_clear_rect) and the velocity resolve's (a copy out of the
// screen's twin, sw_resolve_velocity).
@(private = "file")
Sw_Unit :: enum u8 {
	Shape,
	Shape_Box,
	Shape_Group,
	Marker_Group,
	Filter,
	Composite_Velocity,
}

@(private = "file", rodata)
SW_UNITS := [Sw_Unit]Shader_Unit {
	.Shape              = .Shape,
	.Shape_Box          = .Shape_Box,
	.Shape_Group        = .Shape_Group,
	.Marker_Group       = .Marker_Group,
	.Filter             = .Filter,
	.Composite_Velocity = .Composite_Velocity,
}

// A unit's CPU program and where its uniforms are in its uniform block
// (-1: it reads none): the shape units' uv, data and map from drawing
// coordinates to rc (rc_linear, rc_offset), the quad units' quad_tc and
// paint. It has no stage inputs.
@(private = "file")
Sw_Program_Unit :: struct {
	module:        ^oksl.Module,
	uv_at:         int,
	data_at:       int,
	rc_linear_at:  int,
	rc_offset_at:  int,
	quad_tc_at:    int,
	paint_at:      int,
}

// A group of a run: its grid in `group_words` and its first member's row
// in `group_rows`.
@(private = "file")
Sw_Group :: struct {
	grid:  Group_Grid,
	first: u32,
}

software_backend_init :: proc(b: ^Software_Backend, allocator := context.allocator) {
	b^ = {allocator = allocator}
	b.binned = make([dynamic]Sw_Binned, allocator)
	b.starts = make([dynamic]u32, allocator)
	b.bounds = make([dynamic]Bounds, allocator)
	b.twin_at = make([dynamic]int, allocator)
	b.velocity = make([dynamic][2]f32, allocator)
	b.nearness = make([dynamic]f32, allocator)
	b.paint_rows = make([dynamic][14][4]f32, allocator)
	b.motion_rows = make([dynamic]Shader_Motion, allocator)
	b.group_words = make([dynamic]u32, allocator)
	b.group_rows = make([dynamic]Shader_Instance, allocator)
	b.group_motions = make([dynamic]Shader_Motion, allocator)
	b.groups = make([dynamic]Sw_Group, allocator)
	b.group_of = make([dynamic]i32, allocator)
	b.group_grid = {make([dynamic]Bounds, allocator), make([dynamic][4]i32, allocator), make([dynamic]u32, allocator)}
	b.lanes_free = make([dynamic]^Sw_Lanes, runtime.heap_allocator())
}

// Compiles the units `needs` (their motion variants with `motion`) that
// aren't yet, before a run's bands read them. They are ovg's own sources,
// which test_shaders_compile compiles, so a failure is a bug.
@(private = "file")
sw_programs_need :: proc(b: ^Software_Backend, needs: bit_set[Sw_Unit], motion: int) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	for u in needs {
		p := &b.programs[u][motion]
		if p.module != nil {
			continue
		}
		unit := SW_UNITS[u]
		prelude := strings.concatenate({shader_cpu_defines(unit), shader_prelude(unit, motion == 1, context.temp_allocator)}, context.temp_allocator)
		context.allocator = b.allocator
		m, _, ok := oksl.compile(SHADER_SOURCES[unit].source, {profile = .Glsl, prelude = prelude, no_spirv = true, no_msl = true})
		assert(ok, "ovg's shaders compile for oksl's CPU program")
		assert(m.block_size <= SW_UNIFORM_BYTES && len(m.stage_inputs) == 0)
		at :: proc(m: ^oksl.Module, name: string) -> int {
			u, has := oksl.find_uniform(m, name)
			return u.offset if has else -1
		}
		p^ = {module = m, uv_at = at(m, "uv"), data_at = at(m, "data"), rc_linear_at = at(m, "rc_linear"), rc_offset_at = at(m, "rc_offset"), quad_tc_at = at(m, "quad_tc"), paint_at = at(m, "quad_paint")}
	}
}

software_backend_destroy :: proc(b: ^Software_Backend) {
	delete(b.pixels, b.allocator)
	delete(b.blur_tmp, b.allocator)
	delete(b.binned)
	delete(b.starts)
	delete(b.bounds)
	delete(b.transient, b.allocator)
	delete(b.twins, b.allocator)
	delete(b.twin_at)
	delete(b.velocity)
	delete(b.nearness)
	delete(b.paint_rows)
	delete(b.motion_rows)
	delete(b.group_words)
	delete(b.group_rows)
	delete(b.group_motions)
	delete(b.groups)
	delete(b.group_of)
	group_grid_scratch_destroy(&b.group_grid)
	for L in b.lanes_free {
		sw_lanes_destroy(L)
	}
	delete(b.lanes_free)
	for variants in b.programs {
		for p in variants {
			if p.module != nil {
				oksl.destroy(p.module)
			}
		}
	}
	b^ = {}
}

software_backend :: proc(b: ^Software_Backend) -> Backend {
	return {
		data = b,
		set_size = sw_set_size,
		render = sw_render,
		alloc_image = sw_alloc_image,
		update_image = sw_update_image,
		delete_image = sw_delete_image,
		screenshot = sw_screenshot,
		read_image = sw_read_image,
		memory_images = true,
		create_program = sw_create_program,
		delete_program = sw_delete_program,
	}
}

// The screen contents (RGBA8, premultiplied, top-down).
software_backend_pixels :: proc(b: ^Software_Backend) -> Image_Source {
	return image_source_rgba(b.pixels, b.width, b.height)
}

// Motion blur (canvas_motion_blur): the last frame's velocity (pixels, the
// shutter's middle minus its opening) and nearness at each screen pixel,
// top-down, each the draws' over the pixel by their coverage over still,
// farthest ground, as o3d's motion_blur takes them; empty after a frame
// without.
software_backend_velocity :: proc(b: ^Software_Backend) -> (velocity: [][2]f32, nearness: []f32) {
	return b.velocity[:], b.nearness[:]
}

@(private = "file")
sw_set_size :: proc(data: rawptr, width, height: u32, dpi: f32) {
	b := (^Software_Backend)(data)
	if width == b.width && height == b.height && b.pixels != nil {
		return
	}
	delete(b.pixels, b.allocator)
	b.pixels = make([]u8, int(width * height * 4), b.allocator)
	b.width = width
	b.height = height
}

@(private = "file")
sw_alloc_image :: proc(data: rawptr, info: Image_Info) -> (Backend_Image, Error) {
	b := (^Software_Backend)(data)
	if .Transient in info.flags {
		// Pixels are lent for each render (sw_lend).
		return {}, nil
	}
	pixels, err := make([]u8, int(info.width * info.height * bytes_per_pixel(info.format)), b.allocator)
	if err != nil {
		return {}, .Out_Of_Memory
	}
	return {pixels = pixels}, nil
}

@(private = "file")
sw_update_image :: proc(data: rawptr, img: ^Backend_Image, info: Image_Info, src: Image_Source, x, y: u32) -> Error {
	if .Transient in info.flags {
		return .Unsupported_Operation
	}
	bpp := bytes_per_pixel(info.format)
	src_stride := image_source_stride(src)
	dst_stride := info.width * bpp
	row_bytes := src.width * bpp
	for row in 0 ..< src.height {
		s := src.data[row * src_stride:][:row_bytes]
		d := img.pixels[(y + row) * dst_stride + x * bpp:][:row_bytes]
		copy(d, s)
	}
	return nil
}

@(private = "file")
sw_delete_image :: proc(data: rawptr, img: Backend_Image, id: Image_Id) {
	b := (^Software_Backend)(data)
	if b.target == id {
		b.target = {}
	}
	delete(img.pixels, b.allocator)
}

@(private = "file")
sw_read_image :: proc(data: rawptr, img: Backend_Image, info: Image_Info, allocator: mem.Allocator) -> ([]u8, Error) {
	if .Transient in info.flags {
		return nil, .Unsupported_Operation
	}
	n := int(info.width * info.height * bytes_per_pixel(info.format))
	pixels, err := make([]u8, n, allocator)
	if err != nil {
		return nil, .Out_Of_Memory
	}
	copy(pixels, img.pixels[:n])
	return pixels, nil
}

@(private = "file")
sw_screenshot :: proc(data: rawptr, allocator: mem.Allocator) -> (Screenshot, Error) {
	b := (^Software_Backend)(data)
	pixels, err := make([]u8, len(b.pixels), allocator)
	if err != nil {
		return {}, .Out_Of_Memory
	}
	copy(pixels, b.pixels)
	return {pixels, b.width, b.height}, nil
}

// ---- frame execution ------------------------------------------------------------

@(private = "file")
Sw_Target :: struct {
	pixels: []u8,
	width:  u32,
	height: u32,
	format: Pixel_Format,
}

// A velocity twin: its target's pixels' motion (Software_Backend.twins).
@(private = "file")
Sw_Twin :: struct {
	pixels: [][4]f32,
	width:  u32,
	height: u32,
}

@(private = "file")
sw_active_target :: proc(b: ^Software_Backend, images: ^Image_Store) -> (Sw_Target, bool) {
	if image_id_valid(b.target) {
		entry := image_store_get(images, b.target)
		if entry == nil || entry.image.pixels == nil {
			return {}, false
		}
		return {entry.image.pixels, entry.info.width, entry.info.height, entry.info.format}, true
	}
	return {b.pixels, b.width, b.height, .RGBA8}, true
}

// Clears and draws gather into runs on one target, each drawn in row bands
// (sw_draw_run); a target switch, a filter, a program or an external ends a
// run and runs on its own, after it.
@(private = "file")
sw_render :: proc(data: rawptr, output: Render_Output, images: ^Image_Store, frame: Frame) {
	b := (^Software_Backend)(data)
	sw_lend(b, images)
	sw_twins(b, images, frame)
	b.target = {}
	b.origin = {}
	b.twin = sw_twin_of(b, images, nil, frame.motion)
	// The frame's instances' bounds: room for its largest frame, kept.
	if len(b.bounds) < len(frame.shapes) {
		resize(&b.bounds, len(frame.shapes))
	}
	// The paints and motions as the shaders read them, once a frame.
	resize(&b.paint_rows, len(frame.paints))
	for p, i in frame.paints {
		b.paint_rows[i] = pack_frag_uniforms(p)
	}
	resize(&b.motion_rows, len(frame.motions))
	for m, i in frame.motions {
		b.motion_rows[i] = shader_motion(m)
	}
	run := 0
	for cmd, i in frame.commands {
		#partial switch _ in cmd.type {
		case Cmd_Clear_Rect, Cmd_Draw_Shapes:
			continue
		}
		sw_draw_run(b, images, frame, frame.commands[run:i])
		run = i + 1
		#partial switch v in cmd.type {
		case Cmd_Set_Render_Target:
			b.target = {}
			b.origin = v.origin
			if id, is_image := v.target.(Image_Id); is_image {
				b.target = id
			}
			b.twin = sw_twin_of(b, images, v.target, v.velocity)
		case Cmd_Composite_Velocity:
			sw_composite_velocity(b, images, v)
		case Cmd_Filter_Image:
			sw_filter_image(b, images, cmd, v.target_image, frame.filters[v.filter])
		case Cmd_Run_Program:
			sw_run_program(images, frame, frame.runs[v.run])
		case Cmd_Run_External:
			v.fn(v.user, nil, images)
		}
	}
	sw_draw_run(b, images, frame, frame.commands[run:])
	sw_take_back(b, images)
	sw_resolve_velocity(b)
}

// Gives the screen and every image the frame draws into with `velocity` a
// twin, its span of one block sized for them all (grown, never shrunk),
// the screen's cleared (a layer clears its own). Out of memory leaves them
// without: their motion is lost.
@(private = "file")
sw_twins :: proc(b: ^Software_Backend, images: ^Image_Store, frame: Frame) {
	clear(&b.twin_at)
	b.screen_twin = {}
	if !frame.motion {
		return
	}
	resize(&b.twin_at, len(images.entries.slots))
	for &at in b.twin_at {
		at = -1
	}
	total := int(b.width * b.height)
	for cmd in frame.commands {
		rt, is_target := cmd.type.(Cmd_Set_Render_Target)
		id, is_image := rt.target.(Image_Id)
		if !is_target || !is_image || !rt.velocity || int(id.key.idx) >= len(b.twin_at) || b.twin_at[id.key.idx] >= 0 {
			continue
		}
		if e := image_store_get(images, id); e != nil {
			b.twin_at[id.key.idx] = total
			total += int(e.info.width * e.info.height)
		}
	}
	if len(b.twins) < total {
		delete(b.twins, b.allocator)
		b.twins, _ = make([][4]f32, total, b.allocator)
	}
	if len(b.twins) < total {
		clear(&b.twin_at)
		return
	}
	b.screen_twin = {b.twins[:b.width * b.height], b.width, b.height}
	mem.zero_slice(b.screen_twin.pixels)
}

// The twin of `target` (nil: the screen), none without `velocity`.
@(private = "file")
sw_twin_of :: proc(b: ^Software_Backend, images: ^Image_Store, target: Render_Target, velocity: bool) -> Sw_Twin {
	id, is_image := target.(Image_Id)
	if !velocity || !is_image {
		return b.screen_twin if velocity else {}
	}
	e := image_store_get(images, id)
	if e == nil || int(id.key.idx) >= len(b.twin_at) || b.twin_at[id.key.idx] < 0 {
		return {}
	}
	return {b.twins[b.twin_at[id.key.idx]:][:e.info.width * e.info.height], e.info.width, e.info.height}
}

// A layer's motion onto the target's twin (Cmd_Composite_Velocity) with
// velocity.frag, over the part of its window inside the target: its twin and
// its coverage read nearest at the pixel, as the GPU draws it.
@(private = "file")
sw_composite_velocity :: proc(b: ^Software_Backend, images: ^Image_Store, c: Cmd_Composite_Velocity) {
	src := sw_twin_of(b, images, c.source, true)
	alpha, ok := lookup_texture(images, c.alpha)
	if b.twin.pixels == nil || src.pixels == nil || !ok || c.w <= 0 || c.h <= 0 {
		return
	}
	sw_programs_need(b, {.Composite_Velocity}, 0)
	// The window's corner on the target.
	wx, wy := i32(c.x) - b.origin.x, i32(c.y) - b.origin.y
	coverage := sw_channel(alpha)
	coverage.filter, coverage.wrap = .Nearest, {}
	job := Sw_Quad_Pass {
		b       = b,
		unit    = b.programs[.Composite_Velocity][0],
		raster  = {twin = b.twin, x0 = max(wx, 0), y0 = max(wy, 0), x1 = min(wx + i32(c.w), i32(b.twin.width)), y1 = min(wy + i32(c.h), i32(b.twin.height))},
		quad_tc = {1 / c.w, 1 / c.h, -f32(wx) / c.w, -f32(wy) / c.h},
		images  = {oksl.channel_image(src.pixels, int(src.width), int(src.height)), coverage},
	}
	// The opacity rides in the paint's first word.
	job.paint[0] = {c.opacity, 0, 0, 0}
	sw_bands(b, int(b.twin.height), &job, sw_quad_band)
}

// The screen's twin as velocity and nearness (software_backend_velocity).
@(private = "file")
sw_resolve_velocity :: proc(b: ^Software_Backend) {
	n := len(b.screen_twin.pixels)
	resize(&b.velocity, n)
	resize(&b.nearness, n)
	for t, i in b.screen_twin.pixels {
		b.velocity[i] = t.xy
		b.nearness[i] = t.z
	}
}

// Gives every `.Transient` image of the store pixels for this render,
// each its span of one block sized for them all (grown, never shrunk).
// Out of memory leaves them without pixels: what draws into one or samples
// it is skipped.
@(private = "file")
sw_lend :: proc(b: ^Software_Backend, images: ^Image_Store) {
	total := 0
	for &slot in images.entries.slots {
		if e := &slot.value; slot.occupied && sw_transient(e) {
			total += sw_span(e.info)
		}
	}
	if len(b.transient) < total {
		delete(b.transient, b.allocator)
		b.transient, _ = make([]u8, total, b.allocator)
	}
	at := 0
	for &slot in images.entries.slots {
		if e := &slot.value; slot.occupied && sw_transient(e) {
			n := int(e.info.width * e.info.height * bytes_per_pixel(e.info.format))
			e.image.pixels = b.transient[at:][:n] if len(b.transient) >= total else nil
			at += sw_span(e.info)
		}
	}
}

// Takes the lent pixels back (sw_lend).
@(private = "file")
sw_take_back :: proc(b: ^Software_Backend, images: ^Image_Store) {
	for &slot in images.entries.slots {
		if e := &slot.value; slot.occupied && sw_transient(e) {
			e.image.pixels = nil
		}
	}
}

@(private = "file")
sw_transient :: #force_inline proc "contextless" (e: ^Image_Entry) -> bool {
	return !e.virtual && !e.borrowed && .Transient in e.info.flags
}

// A transient image's span of the block: its pixels, rounded up to a cache
// line so each starts on one.
@(private = "file")
sw_span :: #force_inline proc "contextless" (info: Image_Info) -> int {
	n := int(info.width * info.height * bytes_per_pixel(info.format))
	return (n + 63) &~ 63
}

// A draw of a run in the bands it reaches: the command (its index in the
// run) and its instance (index in the frame's shapes; SW_NO_INSTANCE for a
// clear).
@(private = "file")
Sw_Binned :: struct {
	cmd:  u32,
	inst: u32,
}

@(private = "file")
SW_NO_INSTANCE :: max(u32)

@(private = "file")
Sw_Run :: struct {
	b:      ^Software_Backend,
	images: ^Image_Store,
	frame:  Frame,
	cmds:   []Command,
	target: Sw_Target,
	origin: [2]i32,
	twin:   Sw_Twin,
}

// Draws a run's commands (clears and shape draws on the current target):
// each instance (or clear) is binned once into the row bands it reaches,
// then every band draws its own, in order, on the caller's pool. A pixel
// gets the same draws in the same order as drawing the commands one after
// another, so the result is the same.
@(private = "file")
sw_draw_run :: proc(b: ^Software_Backend, images: ^Image_Store, frame: Frame, cmds: []Command) {
	if len(cmds) == 0 {
		return
	}
	target, ok := sw_active_target(b, images)
	if !ok {
		return
	}
	run := Sw_Run{b, images, frame, cmds, target, b.origin, b.twin}
	rows := int(target.height)
	bands := (rows + SW_BAND_ROWS - 1) / SW_BAND_ROWS
	if bands == 0 {
		return
	}
	// Count each band's draws into starts[k + 1] (keeping the instances'
	// bounds), sum them into ends, fill each band from its start (leaving
	// starts[k] at band k's end), then shift back.
	resize(&b.starts, bands + 1)
	mem.zero_slice(b.starts[:])
	needs: bit_set[Sw_Unit]
	for fill in ([2]bool{false, true}) {
		if fill {
			for band in 0 ..< bands {
				b.starts[band + 1] += b.starts[band]
			}
			// Sized from the count: the bins keep their largest run's room.
			total := int(b.starts[bands])
			if total == 0 {
				return
			}
			if cap(b.binned) < total {
				reserve(&b.binned, total)
			}
			resize(&b.binned, total)
		}
		for cmd, k in cmds {
			r := sw_raster(&run, cmd)
			#partial switch c in cmd.type {
			case Cmd_Clear_Rect:
				sw_bin(&run, fill, {u32(k), SW_NO_INSTANCE}, max(r.y0, i32(c.y)), min(r.y1, i32(c.y + c.h)))
			case Cmd_Draw_Shapes:
				if !fill && c.group != 0 && c.instances.count > 0 {
					needs += {.Marker_Group if frame.shapes[c.instances.start].marker != .None else .Shape_Group}
				}
				for i in c.instances.start ..< c.instances.start + c.instances.count {
					if !fill {
						b.bounds[i] = instance_bounds(frame.shapes[i], frame.shape_words)
						t := frame.shapes[i].transform
						if c.group == 0 {
							needs += {.Shape_Box if t[1] == 0 && t[2] == 0 else .Shape}
						}
					}
					ib := b.bounds[i]
					sw_bin(&run, fill, {u32(k), i}, clamp_i32(math.floor(ib.miny), r.y0, r.y1), clamp_i32(math.ceil(ib.maxy), r.y0, r.y1))
				}
			}
		}
	}
	for band := bands; band > 0; band -= 1 {
		b.starts[band] = b.starts[band - 1]
	}
	b.starts[0] = 0
	sw_programs_need(b, needs, int(run.twin.pixels != nil))
	sw_build_groups(b, frame, cmds)
	sw_bands(b, rows, &run, sw_run_band)
}

// The run's groups as the group and marker shaders read them, before its
// bands: each group's grid and its members' words (copied after it, each
// drawn level once a member) in `group_words`, the members' rows (words at
// their copies) and motions in `group_rows` and `group_motions`, and each
// command's group in `group_of` (-1: none).
@(private = "file")
sw_build_groups :: proc(b: ^Software_Backend, frame: Frame, cmds: []Command) {
	clear(&b.group_words)
	clear(&b.group_rows)
	clear(&b.group_motions)
	clear(&b.groups)
	resize(&b.group_of, len(cmds))
	for cmd, k in cmds {
		b.group_of[k] = -1
		c, is_draw := cmd.type.(Cmd_Draw_Shapes)
		if !is_draw || c.group == 0 || c.instances.count == 0 {
			continue
		}
		members := frame.shapes[c.instances.start:][:c.instances.count]
		grid := group_grid(&b.group_grid, &b.group_words, members, frame.shape_words)
		b.group_of[k] = i32(len(b.groups))
		append(&b.groups, Sw_Group{grid, u32(len(b.group_rows))})
		for inst, i in members {
			at := u32(len(b.group_words))
			if inst.marker == .None {
				append(&b.group_words, ..instance_words(inst, frame.shape_words))
			}
			append(&b.group_rows, shader_instance(inst, frame.shape_words, at, {}))
			m: Shader_Motion
			if len(frame.motions) > 0 {
				m = b.motion_rows[int(c.instances.start) + i]
			}
			append(&b.group_motions, m)
		}
	}
}

// A draw reaching rows [y0, y1) (drawing coordinates) of the run's target:
// counted in each band it reaches, or placed there (`fill`).
@(private = "file")
sw_bin :: proc(run: ^Sw_Run, fill: bool, item: Sw_Binned, y0, y1: i32) {
	if y0 >= y1 {
		return
	}
	b := run.b
	for band in int(y0 - run.origin.y) / SW_BAND_ROWS ..= int(y1 - 1 - run.origin.y) / SW_BAND_ROWS {
		if fill {
			b.binned[b.starts[band]] = item
			b.starts[band] += 1
		} else {
			b.starts[band + 1] += 1
		}
	}
}

// One band of a run: its draws, a command's together, with a set of the
// backend's shading memory (lanes_free).
@(private = "file")
sw_run_band :: proc(data: rawptr, y0, y1: int) {
	run := (^Sw_Run)(data)
	b := run.b
	k := y0 / SW_BAND_ROWS
	items := b.binned[b.starts[k]:b.starts[k + 1]]
	top, bottom := i32(y0) + run.origin.y, i32(y1) + run.origin.y
	lanes := sw_lanes_take(b)
	// oksl's Scratch grows from context.allocator.
	context.allocator = runtime.heap_allocator()
	for i := 0; i < len(items); {
		j := i + 1
		for j < len(items) && items[j].cmd == items[i].cmd {
			j += 1
		}
		sw_band_command(run, items[i].cmd, items[i:j], top, bottom, lanes)
		i = j
	}
	sw_lanes_give(b, lanes)
}

// Pixels are addressed in drawing coordinates: (x, y) is target pixel
// (x - ox, y - oy), and [x0, x1) x [y0, y1) is the drawable area.
@(private = "file")
Raster :: struct {
	target:  Sw_Target,
	ox, oy:  i32,
	x0, y0:  i32,
	x1, y1:  i32,
	blend:   Composite_Operation_State,
	twin:    Sw_Twin,
}

@(private = "file")
clamp_i32 :: #force_inline proc "contextless" (v: f32, lo, hi: i32) -> i32 {
	return i32(clamp(v, f32(lo), f32(hi)))
}

// The command's drawable area on the run's target (its scissor applied).
@(private = "file")
sw_raster :: proc(run: ^Sw_Run, cmd: Command) -> Raster {
	r := Raster {
		target  = run.target,
		blend   = cmd.composite_operation,
		ox      = run.origin.x,
		oy      = run.origin.y,
		x0      = run.origin.x,
		y0      = run.origin.y,
		x1      = run.origin.x + i32(run.target.width),
		y1      = run.origin.y + i32(run.target.height),
		twin    = run.twin,
	}
	if sr, ok := cmd.scissor_rect.?; ok {
		r.x0 = clamp_i32(math.floor(sr.x), r.x0, r.x1)
		r.y0 = clamp_i32(math.floor(sr.y), r.y0, r.y1)
		r.x1 = clamp_i32(math.ceil(sr.x + sr.w), r.x0, r.x1)
		r.y1 = clamp_i32(math.ceil(sr.y + sr.h), r.y0, r.y1)
	}
	return r
}

// Command `k`'s draws in one band, rows [top, bottom).
@(private = "file")
sw_band_command :: proc(run: ^Sw_Run, k: u32, items: []Sw_Binned, top, bottom: i32, lanes: ^Sw_Lanes) {
	cmd := run.cmds[k]
	r := sw_raster(run, cmd)
	r.y0 = max(r.y0, top)
	r.y1 = min(r.y1, bottom)
	if r.y0 >= r.y1 {
		return
	}
	frame := run.frame
	#partial switch c in cmd.type {
	case Cmd_Clear_Rect:
		sw_clear_rect(&r, c)
	case Cmd_Draw_Shapes:
		b := run.b
		// The draw's image as `tex`; white without one, as the GPU binds then.
		textures := [2]oksl.Channel_Image{sw_white(), sw_white()}
		if tex, ok := lookup_texture(run.images, cmd.image); ok {
			textures[0] = sw_channel(tex)
		}
		// With a twin, the units' motion variants, whose motion goes over it.
		motion := int(r.twin.pixels != nil)
		paints := slice.reinterpret([]u32, b.paint_rows[:])
		if g := b.group_of[k]; g >= 0 {
			group := b.groups[g]
			grid := group.grid
			unit := Sw_Unit.Marker_Group if frame.shapes[c.instances.start].marker != .None else .Shape_Group
			// Cell units at the pixel: the group's records map them to
			// drawing coordinates.
			to_cells := Transform2D{1 / grid.cell.x, 0, 0, 1 / grid.cell.y, -grid.area.minx / grid.cell.x, -grid.area.miny / grid.cell.y}
			buffers := [4][]u32{paints, b.group_words[:], slice.reinterpret([]u32, b.group_rows[:]), slice.reinterpret([]u32, b.group_motions[:])}
			prog := b.programs[unit][motion]
			uniforms := sw_shape_uniforms(prog, to_cells, {}, {u32(grid.head), c.group - 1, group.first, 0})
			sw_shade_rect(lanes, &r, prog, sw_pixels(&r, grid.area), uniforms[:], buffers[:], textures[:])
			return
		}
		for it in items {
			inst := frame.shapes[it.inst]
			unit := Sw_Unit.Shape_Box if inst.transform[1] == 0 && inst.transform[2] == 0 else .Shape
			uv, data := shader_instance_inputs(inst, 0)
			data.w = it.inst
			buffers := [4][]u32{paints, instance_words(inst, frame.shape_words), nil, slice.reinterpret([]u32, b.motion_rows[:])}
			prog := b.programs[unit][motion]
			uniforms := sw_shape_uniforms(prog, transform_inverse(inst.transform), uv, data)
			sw_shade_rect(lanes, &r, prog, sw_pixels(&r, b.bounds[it.inst]), uniforms[:], buffers[:], textures[:])
		}
	}
}

@(private = "file")
sw_clear_rect :: proc(r: ^Raster, c: Cmd_Clear_Rect) {
	x0 := max(r.x0, i32(c.x))
	y0 := max(r.y0, i32(c.y))
	x1 := min(r.x1, i32(c.x + c.w))
	y1 := min(r.y1, i32(c.y + c.h))
	if x0 >= x1 || y0 >= y1 {
		return
	}
	col := color_to_array(premultiplied(c.color))
	if r.target.format == .RGBA8 {
		packed := transmute(u32)to_unorm8x4(col)
		px := slice.reinterpret([]u32, r.target.pixels)
		w := int(r.target.width)
		tx0, tx1 := int(x0 - r.ox), int(x1 - r.ox)
		for y in y0 ..< y1 {
			row := px[int(y - r.oy) * w + tx0 : int(y - r.oy) * w + tx1]
			for &p in row {
				p = packed
			}
		}
	} else {
		for y in y0 ..< y1 {
			for x in x0 ..< x1 {
				store_texel(r.target, u32(x - r.ox), u32(y - r.oy), col)
			}
		}
	}
	// What a clear leaves is still and farthest, at its alpha.
	if r.twin.pixels != nil {
		for y in y0 ..< y1 {
			row := r.twin.pixels[int(y - r.oy) * int(r.twin.width):]
			for x in x0 ..< x1 {
				row[x - r.ox] = {0, 0, 0, col[3]}
			}
		}
	}
}

// ---- textures ----------------------------------------------------------------

@(private = "file")
Sw_Texture :: struct {
	pixels: []u8,
	width:  u32,
	height: u32,
	format: Pixel_Format,
	flags:  Image_Flags,
}

@(private = "file")
lookup_texture :: proc(images: ^Image_Store, id: Image_Id) -> (Sw_Texture, bool) {
	if !image_id_valid(id) {
		return {}, false
	}
	entry := image_store_get(images, id)
	if entry == nil || entry.image.pixels == nil {
		return {}, false
	}
	// Bound to oksl, and `fetch` reads it unchecked: every texel must be
	// there.
	if entry.info.width == 0 || entry.info.height == 0 || len(entry.image.pixels) < int(entry.info.width) * int(entry.info.height) * int(bytes_per_pixel(entry.info.format)) {
		return {}, false
	}
	return {entry.image.pixels, entry.info.width, entry.info.height, entry.info.format, entry.info.flags}, true
}

// `t` as a shader's texture (a channel oksl reads itself), filtered and
// wrapped by its flags as the GPU backends' samplers are (Nearest, Repeat_X,
// Repeat_Y), its texels as stored (Gray8 and Gray16 are (g, 0, 0, 1)).
@(private = "file")
sw_channel :: proc "contextless" (t: Sw_Texture) -> oksl.Channel_Image {
	@(static, rodata)
	FORMATS := [Pixel_Format]oksl.Channel_Format {
		.RGBA8   = .Rgba8,
		.Gray8   = .Gray8,
		.Gray16  = .Gray16,
		.RGBA16F = .Rgba16f,
	}
	return {
		format = FORMATS[t.format],
		pixels = t.pixels,
		width  = int(t.width),
		height = int(t.height),
		filter = .Nearest if .Nearest in t.flags else .Linear,
		wrap   = {.Repeat if .Repeat_X in t.flags else .Clamp, .Repeat if .Repeat_Y in t.flags else .Clamp},
	}
}

@(private = "file", rodata)
SW_WHITE := [4]u8{255, 255, 255, 255}

// One white texel: the texture of a draw without an image.
@(private = "file")
sw_white :: proc "contextless" () -> oksl.Channel_Image {
	return {format = .Rgba8, pixels = SW_WHITE[:], width = 1, height = 1}
}

// ---- texels -------------------------------------------------------------------------

// Texel as a GPU sampler returns it: Gray8 and Gray16 are (g, 0, 0, 1).
@(private = "file")
fetch :: #force_inline proc "contextless" (t: Sw_Texture, x, y: u32) -> [4]f32 {
	i := int(y * t.width + x)
	_ = t.pixels[(i + 1) * int(bytes_per_pixel(t.format)) - 1]
	return decode_texel(raw_data(t.pixels), i, t.format)
}

// Texel `i` of pixels in `format`, unchecked: the caller knows it is there.
@(private = "file")
decode_texel :: #force_inline proc "contextless" (pixels: [^]u8, i: int, format: Pixel_Format) -> [4]f32 {
	switch format {
	case .RGBA8:
		p := pixels[i * 4:]
		return {f32(p[0]), f32(p[1]), f32(p[2]), f32(p[3])} / 255
	case .Gray8:
		return {f32(pixels[i]) / 255, 0, 0, 1}
	case .Gray16:
		return {f32(u16(pixels[i * 2]) | u16(pixels[i * 2 + 1]) << 8) / 65535, 0, 0, 1}
	case .RGBA16F:
		p := (^[4]u16)(&pixels[i * 8])^
		return {half_to_f32(p[0]), half_to_f32(p[1]), half_to_f32(p[2]), half_to_f32(p[3])}
	}
	return {}
}

// f32(f16) for every finite half, without the library call it is on CPUs
// without F16C (Odin's default target): the bits moved to f32's places,
// scaled by 2^112 for the exponent bias (subnormals included).
@(private = "file")
half_to_f32 :: #force_inline proc "contextless" (h: u16) -> f32 {
	return transmute(f32)(transmute(u32)(transmute(f32)(u32(h & 0x7fff) << 13) * 0h77800000) | u32(h & 0x8000) << 16)
}

@(private = "file")
load_texel :: #force_inline proc "contextless" (t: Sw_Target, x, y: u32) -> [4]f32 {
	return fetch({t.pixels, t.width, t.height, t.format, {}}, x, y)
}

@(private = "file")
to_unorm8 :: #force_inline proc "contextless" (v: f32) -> u8 {
	return u8(clamp(v * 255 + 0.5, 0, 255))
}

// to_unorm8 of each of the four at once.
@(private = "file")
to_unorm8x4 :: #force_inline proc "contextless" (c: [4]f32) -> [4]u8 {
	return simd.to_array(cast(#simd[4]u8)simd.clamp(simd.from_array(c) * 255 + 0.5, 0, 255))
}

// clamp(c, 0, 1) for each of the four at once.
@(private = "file")
saturate4 :: #force_inline proc "contextless" (c: [4]f32) -> [4]f32 {
	return simd.to_array(simd.clamp(simd.from_array(c), 0, 1))
}

@(private = "file")
store_texel :: #force_inline proc "contextless" (t: Sw_Target, x, y: u32, c: [4]f32) {
	i := int(y * t.width + x)
	switch t.format {
	case .RGBA8:
		(^[4]u8)(raw_data(t.pixels[i * 4:][:4]))^ = to_unorm8x4(c)
	case .Gray8:
		t.pixels[i] = to_unorm8(c[0])
	case .Gray16:
		v := u16(clamp(c[0], 0, 1) * 65535 + 0.5)
		t.pixels[i * 2], t.pixels[i * 2 + 1] = u8(v), u8(v >> 8)
	case .RGBA16F:
		(^[4]f16)(&t.pixels[i * 8])^ = {f16(c[0]), f16(c[1]), f16(c[2]), f16(c[3])}
	}
}

// ---- blending ------------------------------------------------------------------------

@(private = "file")
factor_rgb :: #force_inline proc "contextless" (f: Blend_Factor, src, dst: [4]f32) -> [3]f32 {
	switch f {
	case .Zero:
		return {0, 0, 0}
	case .One:
		return {1, 1, 1}
	case .Src_Color:
		return src.rgb
	case .One_Minus_Src_Color:
		return 1 - src.rgb
	case .Dst_Color:
		return dst.rgb
	case .One_Minus_Dst_Color:
		return 1 - dst.rgb
	case .Src_Alpha:
		return src.a
	case .One_Minus_Src_Alpha:
		return 1 - src.a
	case .Dst_Alpha:
		return dst.a
	case .One_Minus_Dst_Alpha:
		return 1 - dst.a
	case .Src_Alpha_Saturate:
		return min(src.a, 1 - dst.a)
	}
	return {}
}

@(private = "file")
factor_alpha :: #force_inline proc "contextless" (f: Blend_Factor, sa, da: f32) -> f32 {
	switch f {
	case .Zero:
		return 0
	case .One, .Src_Alpha_Saturate:
		return 1
	case .Src_Color, .Src_Alpha:
		return sa
	case .One_Minus_Src_Color, .One_Minus_Src_Alpha:
		return 1 - sa
	case .Dst_Color, .Dst_Alpha:
		return da
	case .One_Minus_Dst_Color, .One_Minus_Dst_Alpha:
		return 1 - da
	}
	return 0
}

// Blends `src` onto the target's texel as a GPU's blend unit does: a unorm
// target clamps the source to [0, 1] first and the result as it stores it
// (store_texel); an RGBA16F target clamps neither.
@(private = "file")
blend_texel :: #force_inline proc "contextless" (t: Sw_Target, x, y: u32, s: Composite_Operation_State, src: [4]f32) {
	src := src
	if t.format != .RGBA16F {
		src = saturate4(src)
	}
	if s.src_rgb == .One && s.src_alpha == .One {
		if (s.dst_rgb == .Zero && s.dst_alpha == .Zero) || (s.dst_rgb == .One_Minus_Src_Alpha && s.dst_alpha == .One_Minus_Src_Alpha && src[3] >= 1) {
			store_texel(t, x, y, src)
			return
		}
	}
	dst := load_texel(t, x, y)
	sf := factor_rgb(s.src_rgb, src, dst)
	df := factor_rgb(s.dst_rgb, src, dst)
	rgb := src.rgb * sf + dst.rgb * df
	a := src.a * factor_alpha(s.src_alpha, src.a, dst.a) + dst.a * factor_alpha(s.dst_alpha, src.a, dst.a)
	store_texel(t, x, y, {rgb.r, rgb.g, rgb.b, a})
}

// ---- image filters -------------------------------------------------------------------

// Runs one image filter with the filter unit (shaders/filter.frag), in the
// passes `filter_plan` lays out for every backend: each a quad over its
// output in row bands (sw_quad_band), a two-pass filter's second reading
// the whole first from the intermediate.
@(private = "file")
sw_filter_image :: proc(b: ^Software_Backend, images: ^Image_Store, cmd: Command, target: Image_Id, filter: Image_Filter) {
	src, src_ok := lookup_texture(images, cmd.image)
	dst_entry := image_store_get(images, target)
	if !src_ok || dst_entry == nil || dst_entry.image.pixels == nil {
		return
	}
	backdrop := filter_backdrop(filter)
	back, back_ok := lookup_texture(images, backdrop)
	back_info: Maybe(Image_Info)
	if back_ok {
		back_info = Image_Info{back.flags, back.width, back.height, back.format}
	}
	src_info := Image_Info{src.flags, src.width, src.height, src.format}
	plan, ok := filter_plan(filter, src_info, dst_entry.info, back_info, target == cmd.image || target == backdrop)
	if !ok {
		return
	}
	dst := Sw_Target{dst_entry.image.pixels, dst_entry.info.width, dst_entry.info.height, dst_entry.info.format}
	mid: Sw_Texture
	if plan.count == 2 || plan.copy {
		info := src_info if plan.count == 2 else dst_entry.info
		mid = {sw_blur_tmp(b, int(info.width * info.height * bytes_per_pixel(info.format))), info.width, info.height, info.format, info.flags}
	}
	sw_programs_need(b, {.Filter}, 0)
	for pass in plan.passes[:plan.count] {
		from := mid if pass.from_mid else src
		to := Sw_Target{mid.pixels, mid.width, mid.height, mid.format} if pass.to_mid else dst
		job := Sw_Quad_Pass {
			b       = b,
			unit    = b.programs[.Filter][0],
			raster  = {target = to, x1 = i32(to.width), y1 = i32(to.height), blend = composite_state_from_op(.Copy)},
			quad_tc = {1 / f32(to.width), 1 / f32(to.height), 0, 0},
			paint   = pass.paint,
			images  = {sw_channel(from), sw_channel(back) if back_ok else {}},
		}
		sw_bands(b, int(to.height), &job, sw_quad_band)
	}
	if plan.copy {
		copy(dst.pixels, mid.pixels)
	}
}

// The intermediate of a filter's passes, `n` bytes.
@(private = "file")
sw_blur_tmp :: proc(b: ^Software_Backend, n: int) -> []u8 {
	if len(b.blur_tmp) < n {
		delete(b.blur_tmp, b.allocator)
		b.blur_tmp = make([]u8, n, b.allocator)
	}
	return b.blur_tmp[:n]
}

// A quad unit drawn over the raster's area as the GPU draws a quad over it
// (its pixels are drawing coordinates): its paint `paint`, `quad_tc`
// the map from a pixel's centre to ftcoord, `images` its `tex` and
// `glyphtex`. A raster without a target takes the unit's output as motion
// over its twin.
@(private = "file")
Sw_Quad_Pass :: struct {
	b:       ^Software_Backend,
	unit:    Sw_Program_Unit,
	raster:  Raster,
	quad_tc: [4]f32,
	paint:   [14][4]f32,
	images:  [2]oksl.Channel_Image,
}

// Rows [y0, y1) of a quad pass, with a set of the backend's shading memory.
@(private = "file")
sw_quad_band :: proc(data: rawptr, y0, y1: int) {
	job := (^Sw_Quad_Pass)(data)
	r := job.raster
	r.y0, r.y1 = max(r.y0, i32(y0)), min(r.y1, i32(y1))
	if r.y0 >= r.y1 || r.x0 >= r.x1 {
		return
	}
	lanes := sw_lanes_take(job.b)
	// oksl's Scratch grows from context.allocator.
	context.allocator = runtime.heap_allocator()
	uniforms: [SW_UNIFORM_BYTES]u8
	if job.unit.quad_tc_at >= 0 {
		(^[4]f32)(&uniforms[job.unit.quad_tc_at])^ = job.quad_tc
	}
	if job.unit.paint_at >= 0 {
		(^[14][4]f32)(&uniforms[job.unit.paint_at])^ = job.paint
	}
	sw_shade_rect(lanes, &r, job.unit, {r.x0, r.y0, r.x1, r.y1}, uniforms[:job.unit.module.block_size], nil, job.images[:])
	sw_lanes_give(job.b, lanes)
}

// ---- row bands -----------------------------------------------------------------------

@(private = "file")
SW_BAND_ROWS :: 16

@(private = "file")
Sw_Bands :: struct {
	data: rawptr,
	band: proc(data: rawptr, y0, y1: int),
	rows: int,
}

// Runs `band` over `rows` rows in bands of SW_BAND_ROWS, a range of bands
// at a time on the caller's pool (`b.pool`; nil: all on this thread). Bands
// write disjoint rows; a band never starts another sweep.
@(private = "file")
sw_bands :: proc(b: ^Software_Backend, rows: int, data: rawptr, band: proc(data: rawptr, y0, y1: int)) {
	job := Sw_Bands{data, band, rows}
	count := (rows + SW_BAND_ROWS - 1) / SW_BAND_ROWS
	if b.pool == nil {
		sw_band_range(&job, 0, count)
		return
	}
	b.pool.run(b.pool, count, sw_band_range, &job)
}

@(private = "file")
sw_band_range :: proc(data: rawptr, first, end: int) {
	job := (^Sw_Bands)(data)
	for k in first ..< end {
		y := k * SW_BAND_ROWS
		job.band(job.data, y, min(y + SW_BAND_ROWS, job.rows))
	}
}

// ---- custom programs ------------------------------------------------------------------

@(private = "file")
Sw_Program :: struct {
	cpu:  Program_Cpu_Proc,
	user: rawptr,
}

@(private = "file")
sw_create_program :: proc(data: rawptr, desc: Program_Desc) -> (Backend_Program, Error) {
	b := (^Software_Backend)(data)
	if desc.cpu == nil {
		return {}, .Unsupported_Operation
	}
	p := new(Sw_Program, b.allocator)
	p^ = {desc.cpu, desc.cpu_user}
	return {user = p}, nil
}

@(private = "file")
sw_delete_program :: proc(data: rawptr, program: Backend_Program) {
	b := (^Software_Backend)(data)
	free(program.user, b.allocator)
}

@(private = "file")
sw_run_program :: proc(images: ^Image_Store, frame: Frame, cmd: Program_Run) {
	p := (^Sw_Program)(cmd.program.user)
	entry := image_store_get(images, cmd.target)
	if p == nil || entry == nil || entry.image.pixels == nil || (entry.info.format != .RGBA8 && entry.info.format != .RGBA16F) {
		return
	}
	sampler: Program_Sampler
	for id, i in cmd.channels {
		if t, ok := lookup_texture(images, id); ok {
			sampler.images[i] = sw_channel(t)
			sampler.sizes[i] = {i32(t.width), i32(t.height), 1}
		}
	}
	w, h := int(entry.info.width), int(entry.info.height)
	format := entry.info.format
	if format == .RGBA16F {
		out := slice.reinterpret([][4]f16, entry.image.pixels[:w * h * 8])
		alpha: f16 = 1 if .Opaque in cmd.flags else 0
		for &px in out {
			px = {0, 0, 0, alpha}
		}
		p.cpu(p.user, frame_bytes(frame, cmd.uniforms), w, h, entry.image.pixels[:w * h * 8], w * 8, format, sampler)
		if .Opaque in cmd.flags {
			for &px in out {
				px[3] = 1
			}
		}
		return
	}
	out := entry.image.pixels[:w * h * 4]
	clear_to: u8 = 255 if .Opaque in cmd.flags else 0
	for i := 0; i < len(out); i += 4 {
		out[i], out[i + 1], out[i + 2], out[i + 3] = 0, 0, 0, clear_to
	}
	p.cpu(p.user, frame_bytes(frame, cmd.uniforms), w, h, out, w * 4, format, sampler)
	if .Opaque in cmd.flags {
		for i := 3; i < len(out); i += 4 {
			out[i] = 255
		}
	}
}

// ---- the shape shaders on oksl's CPU program ------------------------------------

// A band's working memory for the shaders: oksl's registers, and a call's
// quads and outputs (at most SW_SHADE_QUADS), reused from draw to draw and
// frame to frame (Software_Backend.lanes_free).
@(private = "file")
Sw_Lanes :: struct {
	scratch:  oksl.Scratch,
	origins:  [dynamic][2]i32,
	helpers:  [dynamic]oksl.Quad_Lanes,
	shaded:   [dynamic]oksl.Quad_Lanes,
	color:    [dynamic][4]f32,
	motion:   [dynamic][4]f32,
}

// A free set of the backend's shading memory, or a new one on the heap.
@(private = "file")
sw_lanes_take :: proc(b: ^Software_Backend) -> ^Sw_Lanes {
	sync.lock(&b.lanes_lock)
	free_set, ok := pop_safe(&b.lanes_free)
	sync.unlock(&b.lanes_lock)
	if ok {
		return free_set
	}
	heap := runtime.heap_allocator()
	L := new(Sw_Lanes, heap)
	L^ = {
		origins = make([dynamic][2]i32, heap),
		helpers = make([dynamic]oksl.Quad_Lanes, heap),
		shaded = make([dynamic]oksl.Quad_Lanes, heap),
		color = make([dynamic][4]f32, heap),
		motion = make([dynamic][4]f32, heap),
	}
	return L
}

// Puts a set back on `lanes_free`.
@(private = "file")
sw_lanes_give :: proc(b: ^Software_Backend, L: ^Sw_Lanes) {
	sync.lock(&b.lanes_lock)
	append(&b.lanes_free, L)
	sync.unlock(&b.lanes_lock)
}

@(private = "file")
sw_lanes_destroy :: proc(L: ^Sw_Lanes) {
	context.allocator = runtime.heap_allocator()
	oksl.scratch_destroy(&L.scratch)
	delete(L.origins)
	delete(L.helpers)
	delete(L.shaded)
	delete(L.color)
	delete(L.motion)
	free(L)
}

// The pixels of `bounds` (drawing coordinates) in the raster: x0, y0, x1, y1.
@(private = "file")
sw_pixels :: proc "contextless" (r: ^Raster, bounds: Bounds) -> [4]i32 {
	return {clamp_i32(math.floor(bounds.minx), r.x0, r.x1), clamp_i32(math.floor(bounds.miny), r.y0, r.y1), clamp_i32(math.ceil(bounds.maxx), r.x0, r.x1), clamp_i32(math.ceil(bounds.maxy), r.y0, r.y1)}
}

// Quads one run_fragment call shades: 16 of oksl's batches, so a call's
// outputs (two colours a pixel, 32 KB) stay small and in cache however wide
// the pixels are.
@(private = "file")
SW_SHADE_QUADS :: 16 * oksl.LANES / 4

// A unit's uniform block: the shape units' uv, data, rc_linear and
// rc_offset, or the quad units' quad_tc and paint.
@(private = "file")
SW_UNIFORM_BYTES :: 256

// A shape unit's uniforms: uv, data and `to_rc` (the map from fpos, a
// pixel's centre, to rc).
@(private = "file")
sw_shape_uniforms :: proc "contextless" (prog: Sw_Program_Unit, to_rc: Transform2D, uv: [4]f32, data: [4]u32) -> (uniforms: [SW_UNIFORM_BYTES]u8) {
	if prog.uv_at >= 0 {
		(^[4]f32)(&uniforms[prog.uv_at])^ = uv
	}
	if prog.data_at >= 0 {
		(^[4]u32)(&uniforms[prog.data_at])^ = data
	}
	if prog.rc_linear_at >= 0 {
		(^[4]f32)(&uniforms[prog.rc_linear_at])^ = {to_rc[0], to_rc[1], to_rc[2], to_rc[3]}
	}
	if prog.rc_offset_at >= 0 {
		(^[2]f32)(&uniforms[prog.rc_offset_at])^ = {to_rc[4], to_rc[5]}
	}
	return
}

// Shades the raster's pixels `px` (x0, y0, x1, y1) in 2x2 quads with a
// unit, as the GPU rasterizes a quad over them, from its uniform block,
// storage buffers and textures (bound by channel). Then each pixel it
// shades blends in order (and with a twin, its motion over the twin's
// pixel, premultiplied source-over, whatever the blend); a raster without
// a target takes the unit's one output as that motion. The quads go
// SW_SHADE_QUADS at a time, row by row.
@(private = "file")
sw_shade_rect :: proc(L: ^Sw_Lanes, r: ^Raster, prog: Sw_Program_Unit, px: [4]i32, uniforms: []u8, buffers: [][]u32, textures: []oksl.Channel_Image) {
	x0, y0, x1, y1 := px[0], px[1], px[2], px[3]
	if x0 >= x1 || y0 >= y1 {
		return
	}
	m := prog.module
	qx0, qy0 := x0 &~ 1, y0 &~ 1
	nqx := int(x1 - qx0 + 1) / 2
	quads := nqx * (int(y1 - qy0 + 1) / 2)
	colour := r.target.pixels != nil
	moves := len(m.stage_outputs) > 1 || !colour
	most := min(quads, SW_SHADE_QUADS)
	resize(&L.origins, most)
	resize(&L.helpers, most)
	resize(&L.shaded, most)
	resize(&L.color, most * 4)
	if moves {
		resize(&L.motion, most * 4)
	}
	for first := 0; first < quads; first += SW_SHADE_QUADS {
		count := min(quads - first, SW_SHADE_QUADS)
		total := count * 4
		// The quads, the lanes off the pixels helpers.
		for q in 0 ..< count {
			k := first + q
			o := [2]i32{qx0 + i32(k % nqx) * 2, qy0 + i32(k / nqx) * 2}
			L.origins[q] = o
			h: oksl.Quad_Lanes
			if o.x + 1 >= x1 {h += {1, 3}}
			if o.x < x0 {h += {0, 2}}
			if o.y + 1 >= y1 {h += {2, 3}}
			if o.y < y0 {h += {0, 1}}
			L.helpers[q] = h
		}
		targets := [2][][4]f32{L.color[:total], L.motion[:total] if moves else nil}
		outputs := targets[:2 if moves else 1]
		if !colour {
			outputs = targets[1:]
		}
		shaded := L.shaded[:count]
		in_ := oksl.Fragment_Quads{count = count, origin = L.origins[:count], helpers = L.helpers[:count]}
		oksl.run_fragment(&m.program, uniforms, in_, outputs, shaded, &L.scratch, {buffers = buffers, channel_images = textures})
		for lanes, q in shaded {
			o := L.origins[q]
			for l in lanes {
				tx, ty := u32(o.x + i32(l & 1) - r.ox), u32(o.y + i32(l >> 1) - r.oy)
				if colour {
					blend_texel(r.target, tx, ty, r.blend, L.color[q * 4 + l])
				}
				if moves {
					mo := L.motion[q * 4 + l]
					d := &r.twin.pixels[ty * r.twin.width + tx]
					d^ = mo + d^ * (1 - mo[3])
				}
			}
		}
	}
}

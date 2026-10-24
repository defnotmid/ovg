// SDL_GPU backend for ovg: Vulkan on Linux, Metal on macOS, Vulkan (or
// D3D12 with DXIL blobs) on Windows, through SDL3's GPU API.
//
// `init` creates a headless device, or borrows the host's (e.g. the one its
// window renders with). Every flush records one command buffer; up to
// `frames_in_flight` of them stay running when it returns.
package ovg_sdlgpu

import "core:mem"
import sdl "vendor:sdl3"

import vg ".."

VERT_SPV :: #load("../shaders/ovg.vert.spv")
FRAG_SPV :: #load("../shaders/ovg.frag.spv")
VERT_MSL :: #load("../shaders/ovg.vert.msl")
FRAG_MSL :: #load("../shaders/ovg.frag.msl")
SHAPE_VERT_SPV :: #load("../shaders/ovg.shape_vert.spv")
SHAPE_FRAG_SPV :: #load("../shaders/ovg.shape_frag.spv")
SHAPE_VERT_MSL :: #load("../shaders/ovg.shape_vert.msl")
SHAPE_FRAG_MSL :: #load("../shaders/ovg.shape_frag.msl")
SHAPE_BOX_FRAG_SPV :: #load("../shaders/ovg.shape_box_frag.spv")
SHAPE_BOX_FRAG_MSL :: #load("../shaders/ovg.shape_box_frag.msl")
SHAPE_GROUP_FRAG_SPV :: #load("../shaders/ovg.shape_group_frag.spv")
SHAPE_GROUP_FRAG_MSL :: #load("../shaders/ovg.shape_group_frag.msl")

MAX_FRAMES_IN_FLIGHT :: 4

// A GPU texture backing one canvas image (`Backend_Image.user`).
Image :: struct {
	texture: ^sdl.GPUTexture,
	format:  sdl.GPUTextureFormat,
	width:   u32,
	height:  u32,
	flags:   vg.Image_Flags,
}

// A backend-owned texture kept across frames, with the frame it was last
// used in.
Cached_Texture :: struct {
	image:     Image,
	last_used: u64,
}

// A caller-owned texture to render the screen into, passed to `vg.flush`
// with `output`. With `command_buffer` set the frame is recorded into it
// and the caller submits (needed for swapchain textures, which belong to
// the command buffer that acquired them); otherwise the backend submits
// and waits.
Output :: struct {
	texture:        ^sdl.GPUTexture,
	format:         sdl.GPUTextureFormat,
	width:          u32,
	height:         u32,
	command_buffer: ^sdl.GPUCommandBuffer,
}

output :: proc(o: ^Output) -> vg.Render_Output {
	return vg.Render_Output(uintptr(o))
}

SDL_Backend :: struct {
	allocator:        mem.Allocator,
	device:           ^sdl.GPUDevice,
	owns_device:      bool,
	vert:             ^sdl.GPUShader,
	frag:             ^sdl.GPUShader,
	// Shape instances (shapes.odin): quads pulled from `instance_stream`,
	// coverage from the shapes in `shapes`.
	shape_vert:       ^sdl.GPUShader,
	shape_frag:       ^sdl.GPUShader,
	// For instances whose pixel footprint is a box (no rotation or skew).
	shape_box_frag:   ^sdl.GPUShader,
	// For groups (Cmd_Draw_Shapes.group): one record, its pixels compositing
	// the instances.
	shape_group_frag: ^sdl.GPUShader,
	shapes:           Shape_Store,
	screen_width:     u32,
	screen_height:    u32,
	// Default screen target, rendered into when `flush` gets no output.
	offscreen:        ^Image,
	// The texture the last frame rendered its screen into (for screenshot).
	last_screen:      Image,
	// The frame's vertices and paints, uploaded once per frame.
	vertex_stream:    Stream,
	paint_stream:     Stream,
	instance_stream:  Stream,
	// The intermediates of image filters (`scratch_image`);
	// unused ones are freed after a while.
	scratch:          [dynamic]Cached_Texture,
	// Counts `render` calls.
	frame:            u64,
	// Frames `render` may leave running on the GPU when it returns (0, the
	// default: it waits for each frame; at most MAX_FRAMES_IN_FLIGHT - 1).
	// Reading a frame back waits for its own copy, which the queue orders
	// after the frame.
	frames_in_flight: int,
	fences:           [MAX_FRAMES_IN_FLIGHT]^sdl.GPUFence,
	fence_head:       int,
	fence_count:      int,
	pipelines:        map[Pipeline_Key]^sdl.GPUGraphicsPipeline,
	// By Repeat_X | Repeat_Y << 1 | Nearest << 2.
	samplers:         [8]^sdl.GPUSampler,
	white:            ^Image,
	// Bound to custom program channels that have no image.
	transparent:      ^Image,
	// SPIR-V or MSL, whichever the device takes.
	shader_format:    sdl.GPUShaderFormat,
	// The planned frame (render.odin): the quads and paints the backend adds
	// after the frame's, and the rows that draw them all.
	verts:            [dynamic]vg.Vertex,
	paints:           [dynamic]Paint,
	rows:             [dynamic]Row,
	// Each frame shape instance's shape, as a word offset in `shapes`.
	shape_offsets:    [dynamic]u32,
	// The frame's group records, after its instances, and their grids
	// (render.odin, plan_group).
	groups:           [dynamic]Gpu_Shape_Instance,
	group_words:      [dynamic]u32,
	// What the last `render` recorded.
	stats:            Frame_Stats,
}

// Counts of the GPU work one frame recorded.
Frame_Stats :: struct {
	draws:          int,
	pipeline_binds: int,
	render_passes:  int,
	// Shape instances drawn, and words of shapes uploaded to the store.
	shape_instances: int,
	shape_upload_words: int,
}

// Prepares the backend on `device`, or on a new headless device when nil
// (SDL's video subsystem is initialized; without a display the
// `offscreen` video driver is used). On failure what was made is released
// (an owned device too): `destroy` is not needed.
init :: proc(b: ^SDL_Backend, device: ^sdl.GPUDevice = nil, allocator := context.allocator) -> (err: vg.Error) {
	b^ = {
		allocator = allocator,
		device    = device,
		scratch   = make([dynamic]Cached_Texture, allocator),
		pipelines = make(map[Pipeline_Key]^sdl.GPUGraphicsPipeline, allocator),
		verts     = make([dynamic]vg.Vertex, allocator),
		paints    = make([dynamic]Paint, allocator),
		rows      = make([dynamic]Row, allocator),
		shape_offsets = make([dynamic]u32, allocator),
		groups = make([dynamic]Gpu_Shape_Instance, allocator),
		group_words = make([dynamic]u32, allocator),
	}
	defer if err != nil {
		destroy(b)
	}
	if b.device == nil {
		if .VIDEO not_in sdl.WasInit({.VIDEO}) && !sdl.Init({.VIDEO}) {
			sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "offscreen")
			if !sdl.Init({.VIDEO}) {
				return .General
			}
		}
		b.device = sdl.CreateGPUDevice({.SPIRV, .MSL}, false, nil)
		if b.device == nil {
			return .General
		}
		b.owns_device = true
	}

	// slangc names the SPIR-V entry points "main" and keeps the function
	// names for Metal.
	formats := sdl.GetGPUShaderFormats(b.device)
	spirv := .SPIRV in formats
	if !spirv && .MSL not_in formats {
		return .Unsupported_Operation
	}
	b.shader_format = {.SPIRV} if spirv else {.MSL}
	shader :: proc(b: ^SDL_Backend, spv, msl: []u8, entry: cstring, stage: sdl.GPUShaderStage, samplers, storage, uniforms: u32) -> ^sdl.GPUShader {
		spirv := b.shader_format == {.SPIRV}
		code := spv if spirv else msl
		return sdl.CreateGPUShader(b.device, {
			code_size = len(code),
			code = raw_data(code),
			entrypoint = "main" if spirv else entry,
			format = b.shader_format,
			stage = stage,
			num_samplers = samplers,
			num_storage_buffers = storage,
			num_uniform_buffers = uniforms,
		})
	}
	b.vert = shader(b, VERT_SPV, VERT_MSL, "vs_main", .VERTEX, 0, 0, 1)
	b.frag = shader(b, FRAG_SPV, FRAG_MSL, "fs_main", .FRAGMENT, 2, 1, 0)
	b.shape_vert = shader(b, SHAPE_VERT_SPV, SHAPE_VERT_MSL, "vs_shape", .VERTEX, 0, 1, 2)
	b.shape_frag = shader(b, SHAPE_FRAG_SPV, SHAPE_FRAG_MSL, "fs_shape", .FRAGMENT, 2, 2, 0)
	b.shape_box_frag = shader(b, SHAPE_BOX_FRAG_SPV, SHAPE_BOX_FRAG_MSL, "fs_shape_box", .FRAGMENT, 2, 2, 0)
	b.shape_group_frag = shader(b, SHAPE_GROUP_FRAG_SPV, SHAPE_GROUP_FRAG_MSL, "fs_shape_group", .FRAGMENT, 2, 3, 0)
	if b.vert == nil || b.frag == nil || b.shape_vert == nil || b.shape_frag == nil || b.shape_box_frag == nil || b.shape_group_frag == nil {
		return .Shader_Compile
	}
	store_init(b)

	for &s, i in b.samplers {
		filter: sdl.GPUFilter = .NEAREST if i & 4 != 0 else .LINEAR
		s = sdl.CreateGPUSampler(
			b.device,
			{
				min_filter = filter,
				mag_filter = filter,
				mipmap_mode = .NEAREST,
				address_mode_u = .REPEAT if i & 1 != 0 else .CLAMP_TO_EDGE,
				address_mode_v = .REPEAT if i & 2 != 0 else .CLAMP_TO_EDGE,
				address_mode_w = .CLAMP_TO_EDGE,
			},
		)
		if s == nil {
			return .General
		}
	}

	b.white = create_texture(b, 1, 1, .R8G8B8A8_UNORM, {.SAMPLER}) or_return
	pixel := [4]u8{255, 255, 255, 255}
	upload(b, b.white, pixel[:], 0, 0, 1, 1) or_return
	b.transparent = create_texture(b, 1, 1, .R8G8B8A8_UNORM, {.SAMPLER}) or_return
	zero := [4]u8{}
	upload(b, b.transparent, zero[:], 0, 0, 1, 1) or_return
	return nil
}

destroy :: proc(b: ^SDL_Backend) {
	if b.device == nil {
		// init failed before having a device: only the tables to free.
		delete(b.pipelines)
		delete(b.scratch)
		delete(b.verts)
		delete(b.paints)
		delete(b.rows)
		delete(b.shape_offsets)
		delete(b.groups)
		delete(b.group_words)
		b^ = {}
		return
	}
	_ = sdl.WaitForGPUIdle(b.device)
	for i in 0 ..< b.fence_count {
		sdl.ReleaseGPUFence(b.device, b.fences[(b.fence_head + i) % MAX_FRAMES_IN_FLIGHT])
	}
	for _, p in b.pipelines {
		sdl.ReleaseGPUGraphicsPipeline(b.device, p)
	}
	delete(b.pipelines)
	for t in b.scratch {
		sdl.ReleaseGPUTexture(b.device, t.image.texture)
	}
	delete(b.scratch)
	for s in b.samplers {
		if s != nil {
			sdl.ReleaseGPUSampler(b.device, s)
		}
	}
	release_image(b, b.white)
	release_image(b, b.transparent)
	release_image(b, b.offscreen)
	stream_release(b, &b.vertex_stream)
	stream_release(b, &b.paint_stream)
	stream_release(b, &b.instance_stream)
	// Always: the map allocates on its first shape, but a frame of only its
	// own words still fills `pending` and makes the buffers.
	store_destroy(b)
	for s in ([]^sdl.GPUShader{b.shape_vert, b.shape_frag, b.shape_box_frag, b.shape_group_frag}) {
		if s != nil {
			sdl.ReleaseGPUShader(b.device, s)
		}
	}
	if b.vert != nil {
		sdl.ReleaseGPUShader(b.device, b.vert)
	}
	if b.frag != nil {
		sdl.ReleaseGPUShader(b.device, b.frag)
	}
	delete(b.verts)
	delete(b.paints)
	delete(b.rows)
	delete(b.shape_offsets)
	delete(b.groups)
	delete(b.group_words)

	if b.owns_device {
		sdl.DestroyGPUDevice(b.device)
	}
	b^ = {}
}

backend :: proc(b: ^SDL_Backend) -> vg.Backend {
	return {
		data = b,
		set_size = sdl_set_size,
		render = sdl_render,
		alloc_image = sdl_alloc_image,
		update_image = sdl_update_image,
		delete_image = sdl_delete_image,
		screenshot = sdl_screenshot,
		read_image = sdl_read_image,
		create_program = sdl_create_program,
		delete_program = sdl_delete_program,
	}
}

// A custom program (`Backend_Program.user`): its shaders and one pipeline
// per (target format, opaque).
Program :: struct {
	vert:         ^sdl.GPUShader,
	frag:         ^sdl.GPUShader,
	uniform_size: int,
	num_samplers: int,
	pipelines:    [dynamic]Program_Pipeline,
}

Program_Pipeline :: struct {
	format:   sdl.GPUTextureFormat,
	opaque:   bool,
	pipeline: ^sdl.GPUGraphicsPipeline,
}

@(private = "file")
sdl_create_program :: proc(data: rawptr, desc: vg.Program_Desc) -> (vg.Backend_Program, vg.Error) {
	b := (^SDL_Backend)(data)
	vert_code, frag_code: []u8
	vert_entry, frag_entry: cstring
	if .SPIRV in b.shader_format {
		vert_code, frag_code, vert_entry, frag_entry = desc.vert_spirv, desc.frag_spirv, desc.vert_spirv_entry, desc.frag_spirv_entry
	} else {
		vert_code, frag_code, vert_entry, frag_entry = desc.vert_msl, desc.frag_msl, desc.vert_msl_entry, desc.frag_msl_entry
	}
	if len(vert_code) == 0 || len(frag_code) == 0 {
		return {}, .Unsupported_Operation
	}
	vert := sdl.CreateGPUShader(
		b.device,
		{
			code_size = len(vert_code),
			code = raw_data(vert_code),
			entrypoint = vert_entry if vert_entry != nil else "main",
			format = b.shader_format,
			stage = .VERTEX,
			num_uniform_buffers = 1,
		},
	)
	frag := sdl.CreateGPUShader(
		b.device,
		{
			code_size = len(frag_code),
			code = raw_data(frag_code),
			entrypoint = frag_entry if frag_entry != nil else "main",
			format = b.shader_format,
			stage = .FRAGMENT,
			num_samplers = u32(desc.num_samplers),
			num_uniform_buffers = 1 if desc.uniform_size > 0 else 0,
		},
	)
	if vert == nil || frag == nil {
		if vert != nil {sdl.ReleaseGPUShader(b.device, vert)}
		if frag != nil {sdl.ReleaseGPUShader(b.device, frag)}
		return {}, .Shader_Compile
	}
	p := new(Program, b.allocator)
	p^ = {
		vert         = vert,
		frag         = frag,
		uniform_size = desc.uniform_size,
		num_samplers = desc.num_samplers,
		pipelines    = make([dynamic]Program_Pipeline, b.allocator),
	}
	return {user = p}, nil
}

@(private = "file")
sdl_delete_program :: proc(data: rawptr, program: vg.Backend_Program) {
	b := (^SDL_Backend)(data)
	p := (^Program)(program.user)
	if p == nil {
		return
	}
	for pp in p.pipelines {
		sdl.ReleaseGPUGraphicsPipeline(b.device, pp.pipeline)
	}
	delete(p.pipelines)
	sdl.ReleaseGPUShader(b.device, p.vert)
	sdl.ReleaseGPUShader(b.device, p.frag)
	free(p, b.allocator)
}

// The texture behind a canvas image, for compositing it in host UI code.
// nil if the id is unknown.
image_texture :: proc(c: ^vg.Canvas, id: vg.Image_Id) -> ^sdl.GPUTexture {
	return image_store_texture(&c.images, id)
}

// The texture behind an image of a store: a canvas's or a player's
// (`vg.Player.images`), e.g. the one a `vg.run_external` callback gets.
image_store_texture :: proc(images: ^vg.Image_Store, id: vg.Image_Id) -> ^sdl.GPUTexture {
	entry := vg.image_store_get(images, id)
	if entry == nil || entry.image.user == nil {
		return nil
	}
	return (^Image)(entry.image.user).texture
}

// The default screen texture of the last frame flushed without an output.
offscreen_texture :: proc(b: ^SDL_Backend) -> ^sdl.GPUTexture {
	return b.offscreen.texture if b.offscreen != nil else nil
}

@(private = "file")
sdl_set_size :: proc(data: rawptr, width, height: u32, dpi: f32) {
	b := (^SDL_Backend)(data)
	b.screen_width, b.screen_height = width, height
}

// ---- images ---------------------------------------------------------------------

@(private)
create_texture :: proc(b: ^SDL_Backend, w, h: u32, format: sdl.GPUTextureFormat, usage: sdl.GPUTextureUsageFlags) -> (^Image, vg.Error) {
	tex := sdl.CreateGPUTexture(
		b.device,
		{
			type = .D2,
			format = format,
			usage = usage,
			width = max(w, 1),
			height = max(h, 1),
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = ._1,
		},
	)
	if tex == nil {
		return nil, .General
	}
	img := new(Image, b.allocator)
	img^ = {texture = tex, format = format, width = w, height = h}
	return img, nil
}

@(private)
release_image :: proc(b: ^SDL_Backend, img: ^Image) {
	if img == nil {
		return
	}
	// SDL defers the release until submitted work no longer uses it.
	sdl.ReleaseGPUTexture(b.device, img.texture)
	free(img, b.allocator)
}

// The texture format storing `f`. RGB8 is stored as RGBA8: three-byte
// formats are not renderable.
texture_format :: proc "contextless" (f: vg.Pixel_Format) -> sdl.GPUTextureFormat {
	switch f {
	case .Gray8:
		return .R8_UNORM
	case .Gray16:
		return .R16_UNORM
	case .RGBA16F:
		return .R16G16B16A16_FLOAT
	case .RGB8, .RGBA8:
	}
	return .R8G8B8A8_UNORM
}

@(private = "file")
sdl_alloc_image :: proc(data: rawptr, info: vg.Image_Info) -> (vg.Backend_Image, vg.Error) {
	b := (^SDL_Backend)(data)
	format := texture_format(info.format)
	usage: sdl.GPUTextureUsageFlags = {.SAMPLER}
	if sdl.GPUTextureSupportsFormat(b.device, format, .D2, {.SAMPLER, .COLOR_TARGET}) {
		usage += {.COLOR_TARGET}
	}
	img, err := create_texture(b, info.width, info.height, format, usage)
	if err != nil {
		return {}, err
	}
	img.flags = info.flags
	// New textures are undefined (garbage on Metal), and partly updated
	// images such as the glyph atlas sample their untouched texels.
	if .COLOR_TARGET in usage {
		cmd := sdl.AcquireGPUCommandBuffer(b.device)
		if cmd == nil {
			release_image(b, img)
			return {}, .General
		}
		target := sdl.GPUColorTargetInfo{texture = img.texture, load_op = .CLEAR, store_op = .STORE}
		pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
		if pass == nil {
			_ = sdl.CancelGPUCommandBuffer(cmd)
			release_image(b, img)
			return {}, .General
		}
		sdl.EndGPURenderPass(pass)
		if !sdl.SubmitGPUCommandBuffer(cmd) {
			release_image(b, img)
			return {}, .General
		}
	} else {
		w, h := max(info.width, 1), max(info.height, 1)
		zero := make([]u8, int(w * h * vg.bytes_per_pixel(info.format if info.format != .RGB8 else .RGBA8)), context.temp_allocator)
		if uerr := upload(b, img, zero, 0, 0, w, h); uerr != nil {
			release_image(b, img)
			return {}, uerr
		}
	}
	return {user = img}, nil
}

@(private = "file")
sdl_update_image :: proc(data: rawptr, image: ^vg.Backend_Image, info: vg.Image_Info, src: vg.Image_Source, x, y: u32) -> vg.Error {
	b := (^SDL_Backend)(data)
	img := (^Image)(image.user)
	bpp := vg.bytes_per_pixel(info.format)
	stride := vg.image_source_stride(src)
	if info.format == .RGB8 {
		// Expand to RGBA8 with opaque alpha.
		px := make([]u8, int(src.width * src.height * 4), context.temp_allocator)
		for row in 0 ..< src.height {
			s := src.data[row * stride:]
			d := px[row * src.width * 4:]
			for col in 0 ..< src.width {
				d[col * 4 + 0] = s[col * 3 + 0]
				d[col * 4 + 1] = s[col * 3 + 1]
				d[col * 4 + 2] = s[col * 3 + 2]
				d[col * 4 + 3] = 255
			}
		}
		return upload(b, img, px, x, y, src.width, src.height)
	}
	if stride == src.width * bpp {
		return upload(b, img, src.data[:src.width * src.height * bpp], x, y, src.width, src.height)
	}
	packed := make([]u8, int(src.width * src.height * bpp), context.temp_allocator)
	for row in 0 ..< src.height {
		copy(packed[row * src.width * bpp:][:src.width * bpp], src.data[row * stride:][:src.width * bpp])
	}
	return upload(b, img, packed, x, y, src.width, src.height)
}

// Copies tightly packed pixels into a region of `img` with its own command
// buffer, submitted before any later frame.
@(private)
upload :: proc(b: ^SDL_Backend, img: ^Image, pixels: []u8, x, y, w, h: u32) -> vg.Error {
	size := u32(len(pixels))
	transfer := sdl.CreateGPUTransferBuffer(b.device, {usage = .UPLOAD, size = size})
	if transfer == nil {
		return .Out_Of_Memory
	}
	defer sdl.ReleaseGPUTransferBuffer(b.device, transfer)
	mapped := sdl.MapGPUTransferBuffer(b.device, transfer, false)
	if mapped == nil {
		return .Out_Of_Memory
	}
	mem.copy(mapped, raw_data(pixels), int(size))
	sdl.UnmapGPUTransferBuffer(b.device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(b.device)
	if cmd == nil {
		return .General
	}
	pass := sdl.BeginGPUCopyPass(cmd)
	if pass == nil {
		_ = sdl.CancelGPUCommandBuffer(cmd)
		return .General
	}
	sdl.UploadToGPUTexture(
		pass,
		{transfer_buffer = transfer, pixels_per_row = w, rows_per_layer = h},
		{texture = img.texture, x = x, y = y, w = w, h = h, d = 1},
		false,
	)
	sdl.EndGPUCopyPass(pass)
	if !sdl.SubmitGPUCommandBuffer(cmd) {
		return .General
	}
	return nil
}

@(private = "file")
sdl_delete_image :: proc(data: rawptr, image: vg.Backend_Image, id: vg.Image_Id) {
	b := (^SDL_Backend)(data)
	release_image(b, (^Image)(image.user))
}

// Copies a texture back to the CPU as RGBA8, top-down (half-float
// textures: as stored).
read_texture :: proc(b: ^SDL_Backend, img: Image, allocator := context.allocator) -> (pixels: []u8, err: vg.Error) {
	bpp: u32 = 1 if img.format == .R8_UNORM else 8 if img.format == .R16G16B16A16_FLOAT else 4
	size := img.width * img.height * bpp
	transfer := sdl.CreateGPUTransferBuffer(b.device, {usage = .DOWNLOAD, size = size})
	if transfer == nil {
		return nil, .Out_Of_Memory
	}
	defer sdl.ReleaseGPUTransferBuffer(b.device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(b.device)
	if cmd == nil {
		return nil, .General
	}
	pass := sdl.BeginGPUCopyPass(cmd)
	if pass == nil {
		_ = sdl.CancelGPUCommandBuffer(cmd)
		return nil, .General
	}
	sdl.DownloadFromGPUTexture(
		pass,
		{texture = img.texture, w = img.width, h = img.height, d = 1},
		{transfer_buffer = transfer, pixels_per_row = img.width, rows_per_layer = img.height},
	)
	sdl.EndGPUCopyPass(pass)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil {
		return nil, .General
	}
	_ = sdl.WaitForGPUFences(b.device, true, &fence, 1)
	sdl.ReleaseGPUFence(b.device, fence)

	mapped := ([^]u8)(sdl.MapGPUTransferBuffer(b.device, transfer, false))
	if mapped == nil {
		return nil, .General
	}
	defer sdl.UnmapGPUTransferBuffer(b.device, transfer)
	alloc_err: mem.Allocator_Error
	pixels, alloc_err = make([]u8, int(img.width * img.height * max(bpp, 4)), allocator)
	if alloc_err != nil {
		return nil, .Out_Of_Memory
	}
	n := int(img.width * img.height)
	#partial switch img.format {
	case .R8_UNORM:
		for i in 0 ..< n {
			v := mapped[i]
			pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3] = v, v, v, 255
		}
	case .B8G8R8A8_UNORM:
		for i in 0 ..< n {
			pixels[i * 4 + 0] = mapped[i * 4 + 2]
			pixels[i * 4 + 1] = mapped[i * 4 + 1]
			pixels[i * 4 + 2] = mapped[i * 4 + 0]
			pixels[i * 4 + 3] = mapped[i * 4 + 3]
		}
	case:
		copy(pixels, mapped[:size])
	}
	return pixels, nil
}

@(private = "file")
sdl_read_image :: proc(data: rawptr, image: vg.Backend_Image, info: vg.Image_Info, allocator: mem.Allocator) -> ([]u8, vg.Error) {
	b := (^SDL_Backend)(data)
	img := (^Image)(image.user)
	if img == nil || (info.format != .RGBA8 && info.format != .RGBA16F) {
		return nil, .Unsupported_Format
	}
	return read_texture(b, img^, allocator)
}

@(private = "file")
sdl_screenshot :: proc(data: rawptr, allocator: mem.Allocator) -> (vg.Screenshot, vg.Error) {
	b := (^SDL_Backend)(data)
	if b.last_screen.texture == nil {
		return {}, .Unsupported_Operation
	}
	pixels, err := read_texture(b, b.last_screen, allocator)
	if err != nil {
		return {}, err
	}
	return {pixels, b.last_screen.width, b.last_screen.height}, nil
}

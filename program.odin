package ovg

// Custom fragment programs: a host-supplied fragment shader (and its CPU
// twin for the software backend) run over a whole image, like a filter.
// ovg knows nothing about the shading language; the host compiles it
// (e.g. with oksl) and registers the blobs.
//
// A run is a recorded command executed in order at flush: the target image
// is cleared, then every pixel is shaded from a uniform block (copied into
// the frame) and up to PROGRAM_MAX_CHANNELS input images. The result is
// premultiplied RGBA, so draw it with an image paint flagged Premultiplied.
// An RGBA16F target keeps the program's values unclamped (feedback buffers
// read back by later runs).
//
// GPU bindings (SDL_GPU, the layout oksl emits): vertex input position in
// target pixels (location 0) and uv 0..1 from the top-left (location 1),
// with the target size as a vec4 in the vertex uniform buffer (set 1,
// binding 0); fragment input uv at location 0; channel n a combined image
// sampler at set 2, binding n; the uniform block at set 3, binding 0.
// Sampler filtering and wrapping follow each channel image's flags
// (Nearest, Repeat_X, Repeat_Y); unbound channels read transparent black.

PROGRAM_MAX_CHANNELS :: 4

// Samples input image `channel` at normalized `uv` (origin top-left) and mip
// level `lod` with GL semantics: bilinear or nearest per the image flags,
// clamp-to-edge or repeat, texel values as stored (Gray8 and Gray16 are (g, 0, 0, 1),
// RGB8 has alpha 1). The software backend has no mipmaps; `lod` is ignored.
Program_Sample_Proc :: #type proc(data: rawptr, channel: int, uv: [2]f32, lod: f32) -> [4]f32

Program_Sampler :: struct {
	data:   rawptr,
	sample: Program_Sample_Proc,
}

// The CPU program: shades a `width x height` image into `out` (`format`
// texels: RGBA8, or RGBA16F stored as is; `stride` bytes per row,
// top-down, premultiplied). `out` starts cleared; pixels the program leaves
// alone stay that way.
Program_Cpu_Proc :: #type proc(user: rawptr, uniforms: []u8, width, height: int, out: []u8, stride: int, format: Pixel_Format, sampler: Program_Sampler)

// What a backend needs to run a program. Backends take the parts they
// understand (SDL_GPU: SPIR-V or MSL; software: `cpu`) and copy what they
// keep, so the blobs only need to live through `create_program`.
Program_Desc :: struct {
	// Entry point names; nil means "main".
	frag_spirv:       []u8,
	frag_spirv_entry: cstring,
	frag_msl:         []u8,
	frag_msl_entry:   cstring,
	vert_spirv:       []u8,
	vert_spirv_entry: cstring,
	vert_msl:         []u8,
	vert_msl_entry:   cstring,
	// Size of the fragment uniform block in bytes.
	uniform_size:     int,
	// Fragment samplers the program declares (channels 0 ..< num_samplers).
	num_samplers:     int,
	cpu:              Program_Cpu_Proc,
	cpu_user:         rawptr,
}

// A backend's handle for a registered program.
Backend_Program :: struct {
	handle: u32,
	user:   rawptr,
}

Program_Id :: struct {
	key: Key,
}

program_id_valid :: #force_inline proc "contextless" (id: Program_Id) -> bool {
	return id.key.gen != 0
}

Program_Flag :: enum u8 {
	// Write alpha 1 everywhere (Shadertoy ignores the alpha it outputs).
	Opaque,
}
Program_Flags :: bit_set[Program_Flag;u8]

// Runs `Frame.runs[run]`.
Cmd_Run_Program :: struct {
	run: u32,
}

// A program run (`run_program`): one row of `Frame.runs`.
Program_Run :: struct {
	program:  Backend_Program,
	target:   Image_Id,
	// The uniform block: a range of `Frame.bytes`.
	uniforms: Range,
	channels: [PROGRAM_MAX_CHANNELS]Image_Id,
	flags:    Program_Flags,
}

// A program registered on a recording canvas, for the player to create.
// The desc's blobs must stay alive until the frame is played.
Program_Op :: struct {
	key:    Key,
	desc:   Program_Desc,
	// The program was deleted: the player frees its backend program.
	delete: bool,
}

// Registers a program with the backend. `.Unsupported_Operation` when the
// backend can't run custom programs (or got no code it understands). On a
// recording canvas the player registers it with its backend (where errors
// leave the program's runs out), so the desc's blobs must outlive the
// frames recorded with it.
create_program :: proc(c: ^Canvas, desc: Program_Desc) -> (Program_Id, Error) {
	if desc.num_samplers < 0 || desc.num_samplers > PROGRAM_MAX_CHANNELS || desc.uniform_size < 0 {
		return {}, .General
	}
	if c.images.recording {
		// The run commands carry the key index as their program handle.
		key := slot_map_insert(&c.programs, Backend_Program{})
		slot_map_get(&c.programs, key).handle = key.idx
		append(&c.program_ops, Program_Op{key = key, desc = desc})
		return {key}, nil
	}
	if c.backend.create_program == nil {
		return {}, .Unsupported_Operation
	}
	p, err := c.backend.create_program(c.backend.data, desc)
	if err != nil {
		return {}, err
	}
	return {slot_map_insert(&c.programs, p)}, nil
}

// Frees a program. Commands already recorded with it must be flushed (on a
// recording canvas: taken) first.
delete_program :: proc(c: ^Canvas, id: Program_Id) {
	p, ok := slot_map_remove(&c.programs, id.key)
	if !ok {
		return
	}
	if c.images.recording {
		append(&c.program_ops, Program_Op{key = id.key, delete = true})
	} else if c.backend.delete_program != nil {
		c.backend.delete_program(c.backend.data, p)
	}
}

// Overwrites `target` (an RGBA8 or RGBA16F image) with the program's output when the
// frame is flushed. `uniforms` is copied; `channels[n]` is the image bound
// to channel n (zero ids read transparent black) and must not be the
// target. Transforms, scissor and the current render target do not apply.
run_program :: proc(c: ^Canvas, id: Program_Id, target: Image_Id, uniforms: []u8, channels: []Image_Id = nil, flags: Program_Flags = {}) -> Error {
	p := slot_map_get(&c.programs, id.key)
	if p == nil {
		return .General
	}
	info, ok := image_store_info(&c.images, target)
	if !ok {
		return .Image_Id_Not_Found
	}
	if info.format != .RGBA8 && info.format != .RGBA16F {
		return .Unsupported_Format
	}
	for ch in channels {
		if ch == target {
			// A GPU pass can't sample the texture it renders into.
			return .Unsupported_Operation
		}
	}
	cmd := Program_Run {
		program = p^,
		target  = target,
		flags   = flags,
	}
	// Uniform blocks start 16-byte aligned, as GPU uploads like.
	for len(c.bytes) % 16 != 0 {
		append(&c.bytes, 0)
	}
	cmd.uniforms = {u32(len(c.bytes)), u32(len(uniforms))}
	append(&c.bytes, ..uniforms)
	for ch, i in channels[:min(len(channels), PROGRAM_MAX_CHANNELS)] {
		cmd.channels[i] = ch
	}
	append(&c.runs, cmd)
	append(&c.commands, Command{type = Cmd_Run_Program{u32(len(c.runs) - 1)}})
	return nil
}

// Host work run at its place in the frame (`run_external`). `gpu` is the
// backend's handle for the frame's GPU work (SDL_GPU: the
// `^sdl.GPUCommandBuffer`, outside any pass); nil on the software backend.
// `images` is the store the frame's images live in: the canvas's, or the
// player's when a recorded frame plays (`image_store_info`,
// `image_store_get(..).image.pixels` on the software backend,
// `sdlgpu.image_store_texture`).
External_Proc :: #type proc(user: rawptr, gpu: rawptr, images: ^Image_Store)

// Calls `fn(user, gpu, images)`.
Cmd_Run_External :: struct {
	fn:   External_Proc,
	user: rawptr,
}

// Runs `fn(user, gpu, images)` when the frame renders, after the commands recorded
// before it and before those after it: GPU work the host records there
// (3D renders into canvas images, say) reads what earlier commands made
// and later draws read its output. The images it touches are the host's
// own business (`images` holds them): ovg
// neither tracks them nor bounds layers by them, and layer stand-ins don't
// apply. On SDL_GPU `fn` records into the command buffer it gets (closing
// any pass it opens) without submitting it or creating textures, which
// would submit; render targets and passes resume after it. On a
// recording canvas `user` must stay valid until the frame is played, and
// every `player_render` of the frame calls `fn` again.
run_external :: proc(c: ^Canvas, fn: External_Proc, user: rawptr) {
	if fn != nil {
		append(&c.commands, Command{type = Cmd_Run_External{fn, user}})
	}
}

frame_bytes :: #force_inline proc "contextless" (f: Frame, r: Range) -> []u8 {
	return f.bytes[r.start:][:r.count]
}

@(private)
programs_destroy :: proc(c: ^Canvas) {
	if !c.images.recording && c.backend.delete_program != nil {
		for &s in c.programs.slots {
			if s.occupied {
				c.backend.delete_program(c.backend.data, s.value)
			}
		}
	}
	slot_map_destroy(&c.programs)
}

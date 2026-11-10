package ovg_sdlgpu

import "core:math"
import sdl "vendor:sdl3"

import vg ".."
import cv "deps:ocurves"

#assert(cv.FORMAT == SHADERS_CURVES_FORMAT, "ovg's shape shaders read another ocurves curves.FORMAT: use the ocurves this ovg's tag names, or rerun shaders/build.sh against this one")

// The backend's copies of the shapes it draws, in one storage buffer the
// shape shader reads, found by shape id's slot: a shape is uploaded the first time
// it is drawn, after the shapes kept so far, and a frame's own words (paths
// filled this frame, group grids) follow them, in the space the last
// frame's took. Nothing is freed one by one: when a frame doesn't fit, the
// store starts over in a fresh buffer holding what that frame draws (the
// old one is released once the frames reading it finish), so destroyed
// shapes cost nothing beyond it.
Shape_Store :: struct {
	buffer:            ^sdl.GPUBuffer,
	// In 32-bit words: the store's, the end of the shapes kept, and the end
	// of the frame's words after them.
	capacity:          u32,
	kept:              u32,
	top:               u32,
	// By shape id slot (vg.shape_id_slots): the id placed there and its
	// offset, while placed in this generation of the store, which a restart
	// ends, so starting over clears nothing.
	at:                [dynamic]Store_Place,
	gen:               u32,
	// Words placed but not yet uploaded.
	pending:           [dynamic]Pending_Shape,
	transfer:          ^sdl.GPUTransferBuffer,
	transfer_capacity: u32,
}

@(private)
Store_Place :: struct {
	id:     u64,
	gen:    u32,
	offset: u32,
}

@(private = "file")
Pending_Shape :: struct {
	offset: u32,
	data:   []u32,
}

// One shape instance as the shape shader reads it (`Shape_Instance` in
// ovg.slang).
@(private)
Gpu_Shape_Instance :: struct {
	m:      [4]f32,
	t:      [4]f32,
	bounds: [4]f32,
	uv:     [4]f32,
	data:   [4]u32,
	// The scissor's pixels (target pixels x0, y0, x1, y1).
	clip:   [4]f32,
}

@(private)
store_init :: proc(b: ^SDL_Backend) {
	b.shapes.at = make([dynamic]Store_Place, b.allocator)
	b.shapes.gen = 1
	b.shapes.pending = make([dynamic]Pending_Shape, b.allocator)
}

@(private)
store_destroy :: proc(b: ^SDL_Backend) {
	st := &b.shapes
	retire_buffer(b.device, b.retired, st.buffer)
	if st.transfer != nil {
		sdl.ReleaseGPUTransferBuffer(b.device, st.transfer)
	}
	delete(st.at)
	delete(st.pending)
	st^ = {}
}

// Places the frame's shapes: each instance's word offset in the store
// (`b.shape_offsets`), placing the shapes new to it and the frame's own
// words to upload this frame. Returns where the group grids
// (`b.group_words`) go; false when the store can't be that large.
@(private)
store_place :: proc(b: ^SDL_Backend, frame: vg.Frame) -> (grids: u32, ok: bool) {
	st := &b.shapes
	resize(&b.shape_offsets, len(frame.shapes))
	restart :: proc(st: ^Shape_Store) {
		st.gen = st.gen + 1 if st.gen + 1 != 0 else 1
		clear(&st.pending)
		st.kept, st.top, st.capacity = 0, 0, 0
	}
	if len(st.pending) > 0 {
		// The last frame was dropped before its upload: what it placed may
		// be gone, so start over.
		restart(st)
		b.stats.shape_restarts = 1
	}
	place :: proc(st: ^Shape_Store, data: []u32) -> u32 {
		offset := st.top
		if len(data) > 0 {
			append(&st.pending, Pending_Shape{offset, data})
			st.top += u32(len(data))
		}
		return offset
	}
	// Every shape the frame draws was built before it, so its slot is below
	// the count now; new places are zero, of no generation.
	if n := vg.shape_id_slots(); n > len(st.at) {
		resize(&st.at, max(n, 2 * len(st.at)))
	}
	for again in ([2]bool{false, true}) {
		st.top = st.kept
		for inst, i in frame.shapes {
			if inst.shape == nil {
				continue
			}
			p := &st.at[u32(inst.shape.id)]
			if p.id != inst.shape.id || p.gen != st.gen {
				p^ = {inst.shape.id, st.gen, place(st, inst.shape.data)}
			}
			b.shape_offsets[i] = p.offset
		}
		st.kept = st.top
		own := place(st, frame.shape_words)
		grids = place(st, b.group_words[:])
		for inst, i in frame.shapes {
			if inst.shape == nil {
				b.shape_offsets[i] = own + inst.words.start
			}
		}
		if st.top <= st.capacity || again {
			break
		}
		// It doesn't fit: start over with only this frame's shapes, in a
		// buffer four times their size (store_upload makes it).
		restart(st)
		b.stats.shape_restarts = 1
	}
	// Sizes in bytes are 32-bit.
	return grids, st.top <= 1 << 28
}

// Uploads the words placed since the last upload, into a fresh buffer when
// the store started over; false (nothing recorded) when the device fails.
@(private)
store_upload :: proc(b: ^SDL_Backend, cmd: ^sdl.GPUCommandBuffer) -> bool {
	st := &b.shapes
	if st.top > st.capacity {
		capacity := u32(math.next_power_of_two(int(max(4 * st.top, 1 << 16))))
		buffer := sdl.CreateGPUBuffer(b.device, {usage = {.GRAPHICS_STORAGE_READ}, size = capacity * 4})
		if buffer == nil {
			return false
		}
		retire_buffer(b.device, b.retired, st.buffer)
		st.buffer, st.capacity = buffer, capacity
	}
	total: u32
	for p in st.pending {
		total += u32(len(p.data))
	}
	b.stats.shape_upload_words += int(total)
	if total == 0 {
		return true
	}
	if total > st.transfer_capacity {
		if st.transfer != nil {
			sdl.ReleaseGPUTransferBuffer(b.device, st.transfer)
		}
		st.transfer_capacity = u32(math.next_power_of_two(int(max(total, 1 << 14))))
		st.transfer = sdl.CreateGPUTransferBuffer(b.device, {usage = .UPLOAD, size = st.transfer_capacity * 4})
		if st.transfer == nil {
			st.transfer_capacity = 0
			return false
		}
	}
	words := ([^]u32)(sdl.MapGPUTransferBuffer(b.device, st.transfer, true))
	if words == nil {
		return false
	}
	// Each word placed went on at the top of the store, so the words wait
	// as one run of it: one copy (a copy a shape cost the GPU about 1.2 µs
	// each: 18 ms for 15,000 shapes).
	first := st.pending[0].offset
	at: u32
	for p in st.pending {
		assert(p.offset == first + at, "the store's pending words are one run")
		copy(words[at:][:len(p.data)], p.data)
		at += u32(len(p.data))
	}
	sdl.UnmapGPUTransferBuffer(b.device, st.transfer)
	pass := sdl.BeginGPUCopyPass(cmd)
	if pass == nil {
		return false
	}
	sdl.UploadToGPUBuffer(pass, {transfer_buffer = st.transfer}, {buffer = st.buffer, offset = first * 4, size = total * 4}, false)
	sdl.EndGPUCopyPass(pass)
	return true
}

// The instance as the shader reads it: `offset` is its shape's words'
// place in the store, `frame_words` the frame's own.
@(private)
gpu_shape_instance :: proc(inst: vg.Shape_Instance, frame_words: []u32, offset: u32, clip: [4]f32) -> Gpu_Shape_Instance {
	t := inst.transform
	epp := vg.shape_ems_per_pixel(t) * vg.instance_reach(inst)
	u, v := vg.instance_footprint(inst)
	flags: u32 = (1 if inst.rule == .Even_Odd else 0) | (2 if inst.edge == .Aliased else 0) | (4 if inst.edge == .Smooth else 0)
	// A hairline's width in place of the flags: a positive normal float,
	// whose exponent bits the shader tells from the flags by. Anything
	// narrower than the smallest normal float covers nothing anyway.
	if inst.hairline > 0 {
		flags = transmute(u32)max(inst.hairline, transmute(f32)u32(0x0080_0000))
	}
	// A marker: the unit square or circle, its kind where a shape's words
	// are (16 added when it is filled).
	at := offset
	sb := vg.Bounds{-1, -1, 1, 1}
	if inst.marker != .None {
		at = u32(inst.marker) | (16 if inst.marker_fill else 0)
	} else {
		sb = vg.instance_shape_bounds(inst, frame_words)
	}
	return {
		m = {t[0], t[1], t[2], t[3]},
		t = {t[4], t[5], epp.x, epp.y},
		bounds = {sb.minx, sb.miny, sb.maxx, sb.maxy},
		uv = {u.x, u.y, v.x, v.y},
		data = {at, inst.paint, flags, 0},
		clip = clip,
	}
}

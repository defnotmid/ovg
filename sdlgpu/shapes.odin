package ovg_sdlgpu

import "core:math"
import sdl "vendor:sdl3"

import vg ".."
import cv "../curves"

// The backend's copies of the shapes it draws, in one storage buffer the
// shape shader reads, found by shape id: a shape is uploaded the first time
// it is drawn, and a frame's own shapes (filled paths) are appended each
// frame. Nothing is freed one by one: when a frame doesn't fit, the store
// starts over in a fresh buffer holding what that frame draws (the old one
// is released once the frames reading it finish), so destroyed shapes and
// past frames' words cost nothing beyond it.
Shape_Store :: struct {
	buffer:            ^sdl.GPUBuffer,
	// In 32-bit words.
	capacity:          u32,
	top:               u32,
	// Shape id to its place.
	at:                map[u64]u32,
	// Words placed but not yet uploaded.
	pending:           [dynamic]Pending_Shape,
	transfer:          ^sdl.GPUTransferBuffer,
	transfer_capacity: u32,
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
}

@(private)
store_init :: proc(b: ^SDL_Backend) {
	b.shapes.at = make(map[u64]u32, b.allocator)
	b.shapes.pending = make([dynamic]Pending_Shape, b.allocator)
}

@(private)
store_destroy :: proc(b: ^SDL_Backend) {
	st := &b.shapes
	if st.buffer != nil {
		sdl.ReleaseGPUBuffer(b.device, st.buffer)
	}
	if st.transfer != nil {
		sdl.ReleaseGPUTransferBuffer(b.device, st.transfer)
	}
	delete(st.at)
	delete(st.pending)
	st^ = {}
}

// Places the frame's shapes: each instance's word offset in the store
// (`b.shape_offsets`), placing the shapes new to it and the frame's own
// words to upload this frame; false when the store can't be that large.
@(private)
store_place :: proc(b: ^SDL_Backend, frame: vg.Frame) -> bool {
	st := &b.shapes
	resize(&b.shape_offsets, len(frame.shapes))
	if len(st.pending) > 0 {
		// The last frame was dropped before its upload: what it placed may
		// be gone, so start over.
		clear(&st.at)
		clear(&st.pending)
		st.top, st.capacity = 0, 0
	}
	place :: proc(st: ^Shape_Store, data: []u32) -> u32 {
		offset := st.top
		if len(data) > 0 {
			append(&st.pending, Pending_Shape{offset, data})
			st.top += u32(len(data))
		}
		return offset
	}
	for again in ([2]bool{false, true}) {
		own := place(st, frame.shape_words)
		for inst, i in frame.shapes {
			if inst.shape == nil {
				b.shape_offsets[i] = own + inst.words.start
				continue
			}
			offset, ok := st.at[inst.shape.id]
			if !ok {
				offset = place(st, inst.shape.data)
				st.at[inst.shape.id] = offset
			}
			b.shape_offsets[i] = offset
		}
		if st.top <= st.capacity || again {
			break
		}
		// It doesn't fit: start over with only this frame's shapes, in a
		// buffer twice their size (store_upload makes it).
		clear(&st.at)
		clear(&st.pending)
		st.top, st.capacity = 0, 0
	}
	// Sizes in bytes are 32-bit.
	return st.top <= 1 << 28
}

// Uploads the words placed since the last upload, into a fresh buffer when
// the store started over; false (nothing recorded) when the device fails.
@(private)
store_upload :: proc(b: ^SDL_Backend, cmd: ^sdl.GPUCommandBuffer) -> bool {
	st := &b.shapes
	if st.top > st.capacity {
		capacity := u32(math.next_power_of_two(int(max(2 * st.top, 1 << 16))))
		buffer := sdl.CreateGPUBuffer(b.device, {usage = {.GRAPHICS_STORAGE_READ}, size = capacity * 4})
		if buffer == nil {
			return false
		}
		if st.buffer != nil {
			sdl.ReleaseGPUBuffer(b.device, st.buffer)
		}
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
	at: u32
	for p in st.pending {
		copy(words[at:][:len(p.data)], p.data)
		at += u32(len(p.data))
	}
	sdl.UnmapGPUTransferBuffer(b.device, st.transfer)
	pass := sdl.BeginGPUCopyPass(cmd)
	if pass == nil {
		return false
	}
	at = 0
	for p in st.pending {
		n := u32(len(p.data))
		sdl.UploadToGPUBuffer(pass, {transfer_buffer = st.transfer, offset = at * 4}, {buffer = st.buffer, offset = p.offset * 4, size = n * 4}, false)
		at += n
	}
	sdl.EndGPUCopyPass(pass)
	clear(&st.pending)
	return true
}

// The instance as the shader reads it: `words` are its shape's, `offset`
// their place in the store.
@(private)
gpu_shape_instance :: proc(inst: vg.Shape_Instance, words: []u32, offset: u32) -> Gpu_Shape_Instance {
	t := inst.transform
	epp := vg.shape_ems_per_pixel(t) * (1 + inst.widen)
	u, v := vg.instance_footprint(inst)
	x0, y0, x1, y1 := cv.bounds(words)
	flags: u32 = (1 if inst.even_odd else 0) | (2 if inst.aliased else 0)
	return {
		m = {t[0], t[1], t[2], t[3]},
		t = {t[4], t[5], epp.x, epp.y},
		bounds = {x0, y0, x1, y1},
		uv = {u.x, u.y, v.x, v.y},
		data = {offset, inst.paint, flags, 0},
	}
}

package ovg_sdlgpu

import "core:math"
import sdl "vendor:sdl3"

import vg ".."

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
	// By shape id slot (vg.shape_id_slots): the id placed there and the
	// offsets of its levels placed, while placed in this generation of the
	// store, which a restart ends, so starting over clears nothing.
	at:                [dynamic]Store_Place,
	gen:               u32,
	// Words placed but not yet uploaded.
	pending:           [dynamic]Pending_Shape,
	// The words the buffer holds from earlier frames (its kept shapes'),
	// which a larger buffer takes by copy: the store grows without
	// uploading again what the GPU has.
	held:              u32,
	transfer:          ^sdl.GPUTransferBuffer,
	transfer_capacity: u32,
}

@(private)
Store_Place :: struct {
	id:      u64,
	gen:     u32,
	// Per level (vg.shape_level: 0 the shape's own words), where its words
	// lie, PLACE_NONE when no frame of this generation drew it.
	offsets: [1 + len(vg.SHAPE_LEVEL_ERRORS)]u32,
}

@(private = "file")
PLACE_NONE :: max(u32)

@(private = "file")
Pending_Shape :: struct {
	offset: u32,
	data:   []u32,
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
	held := st.kept
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
				p^ = {id = inst.shape.id, gen = st.gen}
				for &o in p.offsets {
					o = PLACE_NONE
				}
			}
			// Only the level the instance draws is placed.
			lo, hi, level := vg.shape_level(inst.shape, inst.transform)
			if p.offsets[level] == PLACE_NONE {
				p.offsets[level] = place(st, inst.shape.data[lo:hi])
			}
			b.shape_offsets[i] = p.offsets[level]
		}
		st.kept = st.top
		own := place(st, frame.shape_words)
		grids = place(st, b.group_words[:])
		for inst, i in frame.shapes {
			if inst.shape == nil {
				b.shape_offsets[i] = own + inst.words.start
			}
		}
		if st.top <= STORE_MAX_CAPACITY / 2 || again {
			break
		}
		// Past what a store holds: start over with only this frame's
		// shapes.
		restart(st)
		held = 0
		b.stats.shape_restarts = 1
	}
	// Past its capacity the store grows (store_upload), keeping what it holds.
	st.held = held
	// Sizes in bytes are 32-bit (store_capacity).
	return grids, st.top <= STORE_MAX_CAPACITY / 2
}

// The words a fresh store holds for `top` placed: four times as many, a
// power of two, but at most STORE_MAX_CAPACITY, whose size in bytes is
// still 32-bit (store_place refuses a frame of more than half that).
@(private)
store_capacity :: proc "contextless" (top: u32) -> u32 {
	return u32(min(math.next_power_of_two(int(max(4 * u64(top), 1 << 16))), STORE_MAX_CAPACITY))
}

@(private)
STORE_MAX_CAPACITY :: 1 << 29

// Uploads the words placed since the last upload, into a larger buffer
// when they pass the store's capacity, the words it holds copied over on
// the GPU first; false (nothing recorded) when the device fails.
@(private)
store_upload :: proc(b: ^SDL_Backend, cmd: ^sdl.GPUCommandBuffer) -> bool {
	st := &b.shapes
	if st.top > st.capacity {
		capacity := store_capacity(st.top)
		buffer := sdl.CreateGPUBuffer(b.device, {usage = {.GRAPHICS_STORAGE_READ}, size = capacity * 4})
		if buffer == nil {
			return false
		}
		if st.held > 0 && st.buffer != nil {
			pass := sdl.BeginGPUCopyPass(cmd)
			if pass == nil {
				sdl.ReleaseGPUBuffer(b.device, buffer)
				return false
			}
			sdl.CopyGPUBufferToBuffer(pass, {buffer = st.buffer}, {buffer = buffer}, st.held * 4, false)
			sdl.EndGPUCopyPass(pass)
			b.stats.shape_grows = 1
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

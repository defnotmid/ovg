package ovg_sdlgpu

import "core:math"
import "core:sync"
import sdl "vendor:sdl3"

import vg ".."

// The backend's copies of the shapes it has drawn (vg.Shape), in one
// storage buffer the shape shader reads: a shape is uploaded the first
// frame it is drawn and stays until it is destroyed (`vg.shape_destroy`
// calls `store_forget`, on any thread). A freed range is reused once the
// frames that may still read it have finished. The buffer grows by
// doubling, keeping every shape's place.
Shape_Store :: struct {
	lock:              sync.Mutex,
	buffer:            ^sdl.GPUBuffer,
	// In 32-bit words.
	capacity:          u32,
	top:               u32,
	ranges:            map[u64]Shape_Range,
	free:              [dynamic]Free_Range,
	// Shapes placed but not yet uploaded.
	pending:           [dynamic]Pending_Shape,
	// The buffer before it grew this frame, and the words to copy from it.
	old:               ^sdl.GPUBuffer,
	old_top:           u32,
	transfer:          ^sdl.GPUTransferBuffer,
	transfer_capacity: u32,
	// The backend's frame count, for the age of freed ranges.
	frame:             u64,
}

@(private = "file")
Shape_Range :: struct {
	offset, words: u32,
}

@(private = "file")
Free_Range :: struct {
	offset, words: u32,
	// The frame it was freed in.
	frame:         u64,
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
	data:   [4]u32,
}

@(private)
store_init :: proc(b: ^SDL_Backend) {
	st := &b.shapes
	st.ranges = make(map[u64]Shape_Range, b.allocator)
	st.free = make([dynamic]Free_Range, b.allocator)
	st.pending = make([dynamic]Pending_Shape, b.allocator)
	vg.shape_store_register({st, store_forget})
}

@(private)
store_destroy :: proc(b: ^SDL_Backend) {
	st := &b.shapes
	vg.shape_store_unregister(st)
	if st.buffer != nil {
		sdl.ReleaseGPUBuffer(b.device, st.buffer)
	}
	if st.old != nil {
		sdl.ReleaseGPUBuffer(b.device, st.old)
	}
	if st.transfer != nil {
		sdl.ReleaseGPUTransferBuffer(b.device, st.transfer)
	}
	delete(st.ranges)
	delete(st.free)
	delete(st.pending)
	st^ = {}
}

@(private = "file")
store_forget :: proc(data: rawptr, id: u64) {
	st := (^Shape_Store)(data)
	sync.mutex_lock(&st.lock)
	defer sync.mutex_unlock(&st.lock)
	r, ok := st.ranges[id]
	if !ok {
		return
	}
	delete_key(&st.ranges, id)
	for p, i in st.pending {
		if p.offset == r.offset {
			unordered_remove(&st.pending, i)
			break
		}
	}
	append(&st.free, Free_Range{r.offset, r.words, st.frame})
}

// The shape's word offset in the store, placing it (to upload this frame)
// on first use; false when the device can't grow the store.
@(private)
store_place :: proc(b: ^SDL_Backend, s: ^vg.Shape) -> (offset: u32, ok: bool) {
	st := &b.shapes
	sync.mutex_lock(&st.lock)
	defer sync.mutex_unlock(&st.lock)
	if r, has := st.ranges[s.id]; has {
		return r.offset, true
	}
	words := u32(len(s.data))
	offset, ok = store_alloc(b, words)
	if !ok {
		return
	}
	st.ranges[s.id] = {offset, words}
	append(&st.pending, Pending_Shape{offset, s.data})
	return offset, true
}

@(private = "file")
store_alloc :: proc(b: ^SDL_Backend, words: u32) -> (offset: u32, ok: bool) {
	st := &b.shapes
	// A freed range old enough that no running frame reads it, best fit.
	best := -1
	for f, i in st.free {
		if f.words >= words && st.frame > f.frame + MAX_FRAMES_IN_FLIGHT && (best < 0 || f.words < st.free[best].words) {
			best = i
		}
	}
	if best >= 0 {
		f := &st.free[best]
		offset = f.offset
		if f.words == words {
			unordered_remove(&st.free, best)
		} else {
			f.offset += words
			f.words -= words
		}
		return offset, true
	}
	if st.top + words > st.capacity {
		capacity := u32(math.next_power_of_two(int(max(st.top + words, 1 << 16))))
		buffer := sdl.CreateGPUBuffer(b.device, {usage = {.GRAPHICS_STORAGE_READ}, size = capacity * 4})
		if buffer == nil {
			return 0, false
		}
		if st.old == nil {
			// Copied into the new buffer before this frame's uploads.
			st.old, st.old_top = st.buffer, st.top
		} else if st.buffer != nil {
			// Grown twice this frame: the middle buffer holds nothing yet.
			sdl.ReleaseGPUBuffer(b.device, st.buffer)
		}
		st.buffer, st.capacity = buffer, capacity
	}
	offset = st.top
	st.top += words
	return offset, true
}

// Copies the shapes placed since the last upload into the store; false
// (nothing recorded, the shapes left pending) when the device fails.
@(private)
store_upload :: proc(b: ^SDL_Backend, cmd: ^sdl.GPUCommandBuffer) -> bool {
	st := &b.shapes
	sync.mutex_lock(&st.lock)
	defer sync.mutex_unlock(&st.lock)
	if st.old != nil {
		if st.old_top > 0 {
			pass := sdl.BeginGPUCopyPass(cmd)
			if pass == nil {
				return false
			}
			sdl.CopyGPUBufferToBuffer(pass, {buffer = st.old}, {buffer = st.buffer}, st.old_top * 4, false)
			sdl.EndGPUCopyPass(pass)
		}
		sdl.ReleaseGPUBuffer(b.device, st.old)
		st.old, st.old_top = nil, 0
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

// Starts the backend's frame `frame` in the store (the age of freed
// ranges).
@(private)
store_begin_frame :: proc(b: ^SDL_Backend) {
	sync.mutex_lock(&b.shapes.lock)
	b.shapes.frame = b.frame
	sync.mutex_unlock(&b.shapes.lock)
}

// The instance as the shader reads it: `offset` is the shape's place in
// the store.
@(private)
gpu_shape_instance :: proc(inst: vg.Shape_Instance, offset: u32) -> Gpu_Shape_Instance {
	t := inst.transform
	epp := vg.shape_ems_per_pixel(t)
	x0, y0, x1, y1 := vg.shape_bounds(inst.shape)
	return {
		m = {t[0], t[1], t[2], t[3]},
		t = {t[4], t[5], epp.x, epp.y},
		bounds = {x0, y0, x1, y1},
		data = {offset, inst.paint, 1 if inst.even_odd else 0, 0},
	}
}

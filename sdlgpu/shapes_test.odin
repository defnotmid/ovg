package ovg_sdlgpu

import "core:testing"
import vg ".."

// The store finds a shape it holds by its id's slot and places one it
// doesn't, including a later shape in a destroyed one's slot, whose words
// it must not take for the old one's. No device: store_place only lays out
// words, and the upload is stood in for.
@(test)
test_store_recycled_slot :: proc(t: ^testing.T) {
	b: SDL_Backend
	store_init(&b)
	defer {
		delete(b.shapes.at)
		delete(b.shapes.pending)
		delete(b.shape_offsets)
	}
	uploaded :: proc(b: ^SDL_Backend) {
		b.shapes.capacity = 1 << 20
		clear(&b.shapes.pending)
	}
	p: vg.Path
	vg.path_init(&p)
	defer vg.path_destroy(&p)
	vg.path_rect(&p, 0, 0, 4, 4)
	a, _ := vg.shape_from_path(&p)
	vg.path_reset(&p)
	vg.path_circle(&p, 0, 0, 3)
	c, _ := vg.shape_from_path(&p)
	defer vg.shape_destroy(&c)
	draw :: proc(b: ^SDL_Backend, shapes: []vg.Shape_Instance) -> []u32 {
		_, ok := store_place(b, {shapes = shapes})
		assert(ok)
		return b.shape_offsets[:]
	}

	frame := [2]vg.Shape_Instance{{shape = &a}, {shape = &c}}
	first := draw(&b, frame[:])
	at_a, at_c := first[0], first[1]
	testing.expect_value(t, len(b.shapes.pending), 2)
	uploaded(&b)
	// Held: found where they were, nothing to upload.
	again := draw(&b, frame[:])
	testing.expect_value(t, again[0], at_a)
	testing.expect_value(t, again[1], at_c)
	testing.expect_value(t, len(b.shapes.pending), 0)
	uploaded(&b)

	old := a.id
	vg.shape_destroy(&a)
	vg.path_reset(&p)
	vg.path_rect(&p, 0, 0, 9, 2)
	n, _ := vg.shape_from_path(&p)
	defer vg.shape_destroy(&n)
	testing.expect(t, n.id != old)
	frame[0] = {shape = &n}
	later := draw(&b, frame[:])
	// The new shape's words are placed and uploaded, not the old one's
	// offset reused, even in the old one's slot.
	testing.expect(t, later[0] != at_a)
	testing.expect_value(t, later[1], at_c)
	testing.expect_value(t, len(b.shapes.pending), 1)
	if len(b.shapes.pending) == 1 {
		testing.expect(t, raw_data(b.shapes.pending[0].data) == raw_data(n.data))
	}
}

// A store's size in bytes fits 32 bits however many words a frame places
// (store_place takes up to half of STORE_MAX_CAPACITY): past 2^27 words, four
// times as many rounded to a power of two was 2^30 words, 2^32 bytes, which
// wrapped to 0 and failed every frame.
@(test)
test_store_capacity :: proc(t: ^testing.T) {
	for top in ([?]u32{0, 1, 1 << 16, 1 << 27 - 1, 1 << 27, 1 << 27 + 1, 197_423_087, STORE_MAX_CAPACITY / 2}) {
		capacity := store_capacity(top)
		testing.expectf(t, capacity >= top && capacity * 4 != 0 && u64(capacity) * 4 <= u64(max(u32)), "%d words placed: capacity %d", top, capacity)
	}
	testing.expect_value(t, store_capacity(1000), 1 << 16)
	testing.expect_value(t, store_capacity(1 << 20), 1 << 22)
}

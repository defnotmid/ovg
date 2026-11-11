package ovg_sdlgpu

import "core:math"
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

// The store places only the level an instance draws (vg.shape_level): a
// detailed shape drawn large places its own words, drawn small one of its
// coarse levels' beside them, and drawn at both again places nothing.
@(test)
test_store_levels :: proc(t: ^testing.T) {
	b: SDL_Backend
	store_init(&b)
	defer {
		delete(b.shapes.at)
		delete(b.shapes.pending)
		delete(b.shape_offsets)
	}
	p: vg.Path
	vg.path_init(&p)
	defer vg.path_destroy(&p)
	for k in 0 ..< 4096 {
		a := 2 * math.PI * f32(k) / 4096
		r := 1 + 0.0004 * math.sin(f32(k) * 1.3) + 0.05 * math.sin(a * 5)
		if k == 0 {
			vg.path_move_to(&p, r * math.cos(a), r * math.sin(a))
		} else {
			vg.path_line_to(&p, r * math.cos(a), r * math.sin(a))
		}
	}
	vg.path_close(&p)
	s, _ := vg.shape_from_path(&p, search = false)
	defer vg.shape_destroy(&s)
	testing.expect(t, s.level_count > 0)
	large := vg.transform_multiply(vg.shape_local(&s), {400, 0, 0, 400, 0, 0})
	small := vg.transform_multiply(vg.shape_local(&s), {4, 0, 0, 4, 0, 0})
	frame := [2]vg.Shape_Instance{{shape = &s, transform = large}, {shape = &s, transform = small}}
	_, ok := store_place(&b, {shapes = frame[:]})
	testing.expect(t, ok)
	testing.expect_value(t, len(b.shapes.pending), 2)
	if len(b.shapes.pending) == 2 {
		lo, hi, level := vg.shape_level(&s, small)
		testing.expect(t, level > 0)
		testing.expect_value(t, len(b.shapes.pending[0].data), int(s.levels[0].at))
		testing.expect_value(t, len(b.shapes.pending[1].data), int(hi - lo))
		testing.expect(t, b.shape_offsets[0] != b.shape_offsets[1])
	}
	b.shapes.capacity = 1 << 22
	clear(&b.shapes.pending)
	at := [2]u32{b.shape_offsets[0], b.shape_offsets[1]}
	_, ok = store_place(&b, {shapes = frame[:]})
	testing.expect(t, ok)
	testing.expect_value(t, len(b.shapes.pending), 0)
	testing.expect_value(t, b.shape_offsets[0], at[0])
	testing.expect_value(t, b.shape_offsets[1], at[1])
}

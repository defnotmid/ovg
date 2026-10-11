package ovg

import "core:hash"

GRADIENT_RAMP_WIDTH :: 256

// Caches the 256x1 ramp textures of multi-stop gradients. Ramps used in a
// frame survive into the next; anything unused for a whole frame is freed.
Gradient_Store :: struct {
	this_frame: map[u64]Image_Id,
	prev_frame: map[u64]Image_Id,
}

gradient_store_init :: proc(s: ^Gradient_Store, allocator := context.allocator) {
	s.this_frame = make(map[u64]Image_Id, allocator)
	s.prev_frame = make(map[u64]Image_Id, allocator)
}

gradient_store_destroy :: proc(s: ^Gradient_Store) {
	delete(s.this_frame)
	delete(s.prev_frame)
}

@(private)
gradient_key :: proc(g: Multi_Stop_Gradient) -> u64 {
	stops := g.stops
	tint := g.tint
	h := hash.fnv64a(([^]u8)(raw_data(stops))[:len(stops) * size_of(Gradient_Stop)])
	return hash.fnv64a(([^]u8)(&tint)[:size_of(tint)], h)
}

gradient_store_lookup_or_add :: proc(s: ^Gradient_Store, g: Multi_Stop_Gradient, images: ^Image_Store) -> (id: Image_Id, err: Error) {
	key := gradient_key(g)
	if cached, ok := s.prev_frame[key]; ok {
		delete_key(&s.prev_frame, key)
		s.this_frame[key] = cached
		return cached, nil
	}
	if cached, ok := s.this_frame[key]; ok {
		return cached, nil
	}
	id = image_store_alloc(images, {{.Repeat_Y}, GRADIENT_RAMP_WIDTH, 1, .RGBA8}) or_return
	ramp: [GRADIENT_RAMP_WIDTH * 4]u8
	gradient_synthesize(g, &ramp)
	image_store_update(images, id, image_source_rgba(ramp[:], GRADIENT_RAMP_WIDTH, 1), 0, 0) or_return
	s.this_frame[key] = id
	return id, nil
}

// Call after every rendered frame.
gradient_store_release_old :: proc(s: ^Gradient_Store, images: ^Image_Store) {
	for _, id in s.prev_frame {
		image_store_remove(images, id)
	}
	clear(&s.prev_frame)
	s.this_frame, s.prev_frame = s.prev_frame, s.this_frame
}

// Renders the gradient into a premultiplied RGBA8 ramp. Offsets outside the
// stop range pad with the first/last stop color.
gradient_synthesize :: proc "contextless" (g: Multi_Stop_Gradient, dest: ^[GRADIENT_RAMP_WIDTH * 4]u8) {
	dest^ = {}
	if len(g.stops) == 0 {
		return
	}
	tinted :: proc "contextless" (s: Gradient_Stop, tint: f32) -> Gradient_Stop {
		s := s
		s.color.a *= tint
		return s
	}
	first := tinted(g.stops[0], g.tint)
	if first.offset > 0 {
		gradient_span(dest, first.color, first.color, 0, first.offset)
	}
	for i in 0 ..< len(g.stops) - 1 {
		s0 := tinted(g.stops[i], g.tint)
		s1 := tinted(g.stops[i + 1], g.tint)
		if s0.offset > 1 {
			break
		}
		gradient_span(dest, s0.color, s1.color, s0.offset, s1.offset)
	}
	last := tinted(g.stops[len(g.stops) - 1], g.tint)
	if last.offset < 1 {
		gradient_span(dest, last.color, last.color, last.offset, 1)
	}
}

@(private)
gradient_span :: proc "contextless" (dest: ^[GRADIENT_RAMP_WIDTH * 4]u8, c0, c1: Color, offset0, offset1: f32) {
	o0 := clamp(offset0, 0, 1)
	o1 := clamp(offset1, 0, 1)
	s := int(o0 * GRADIENT_RAMP_WIDTH)
	e := int(o1 * GRADIENT_RAMP_WIDTH)
	if e <= s {
		return
	}
	// Interpolate in straight alpha and premultiply on write, so fades to
	// transparent don't wash out.
	steps := f32(e - s)
	for i in s ..< min(e, GRADIENT_RAMP_WIDTH) {
		t := f32(i - s) / steps
		r := c0.r + (c1.r - c0.r) * t
		g := c0.g + (c1.g - c0.g) * t
		b := c0.b + (c1.b - c0.b) * t
		a := c0.a + (c1.a - c0.a) * t
		dest[i * 4 + 0] = u8(clamp(r * a * 255, 0, 255))
		dest[i * 4 + 1] = u8(clamp(g * a * 255, 0, 255))
		dest[i * 4 + 2] = u8(clamp(b * a * 255, 0, 255))
		dest[i * 4 + 3] = u8(clamp(a * 255, 0, 255))
	}
}

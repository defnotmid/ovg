package ovg

import "core:math"
import "core:slice"
import "core:testing"

// feComponentTransfer, feMorphology, feTurbulence and lighting. Expected
// values are worked out by hand from the Filter Effects spec (and resvg,
// the reference renderer, where the spec leaves rounding open).

@(private = "file")
Fx2 :: struct {
	backend: Software_Backend,
	canvas:  Canvas,
}

@(private = "file")
fx2_open :: proc(s: ^Fx2) {
	software_backend_init(&s.backend)
	canvas_init(&s.canvas, software_backend(&s.backend))
	set_size(&s.canvas, 8, 8)
}

@(private = "file")
fx2_close :: proc(s: ^Fx2) {
	canvas_destroy(&s.canvas)
	software_backend_destroy(&s.backend)
}

@(private = "file")
row_image :: proc(s: ^Fx2, px: [][4]u8) -> Image_Id {
	id, _ := create_image(&s.canvas, image_source_rgba(slice.to_bytes(px), u32(len(px)), 1), {.Premultiplied})
	return id
}

@(private = "file")
row_pixels :: proc(s: ^Fx2, id: Image_Id, n: int) -> [][4]u8 {
	p := image_store_get(&s.canvas.images, id).image.pixels
	return slice.reinterpret([][4]u8, p)[:n]
}

@(test)
test_transfer_functions :: proc(t: ^testing.T) {
	values := []f32{0, 1, 0, 0.5, 1}
	tab := Transfer_Function{kind = .Table, first = 0, count = 2}
	disc := Transfer_Function{kind = .Discrete, first = 2, count = 3}
	lin := Transfer_Function{kind = .Linear, slope = 0.5, intercept = 0.25}
	gam := Transfer_Function{kind = .Gamma, amplitude = 2, exponent = 2, offset = 0.1}
	// Results are truncated to 8 bits (resvg).
	testing.expect_value(t, transfer_value(TRANSFER_IDENTITY, values, 0.5), 127)
	testing.expect_value(t, transfer_value(tab, values, 0.5), 127)
	testing.expect_value(t, transfer_value(tab, values, 1), 255)
	// Discrete [0, 0.5, 1]: 0.4 falls in the second step.
	testing.expect_value(t, transfer_value(disc, values, 0.4), 127)
	testing.expect_value(t, transfer_value(disc, values, 1), 255)
	testing.expect_value(t, transfer_value(lin, values, 1), 191)
	testing.expect_value(t, transfer_value(lin, values, 0), 63)
	// 2 * 0.5^2 + 0.1 = 0.6.
	testing.expect_value(t, transfer_value(gam, values, 0.5), 153)
	// Clamped.
	testing.expect_value(t, transfer_value(Transfer_Function{kind = .Linear, slope = 4}, values, 0.5), 255)
	// An empty table is the identity.
	testing.expect_value(t, transfer_value(Transfer_Function{kind = .Table}, values, 0.2), 51)

	// Through the filter: straight color in, premultiplied out.
	s: Fx2
	fx2_open(&s)
	defer fx2_close(&s)
	funcs := [4]Transfer_Function{lin, TRANSFER_IDENTITY, Transfer_Function{kind = .Linear, slope = 0, intercept = 1}, TRANSFER_IDENTITY}
	lut := component_transfer_lut(funcs, values)
	lut_id, _ := create_image(&s.canvas, image_source_rgba(lut[:], 256, 1), {.Premultiplied, .Nearest})
	// Straight (200, 100, 50) at alpha 0.5.
	src := row_image(&s, {{100, 50, 25, 128}})
	dst := row_image(&s, {{}})
	filter_image(&s.canvas, dst, Component_Transfer{lut_id}, src)
	flush(&s.canvas)
	got := row_pixels(&s, dst, 1)[0]
	// R: 0.5 * 200/255 + 0.25 -> 163 straight; B -> 255; then * 128/255.
	want := [4]u8{82, 50, 128, 128}
	for k in 0 ..< 4 {
		testing.expectf(t, abs(int(got[k]) - int(want[k])) <= 1, "channel %d: got %v want %v", k, got, want)
	}
}

@(test)
test_morphology_radius :: proc(t: ^testing.T) {
	s: Fx2
	fx2_open(&s)
	defer fx2_close(&s)
	O :: [4]u8{255, 255, 255, 255}
	Z :: [4]u8{}
	dot := row_image(&s, {Z, Z, Z, O, Z, Z, Z, Z})
	dst := row_image(&s, make([][4]u8, 8, context.temp_allocator))
	filter_image(&s.canvas, dst, Morphology{{2, 0}, true, {0, 0, 8, 1}}, dot)
	flush(&s.canvas)
	got := row_pixels(&s, dst, 8)
	for x in 0 ..< 8 {
		want := O if x >= 1 && x <= 5 else Z
		testing.expectf(t, got[x] == want, "dilate x=%d: %v", x, got[x])
	}
	// Erode: pixels outside the valid rectangle don't count, so the
	// edges of a full row stay; the hole spreads by the radius.
	holed := row_image(&s, {O, O, O, O, O, O, Z, O})
	filter_image(&s.canvas, dst, Morphology{{1, 0}, false, {0, 0, 8, 1}}, holed)
	flush(&s.canvas)
	got = row_pixels(&s, dst, 8)
	for x in 0 ..< 8 {
		want := Z if x >= 5 else O
		testing.expectf(t, got[x] == want, "erode x=%d: %v", x, got[x])
	}
	// Radius 0 copies.
	filter_image(&s.canvas, dst, Morphology{{0, 0}, false, {0, 0, 8, 1}}, holed)
	flush(&s.canvas)
	got = row_pixels(&s, dst, 8)
	testing.expect(t, got[6] == Z && got[5] == O && got[7] == O)
}

@(test)
test_turbulence_reference :: proc(t: ^testing.T) {
	l := new(Turbulence_Lattice)
	defer free(l)
	// seed 0 becomes 1; random(1) = 16807, random(16807) = 282475249.
	turbulence_init(l, 0)
	g := [2]f64{f64(16807 % 512 - 256) / 256, f64(282475249 % 512 - 256) / 256}
	n := math.sqrt(g.x * g.x + g.y * g.y)
	testing.expect(t, abs(l.gradient[0][0][0] - g.x / n) < 1e-12 && abs(l.gradient[0][0][1] - g.y / n) < 1e-12)
	// The lattice is a permutation of 0..255, repeated.
	seen: [256]bool
	for i in 0 ..< 256 {
		seen[l.selector[i]] = true
		testing.expect(t, l.selector[i] == l.selector[i + 256])
	}
	for v in seen {
		testing.expect(t, v)
	}
	tp := Turbulence_Params{base_frequency = {1, 1}, octaves = 1}
	// Noise vanishes on lattice points.
	testing.expect(t, abs(turbulence(l, tp, {3, 7}, {})[0]) < 1e-12)
	// Halfway between lattice points the s-curve weights are 1/2: the
	// mean of the four corner gradients dotted with (+-1/2, +-1/2).
	p := [2]f64{0.5, 0.5}
	bx := (0x1000) & 0xff
	i, j := l.selector[bx], l.selector[bx + 1]
	q := &l.gradient[2]
	b00, b10, b01, b11 := l.selector[i + i32(bx)], l.selector[j + i32(bx)], l.selector[i + i32(bx) + 1], l.selector[j + i32(bx) + 1]
	want := 0.25 * ((0.5 * q[b00][0] + 0.5 * q[b00][1]) + (-0.5 * q[b10][0] + 0.5 * q[b10][1]) + (0.5 * q[b01][0] - 0.5 * q[b01][1]) + (-0.5 * q[b11][0] - 0.5 * q[b11][1]))
	tp.fractal_noise = true
	testing.expect(t, abs(turbulence(l, tp, p, {})[2] - want) < 1e-12)
	// Turbulence sums |noise|, halving per octave.
	tp.fractal_noise = false
	tp.octaves = 2
	two := turbulence(l, tp, p, {})[2]
	tp.octaves = 1
	one := turbulence(l, tp, p, {})[2]
	tp.octaves = 1
	testing.expect(t, abs(one - abs(want)) < 1e-12 && two >= one)
}

@(test)
test_lighting_normals :: proc(t: ^testing.T) {
	// A ramp of 0.1 per pixel: the spec's Sobel normal is twice the slope
	// everywhere, edges included.
	ramp := [3][3]f32{{0, 0.1, 0.2}, {0, 0.1, 0.2}, {0, 0.1, 0.2}}
	g := lighting_gradient(ramp, true, true, true, true)
	testing.expect(t, abs(g.x - 0.2) < 1e-6 && abs(g.y) < 1e-6)
	g = lighting_gradient(ramp, false, true, false, true)
	testing.expect(t, abs(g.x - 0.2) < 1e-6 && abs(g.y) < 1e-6)
	// Top-left corner kernel on an uneven patch (resvg's top_left_normal:
	// 2/3 (-2c + 2r - b + br), 2/3 (-2c - r + 2b + br)).
	a := [3][3]f32{{0, 0, 0}, {0, 0.2, 0.5}, {0, 0.9, 0.4}}
	g = lighting_gradient(a, false, true, false, true)
	c, r, b, br := f32(0.2), f32(0.5), f32(0.9), f32(0.4)
	testing.expect(t, abs(g.x - 2.0 / 3 * (-2 * c + 2 * r - b + br)) < 1e-6)
	testing.expect(t, abs(g.y - 2.0 / 3 * (-2 * c - r + 2 * b + br)) < 1e-6)
	// Interior Sobel.
	a = {{0.1, 0.3, 0.2}, {0.4, 0.5, 0.9}, {0.0, 0.6, 0.8}}
	g = lighting_gradient(a, true, true, true, true)
	testing.expect(t, abs(g.x - 0.25 * (-0.1 + 0.2 - 2 * 0.4 + 2 * 0.9 - 0.0 + 0.8)) < 1e-6)
	testing.expect(t, abs(g.y - 0.25 * (-0.1 - 2 * 0.3 - 0.2 + 0.0 + 2 * 0.6 + 0.8)) < 1e-6)

	// A flat surface lit from straight above: full diffuse and specular.
	flat: [3][3]f32
	l := Lighting{light = .Distant, color = {1, 0.5, 0}, surface_scale = 1, constant = 1, specular_exponent = 1, position = {0, 0, 1}, cone_cos = -2}
	px := lighting_pixel(l, flat, true, true, true, true, 0, 0)
	testing.expect(t, px == [4]f32{1, 128.0 / 255, 0, 1})
	l.specular = true
	px = lighting_pixel(l, flat, true, true, true, true, 0, 0)
	testing.expect(t, px == [4]f32{1, 128.0 / 255, 0, 1})
	// At 60 degrees elevation diffuse is sin(60).
	l.specular = false
	l.color = 1
	el := f32(math.PI / 3)
	l.position = {math.cos(el), 0, math.sin(el)}
	px = lighting_pixel(l, flat, true, true, true, true, 0, 0)
	testing.expect_value(t, u8(px.r * 255 + 0.5), u8(math.floor(255 * math.sin(el) + 0.5)))
	// A spot light pointing away leaves the surface black.
	l.light = .Spot
	l.position = {0, 0, 10}
	l.points_at = {0, 0, 20}
	l.spot_exponent = 1
	px = lighting_pixel(l, flat, true, true, true, true, 0, 0)
	testing.expect(t, px.rgb == 0)
}

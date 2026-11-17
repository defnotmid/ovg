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
}

// Lighting through the filter unit on the software backend: the normal is
// the spec's Sobel kernels, its edge kernels where a neighbour is outside
// the valid rectangle, and colours round to 8 bits as resvg rounds them.
@(test)
test_lighting_normals :: proc(t: ^testing.T) {
	s: Fx2
	fx2_open(&s)
	defer fx2_close(&s)
	lit :: proc(s: ^Fx2, l: Lighting, alphas: []u8) -> [][4]u8 {
		px := make([][4]u8, len(alphas), context.temp_allocator)
		for a, i in alphas {
			px[i] = {0, 0, 0, a}
		}
		src := row_image(s, px)
		dst := row_image(s, make([][4]u8, len(alphas), context.temp_allocator))
		l := l
		l.valid = {0, 0, f32(len(alphas)), 1}
		filter_image(&s.canvas, dst, l, src)
		flush(&s.canvas)
		return row_pixels(s, dst, len(alphas))
	}
	// A flat surface lit from straight above: full diffuse and specular.
	l := Lighting{light = .Distant, color = {1, 0.5, 0}, surface_scale = 1, constant = 1, specular_exponent = 1, position = {0, 0, 1}, cone_cos = -2}
	flat := []u8{0, 0, 0}
	testing.expect_value(t, lit(&s, l, flat)[1], [4]u8{255, 128, 0, 255})
	l.specular = true
	testing.expect_value(t, lit(&s, l, flat)[1], [4]u8{255, 128, 0, 255})
	// A ramp of 26/255 a pixel, lit from above: the interior kernel and
	// both edge kernels give the slope twice over, so every pixel is
	// 255 / sqrt(1 + (52/255)^2), 250.
	l.specular = false
	l.color = 1
	ramp := lit(&s, l, {0, 26, 52})
	for p, x in ramp {
		testing.expectf(t, p == {250, 250, 250, 255}, "ramp x=%d: %v", x, p)
	}
	// At 60 degrees elevation diffuse is sin(60).
	el := f32(math.PI / 3)
	l.position = {math.cos(el), 0, math.sin(el)}
	testing.expect_value(t, lit(&s, l, flat)[1].r, u8(math.floor(255 * math.sin(el) + 0.5)))
	// A spot light pointing away leaves the surface black.
	l.light = .Spot
	l.position = {0, 0, 10}
	l.points_at = {0, 0, 20}
	l.spot_exponent = 1
	testing.expect_value(t, lit(&s, l, flat)[1], [4]u8{0, 0, 0, 255})
}

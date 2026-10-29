package ovg

import "core:math"

// Filter inputs computed on the CPU and uploaded as images (the same bytes
// on every backend): feComponentTransfer lookup tables and the feTurbulence
// lattice. The noise itself is the Filter Effects spec's reference Perlin
// code: here in f64 (as resvg, so it matches resvg and browsers) for the
// software backend, in the GPU backends' shader in f32.

Transfer_Kind :: enum u8 {
	Identity,
	Table,
	Discrete,
	Linear,
	Gamma,
}

// One feFuncR/G/B/A. Table and Discrete read `count` values at `first` of
// `Filter.values` (none means identity, as resvg).
Transfer_Function :: struct {
	kind:      Transfer_Kind,
	first:     u16,
	count:     u16,
	slope:     f32,
	intercept: f32,
	amplitude: f32,
	exponent:  f32,
	offset:    f32,
}

TRANSFER_IDENTITY :: Transfer_Function{kind = .Identity, slope = 1, amplitude = 1, exponent = 1}

// The transfer function at `c` (0..1) as resvg's component_transfer.rs: the
// result clamped and truncated to 8 bits.
transfer_value :: proc "contextless" (fn: Transfer_Function, values: []f32, c: f32) -> u8 {
	v := c
	table := values[min(int(fn.first), len(values)):][:min(int(fn.count), max(len(values) - int(fn.first), 0))]
	switch fn.kind {
	case .Identity:
	case .Table:
		if len(table) > 0 {
			n := len(table) - 1
			k := min(int(math.floor(c * f32(n))), n)
			if k == n {
				v = table[k]
			} else {
				v = table[k] + (c - f32(k) / f32(n)) * f32(n) * (table[k + 1] - table[k])
			}
		}
	case .Discrete:
		if len(table) > 0 {
			n := len(table)
			v = table[min(int(math.floor(c * f32(n))), n - 1)]
		}
	case .Linear:
		v = fn.slope * c + fn.intercept
	case .Gamma:
		v = fn.amplitude * math.pow(c, fn.exponent) + fn.offset
	}
	return u8(clamp(v, 0, 1) * 255)
}

// The 256 x 1 RGBA8 lookup table of a `Component_Transfer` filter.
component_transfer_lut :: proc "contextless" (funcs: [4]Transfer_Function, values: []f32) -> (lut: [256 * 4]u8) {
	for i in 0 ..< 256 {
		for k in 0 ..< 4 {
			lut[i * 4 + k] = transfer_value(funcs[k], values, f32(i) / 255)
		}
	}
	return
}

// ---- feTurbulence ----------------------------------------------------------------------

@(private = "file")
TURB_B :: 0x100
@(private = "file")
TURB_BM :: 0xff
@(private = "file")
TURB_PERLIN_N :: 0x1000
@(private = "file")
RAND_M :: 2147483647
@(private = "file")
RAND_A :: 16807
@(private = "file")
RAND_Q :: 127773
@(private = "file")
RAND_R :: 2836

// The spec's lattice: permutation and per-channel unit gradients.
Turbulence_Lattice :: struct {
	selector: [TURB_B + TURB_B + 2]i32,
	gradient: [4][TURB_B + TURB_B + 2][2]f64,
}

@(private = "file")
turb_random :: #force_inline proc "contextless" (seed: i32) -> i32 {
	r := RAND_A * (seed % RAND_Q) - RAND_R * (seed / RAND_Q)
	return r + RAND_M if r <= 0 else r
}

turbulence_init :: proc "contextless" (lattice: ^Turbulence_Lattice, seed: i32) {
	seed := seed
	if seed <= 0 {
		seed = -(seed % (RAND_M - 1)) + 1
	}
	if seed > RAND_M - 1 {
		seed = RAND_M - 1
	}
	for k in 0 ..< 4 {
		for i in 0 ..< TURB_B {
			lattice.selector[i] = i32(i)
			for j in 0 ..< 2 {
				seed = turb_random(seed)
				lattice.gradient[k][i][j] = f64((seed % (TURB_B + TURB_B)) - TURB_B) / TURB_B
			}
			g := &lattice.gradient[k][i]
			s := math.sqrt(g[0] * g[0] + g[1] * g[1])
			g[0] /= s
			g[1] /= s
		}
	}
	for i := TURB_B - 1; i > 0; i -= 1 {
		k := lattice.selector[i]
		seed = turb_random(seed)
		j := seed % TURB_B
		lattice.selector[i] = lattice.selector[j]
		lattice.selector[j] = k
	}
	for i in 0 ..< TURB_B + 2 {
		lattice.selector[TURB_B + i] = lattice.selector[i]
		for k in 0 ..< 4 {
			lattice.gradient[k][TURB_B + i] = lattice.gradient[k][i]
		}
	}
}

// The lattice image a `Turbulence` filter reads on the GPU (RGBA8). Row 0
// holds the permutation (in red); row 1 + k channel k's gradients as 16-bit
// fixed point, round((g + 1) / 2 * 65535), bytes x high, x low, y high,
// y low (an error under 2e-5, far below 8-bit output). The spec's tables
// repeat with period 256, so 256 entries are all a shader needs.
TURBULENCE_LATTICE_W :: 256
TURBULENCE_LATTICE_H :: 5

turbulence_lattice_pixels :: proc "contextless" (seed: i32) -> (px: [TURBULENCE_LATTICE_W * TURBULENCE_LATTICE_H * 4]u8) {
	l: Turbulence_Lattice
	turbulence_init(&l, seed)
	for i in 0 ..< TURB_B {
		px[i * 4] = u8(l.selector[i])
		px[i * 4 + 3] = 255
		for k in 0 ..< 4 {
			o := px[((k + 1) * TURB_B + i) * 4:]
			for j in 0 ..< 2 {
				q := u16(math.round((l.gradient[k][i][j] + 1) * 32767.5))
				o[j * 2] = u8(q >> 8)
				o[j * 2 + 1] = u8(q)
			}
		}
	}
	return
}

@(private = "file")
Stitch :: struct {
	width, height, wrap_x, wrap_y: i32,
}

// The spec's noise2 for all four channels (they share the lattice cell).
// Indices are masked to 0..255 before every lookup, which stays inside the
// 514-entry tables.
@(private = "file")
noise2 :: #force_inline proc "contextless" (l: ^Turbulence_Lattice, x, y: f64, stitch: ^Stitch) -> (n: [4]f64) #no_bounds_check {
	s_curve :: #force_inline proc "contextless" (t: f64) -> f64 {return t * t * (3 - 2 * t)}
	lerp :: #force_inline proc "contextless" (t, a, b: f64) -> f64 {return a + t * (b - a)}
	t := x + TURB_PERLIN_N
	bx0 := i32(t)
	bx1 := bx0 + 1
	rx0 := t - f64(i64(t))
	rx1 := rx0 - 1
	t = y + TURB_PERLIN_N
	by0 := i32(t)
	by1 := by0 + 1
	ry0 := t - f64(i64(t))
	ry1 := ry0 - 1
	if stitch != nil {
		if bx0 >= stitch.wrap_x {bx0 -= stitch.width}
		if bx1 >= stitch.wrap_x {bx1 -= stitch.width}
		if by0 >= stitch.wrap_y {by0 -= stitch.height}
		if by1 >= stitch.wrap_y {by1 -= stitch.height}
	}
	bx0 &= TURB_BM
	bx1 &= TURB_BM
	by0 &= TURB_BM
	by1 &= TURB_BM
	i := l.selector[bx0]
	j := l.selector[bx1]
	b00 := l.selector[i + by0]
	b10 := l.selector[j + by0]
	b01 := l.selector[i + by1]
	b11 := l.selector[j + by1]
	sx := s_curve(rx0)
	sy := s_curve(ry0)
	for k in 0 ..< 4 {
		g := &l.gradient[k]
		u := rx0 * g[b00][0] + ry0 * g[b00][1]
		v := rx1 * g[b10][0] + ry0 * g[b10][1]
		a := lerp(sx, u, v)
		u = rx0 * g[b01][0] + ry1 * g[b01][1]
		v = rx1 * g[b11][0] + ry1 * g[b11][1]
		b := lerp(sx, u, v)
		n[k] = lerp(sy, a, b)
	}
	return
}

// feTurbulence parameters (base frequencies per user unit).
Turbulence_Params :: struct {
	base_frequency: [2]f64,
	octaves:        u32,
	fractal_noise:  bool,
	stitch:         bool,
}

// The frequencies turbulence runs at and, when stitching, the stitch tile
// size in lattice cells: the spec adjusts the base frequency so a whole
// number of cells spans the tile (`tile` width and height).
turbulence_frequency :: proc "contextless" (tp: Turbulence_Params, tile: [2]f64) -> (freq: [2]f64, cells: [2]i32) {
	freq = tp.base_frequency
	if !tp.stitch {
		return
	}
	for a in 0 ..< 2 {
		if freq[a] != 0 {
			lo := math.floor(tile[a] * freq[a]) / tile[a]
			hi := math.ceil(tile[a] * freq[a]) / tile[a]
			freq[a] = lo if freq[a] / lo < hi / freq[a] else hi
		}
		cells[a] = i32(tile[a] * freq[a] + 0.5)
	}
	return
}

// The octave sum at user-space `p` for frequencies `freq` (see
// `turbulence_frequency`); `origin` is the stitching tile's origin.
@(private = "file")
turbulence_sum :: #force_inline proc "contextless" (l: ^Turbulence_Lattice, tp: Turbulence_Params, freq: [2]f64, cells: [2]i32, p, origin: [2]f64) -> (sum: [4]f64) {
	st: Stitch
	stitch: ^Stitch
	if tp.stitch {
		st.width = cells.x
		st.height = cells.y
		st.wrap_x = i32(origin.x * freq.x + TURB_PERLIN_N + f64(st.width))
		st.wrap_y = i32(origin.y * freq.y + TURB_PERLIN_N + f64(st.height))
		stitch = &st
	}
	x, y := p.x * freq.x, p.y * freq.y
	ratio := 1.0
	for _ in 0 ..< tp.octaves {
		n := noise2(l, x, y, stitch)
		for k in 0 ..< 4 {
			sum[k] += (n[k] if tp.fractal_noise else abs(n[k])) / ratio
		}
		x *= 2
		y *= 2
		ratio *= 2
		if stitch != nil {
			st.width *= 2
			st.wrap_x = 2 * st.wrap_x - TURB_PERLIN_N
			st.height *= 2
			st.wrap_y = 2 * st.wrap_y - TURB_PERLIN_N
		}
	}
	return
}

// The spec's turbulence(channel, point) for the four channels at user-space
// `p`; `tile` is the stitching tile (x, y, w, h), as resvg passes it.
turbulence :: proc "contextless" (l: ^Turbulence_Lattice, tp: Turbulence_Params, p: [2]f64, tile: [4]f64) -> [4]f64 {
	freq, cells := turbulence_frequency(tp, {tile[2], tile[3]})
	return turbulence_sum(l, tp, freq, cells, p, {tile[0], tile[1]})
}

// Fills rows y0 ..< y1 of `out` (w x h, premultiplied: RGBA8 rounded as
// resvg's apply_turbulence, or RGBA16F unrounded if `half`) with `t`: pixel
// (x, y) is user point ((x + offset.x) / scale.x, (y + offset.y) /
// scale.y); the stitching tile is `t.region`.
turbulence_fill :: proc "contextless" (out: []u8, w, h: int, t: Turbulence, l: ^Turbulence_Lattice, y0, y1: int, $half: bool) {
	tp, region := t.params, t.region
	freq, cells := turbulence_frequency(tp, {region[2], region[3]})
	if len(out) < w * h * (8 if half else 4) || y0 < 0 || y1 > h {
		return
	}
	for y in y0 ..< y1 {
		for x in 0 ..< w {
			p := [2]f64{(f64(x) + t.offset.x) / t.scale.x, (f64(y) + t.offset.y) / t.scale.y}
			// resvg passes the pixel's place in the region as the tile origin.
			n := turbulence_sum(l, tp, freq, cells, p, {f64(x) - region[0], f64(y) - region[1]})
			when half {
				// RGBA16F: the noise unrounded, premultiplied.
				c: [4]f32
				for k in 0 ..< 4 {
					c[k] = clamp(f32((n[k] + 1) / 2 if tp.fractal_noise else n[k]), 0, 1)
				}
				#no_bounds_check {
					(^[4]f16)(&out[(y * w + x) * 8])^ = {f16(c[0] * c[3]), f16(c[1] * c[3]), f16(c[2] * c[3]), f16(c[3])}
				}
				continue
			}
			px: [4]u8
			for k in 0 ..< 4 {
				v := (n[k] * 255 + 255) / 2 if tp.fractal_noise else n[k] * 255
				px[k] = u8(clamp(f32(v), 0, 255) + 0.5)
			}
			// Premultiply as resvg's multiply_alpha.
			a := f32(px[3]) / 255
			#no_bounds_check {
				o := out[(y * w + x) * 4:]
				for k in 0 ..< 3 {
					o[k] = u8(f32(px[k]) * a + 0.5)
				}
				o[3] = px[3]
			}
		}
	}
}

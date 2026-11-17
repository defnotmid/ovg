package ovg

import "core:math"

// Filter inputs computed on the CPU and uploaded as images (the same bytes
// on every backend): feComponentTransfer lookup tables and the feTurbulence
// lattice. The noise itself is the Filter Effects spec's reference Perlin
// code, in the filter shader (shaders/filter.frag) in f32.

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

// The lattice image a `Turbulence` filter reads (RGBA16F, whole numbers,
// which a half holds exactly, so the shader reads them with no decode).
// Row 0 holds the permutation (in red); row 1 + k channel k's gradients as
// 16-bit fixed point q = round((g + 1) / 2 * 65535), x as (q &~ 255, q &
// 255) and y the same (an error under 2e-5, far below 8-bit output). The
// spec's tables repeat with period 256, so 256 entries are all a shader
// needs.
TURBULENCE_LATTICE_W :: 256
TURBULENCE_LATTICE_H :: 5

turbulence_lattice_pixels :: proc "contextless" (seed: i32) -> (px: [TURBULENCE_LATTICE_W * TURBULENCE_LATTICE_H][4]f16) {
	l: Turbulence_Lattice
	turbulence_init(&l, seed)
	for i in 0 ..< TURB_B {
		px[i] = {f16(l.selector[i]), 0, 0, 1}
		for k in 0 ..< 4 {
			o := &px[(k + 1) * TURB_B + i]
			for j in 0 ..< 2 {
				q := u16(math.round((l.gradient[k][i][j] + 1) * 32767.5))
				o[j * 2] = f16(q &~ 255)
				o[j * 2 + 1] = f16(q & 255)
			}
		}
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

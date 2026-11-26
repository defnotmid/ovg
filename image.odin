package ovg

import "base:runtime"
import "core:math"
import "core:simd"
import "core:slice"

Pixel_Format :: enum u8 {
	// From 1: zero is no format, so a source left unset matches no image.
	RGBA8 = 1,
	Gray8,
	// 16-bit single channel (little-endian u16, sampled as value / 65535):
	// deep planes, e.g. 10- and 12-bit video, for custom programs.
	Gray16,
	// Half-float RGBA (four f16 per pixel), stored and sampled unclamped:
	// for custom program targets and channels (feedback buffers), and
	// offscreen images that keep more than 8 bits (`layer_image_begin`).
	RGBA16F,
}

bytes_per_pixel :: proc "contextless" (f: Pixel_Format) -> u32 {
	switch f {
	case .RGBA8:
		return 4
	case .Gray8:
		return 1
	case .Gray16:
		return 2
	case .RGBA16F:
		return 8
	}
	return 4
}

Image_Flag :: enum u32 {
	// Minified, sample a chain of smaller levels (image_levels_build) built
	// from each upload, blended between the two the minification picks, so
	// each pixel averages the texels it covers instead of aliasing. Every
	// backend builds the levels alike on the CPU, so such an image takes
	// whole updates only (.Unsupported_Operation otherwise) and is never a
	// render target.
	Generate_Mipmaps,
	Repeat_X,
	Repeat_Y,
	// Sample the image upside down.
	Flip_Y,
	// RGBA8 pixels are already premultiplied by alpha.
	Premultiplied,
	// Nearest-neighbour sampling instead of bilinear.
	Nearest,
	// Contents last through one render: they are undefined when a render
	// starts, so each frame clears or overwrites the image before reading
	// it, and nothing writes or reads it between renders (an update or a
	// read is an error). A backend may drop the contents between renders:
	// the software backend lends such images their pixels for one render, so
	// players sharing it hold one render's worth between them.
	Transient,
}
Image_Flags :: bit_set[Image_Flag;u32]

// Borrowed pixel data for an upload. `row_stride == 0` means tightly packed.
Image_Source :: struct {
	format:     Pixel_Format,
	data:       []u8,
	width:      u32,
	height:     u32,
	row_stride: u32,
}

image_source_rgba :: proc "contextless" (data: []u8, width, height: u32) -> Image_Source {
	return {.RGBA8, data, width, height, 0}
}

image_source_gray :: proc "contextless" (data: []u8, width, height: u32) -> Image_Source {
	return {.Gray8, data, width, height, 0}
}

image_source_gray16 :: proc "contextless" (data: []u8, width, height: u32) -> Image_Source {
	return {.Gray16, data, width, height, 0}
}

image_source_stride :: proc "contextless" (s: Image_Source) -> u32 {
	return s.row_stride if s.row_stride != 0 else s.width * bytes_per_pixel(s.format)
}

Image_Info :: struct {
	flags:  Image_Flags,
	width:  u32,
	height: u32,
	format: Pixel_Format,
}

// Handle to a canvas image. The zero value is "no image".
Image_Id :: struct {
	key: Key,
}

image_id_valid :: #force_inline proc "contextless" (id: Image_Id) -> bool {
	return id.key.gen != 0
}

// ---- image filters ------------------------------------------------------------------
//
// Filters are recorded by `filter_image` and run in order at flush. They read
// and write premultiplied images of one size (Gray8 and Gray16 sources are
// read as GPU samplers return them, see `tex_type_for`). The target may be one
// of the inputs. Color math follows SVG 1.1 Filter Effects / W3C Compositing:
// matrices and blend functions act on straight (unpremultiplied) color in
// whatever space the pixels are in; convert with `Color_Space_Convert` for
// SVG's default linearRGB filter space.

// What a blur reads beyond the image: transparent black (SVG) or the edge
// pixels.
Blur_Edge :: enum u8 {
	Transparent,
	Clamp,
}

// SVG feGaussianBlur with one standard deviation (pixels) for both axes and
// transparent black beyond the image. The kernel spans 3 sigma each side,
// exact up to BLUR_MAX_EXACT_SIGMA; wider blurs keep BLUR_MAX_TAPS taps each
// side (a truncated, renormalized kernel) on every backend, so blur a
// downscaled copy for those. Sigma <= 0 copies the image.
Gaussian_Blur :: struct {
	sigma: f32,
}

// feGaussianBlur with stdDeviation="x y": one sigma per axis (<= 0 leaves
// that axis untouched) and a choice of edge handling.
Blur_XY :: struct {
	sigma_x: f32,
	sigma_y: f32,
	edge:    Blur_Edge,
}

BLUR_MAX_EXACT_SIGMA :: 8
BLUR_MAX_TAPS :: 24

// The axis sigmas and edge mode of either blur filter.
blur_params :: proc "contextless" (f: Image_Filter) -> (sigma_x, sigma_y: f32, edge: Blur_Edge, ok: bool) {
	#partial switch v in f {
	case Gaussian_Blur:
		return v.sigma, v.sigma, .Transparent, true
	case Blur_XY:
		return v.sigma_x, v.sigma_y, v.edge, true
	}
	return
}

// The incremental gaussian coefficients both backends use for one pass:
// (g0, exp(-1/(2 s^2)), its square), the number of taps each side, and the
// sigma used for them (0 means "copy").
blur_pass_coefficients :: proc "contextless" (sigma: f32) -> (coeff: [3]f32, taps: int) {
	if !(sigma > 0) || math.is_inf(sigma) {
		// Zero, negative, NaN or infinite: leave the image unchanged.
		return {1, 0, 0}, 0
	}
	g1 := math.exp(-0.5 / (sigma * sigma))
	coeff = {1 / (math.sqrt(f32(2 * math.PI)) * sigma), g1, g1 * g1}
	taps = min(int(math.ceil(3 * min(sigma, BLUR_MAX_EXACT_SIGMA))), BLUR_MAX_TAPS)
	return
}

// Bloom (`.Bloom` in a filter, `layer_bloom_into`): the source's light above
// `threshold` per channel, its alpha too, per pixel of it, into a target half its
// size. `encoded`: the source is sRGB-encoded, its light read linear.
Bloom_Bright :: struct {
	threshold: f32,
	encoded:   bool,
}

// The source plus `intensity` of the glow, read bilinearly at (x, y) * uv.xy + uv.zw
// (the pixel's centre, in the target's pixels) so that it can be smaller, in
// linear light. `encoded`: the source and the target are sRGB-encoded.
Bloom_Add :: struct {
	glow:      Image_Id,
	intensity: f32,
	uv:        [4]f32,
	encoded:   bool,
}

// SVG feColorMatrix: rows R, G, B, A of [r g b a 1] coefficients (the fifth
// column is an offset in 0..1 units), applied to straight color, clamped,
// then premultiplied.
Color_Matrix :: struct {
	m: [20]f32,
}

COLOR_MATRIX_IDENTITY :: Color_Matrix{{1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0}}

// feColorMatrix type="saturate" (0 = grey, 1 = unchanged).
color_matrix_saturate :: proc "contextless" (s: f32) -> Color_Matrix {
	return {
		{
			0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0,
			0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0,
			0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0,
			0, 0, 0, 1, 0,
		},
	}
}

// feColorMatrix type="hueRotate", in degrees.
color_matrix_hue_rotate :: proc "contextless" (degrees: f32) -> Color_Matrix {
	a := degrees * math.PI / 180
	c, s := math.cos(a), math.sin(a)
	return {
		{
			0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0, 0,
			0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0, 0,
			0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0, 0,
			0, 0, 0, 1, 0,
		},
	}
}

// The luminance a luminance mask counts by: SVG's and CSS's Rec. 709
// weights (0.2125, 0.7154, 0.0721, as feColorMatrix luminanceToAlpha) or
// PDF's soft masks' (0.30, 0.59, 0.11, its non-separable blend modes').
Mask_Luminance :: enum u8 {
	Rec709,
	Pdf,
}

// feColorMatrix type="luminanceToAlpha": black with the luminance as alpha.
color_matrix_luminance_to_alpha :: proc "contextless" () -> Color_Matrix {
	return {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.2125, 0.7154, 0.0721, 0, 0}}
}

// Converts straight color between sRGB and linearRGB (SVG
// color-interpolation-filters), keeping alpha.
Color_Space_Convert :: struct {
	to_linear: bool,
}

// W3C Compositing and Blending Level 1 blend modes.
Blend_Mode :: enum u8 {
	Normal,
	Multiply,
	Screen,
	Overlay,
	Darken,
	Lighten,
	Color_Dodge,
	Color_Burn,
	Hard_Light,
	Soft_Light,
	Difference,
	Exclusion,
	Hue,
	Saturation,
	Color,
	Luminosity,
}

// SVG feBlend / CSS mix-blend-mode: the filter's source (in) blended onto
// `backdrop` (in2) and composited source-over:
// co = cs (1 - ab) + cb (1 - as) + as ab B(Cb, Cs), ao = as + ab - as ab.
Blend :: struct {
	mode:     Blend_Mode,
	backdrop: Image_Id,
}

// SVG feComposite operators (`Lighter` is SVG 2's).
Composite_Operator :: enum u8 {
	Over,
	In,
	Out,
	Atop,
	Xor,
	Lighter,
	Arithmetic,
}

// SVG feComposite of the filter's source (in) with `backdrop` (in2), on
// premultiplied color. Arithmetic is k1 i1 i2 + k2 i1 + k3 i2 + k4 per
// channel, clamped to [0, 1] with color clamped to alpha.
Composite :: struct {
	op:       Composite_Operator,
	k:        [4]f32,
	backdrop: Image_Id,
}

// The neighbourhood filters below (morphology, lighting, convolution,
// displacement) see only the pixels inside `valid` (x0, y0, x1, y1 in
// image pixels, typically the SVG filter region): it plays the role of the
// image edge of the Filter Effects spec, as resvg crops each input to the
// region.

// SVG feComponentTransfer: each straight channel c (0..255) becomes
// lut[c] (the R, G, B, A of `lut`'s pixel c), then premultiplied. `lut` is a
// 256 x 1 RGBA8 image (see `component_transfer_lut`), it need not match the
// source's size.
Component_Transfer :: struct {
	lut: Image_Id,
}

// SVG feMorphology: per premultiplied channel, the minimum (erode) or
// maximum (dilate) over a (2 rx + 1) x (2 ry + 1) box (at most
// MORPHOLOGY_MAX_RADIUS), run as two separable passes. A fractional radius
// blends in the next ring of pixels by its fraction, so animated radii move
// smoothly instead of stepping a whole pixel at a time.
Morphology :: struct {
	radius: [2]f32,
	dilate: bool,
	valid:  [4]f32,
}

MORPHOLOGY_MAX_RADIUS :: 256

Light_Kind :: enum u8 {
	Distant,
	Point,
	Spot,
}

// SVG feDiffuseLighting / feSpecularLighting over the source's alpha
// (surface normals from the spec's Sobel kernels, edge kernels at `valid`'s
// border), lit by one light. Positions are in image pixels (z in the same
// scale); `color` is used as given (no color space conversion), as resvg.
// Diffuse writes opaque color, specular color with alpha max(r, g, b).
Lighting :: struct {
	specular:          bool,
	light:             Light_Kind,
	color:             [3]f32,
	surface_scale:     f32,
	// kd (diffuse) or ks (specular).
	constant:          f32,
	specular_exponent: f32,
	// Distant: the unit direction to the light; point / spot: the position.
	position:          [3]f32,
	points_at:         [3]f32,
	spot_exponent:     f32,
	// cos(limitingConeAngle), or -2 for no cone.
	cone_cos:          f32,
	valid:             [4]f32,
}

// SVG feTile: the tile `rect` (x, y, w, h in whole image pixels) of the
// source repeated over the whole image.
Tile :: struct {
	rect: [4]f32,
}

// SVG feDisplacementMap: out(p) = in(p + scale * (map channel - 0.5)),
// rounded to whole pixels; transparent where that falls outside `valid`.
// `channels` select R, G, B, A (0..3) of the (premultiplied) map for x, y.
Displacement_Map :: struct {
	displacement: Image_Id,
	scale:        [2]f32,
	channels:     [2]u8,
	valid:        [4]f32,
}

// SVG feConvolveMatrix with at most CONVOLVE_MAX_KERNEL entries (row-major,
// as written; the spec's flip happens in the filter). `edge`: 0 duplicate,
// 1 wrap, 2 none.
Convolve_Matrix :: struct {
	kernel:         [CONVOLVE_MAX_KERNEL]f32,
	order:          [2]i32,
	target:         [2]i32,
	divisor:        f32,
	bias:           f32,
	edge:           u8,
	preserve_alpha: bool,
	valid:          [4]f32,
}

CONVOLVE_MAX_KERNEL :: 36

// SVG feTurbulence (the spec's reference noise) over the whole target; the
// filter's source is the lattice image of its seed (see
// `turbulence_lattice_pixels`). Target pixel (x, y) is user point
// ((x + offset.x) / scale.x, (y + offset.y) / scale.y); `region` (x, y, w,
// h in target pixels) is the stitching tile. Every backend evaluates it in
// f32 from the lattice image (shaders/filter.frag).
Turbulence :: struct {
	params: Turbulence_Params,
	offset: [2]f64,
	scale:  [2]f64,
	region: [4]f64,
}

Image_Filter :: union {
	Gaussian_Blur,
	Blur_XY,
	Color_Matrix,
	Color_Space_Convert,
	Blend,
	Composite,
	Component_Transfer,
	Morphology,
	Lighting,
	Tile,
	Displacement_Map,
	Convolve_Matrix,
	Turbulence,
	Bloom_Bright,
	Bloom_Add,
}

// Filters run as two passes through an intermediate image (besides blurs).
filter_two_pass :: proc "contextless" (f: Image_Filter) -> bool {
	_, ok := f.(Morphology)
	return ok
}

// The second input of a two-input filter (zero for one-input filters).
// Only Blend, Composite and Displacement_Map need it the source's size.
filter_backdrop :: proc "contextless" (f: Image_Filter) -> Image_Id {
	#partial switch v in f {
	case Blend:
		return v.backdrop
	case Composite:
		return v.backdrop
	case Component_Transfer:
		return v.lut
	case Displacement_Map:
		return v.displacement
	case Bloom_Add:
		return v.glow
	}
	return {}
}

// One pass of an image filter as every backend draws it with the filter
// unit (shaders/filter.frag): a quad over the whole of its output, reading
// `tex` (the filter's source, or the intermediate) and `glyphtex` (the
// backdrop) through `paint`, a paint row as `pack_frag_uniforms` packs one.
// `from_mid` reads the intermediate for the source, `to_mid` writes it for
// the target.
Filter_Pass :: struct {
	paint:    [14][4]f32,
	from_mid: bool,
	to_mid:   bool,
}

// A filter's passes. Blurs and morphology run two through an intermediate
// the source's size and format; a one-pass filter whose target is also an
// input (`aliased`) draws into an intermediate the target's size and
// format, then `copy`s it to the target. Not ok: the images don't fit the
// filter, and nothing draws. `back` is the backdrop's info when it has one.
Filter_Plan :: struct {
	passes: [2]Filter_Pass,
	count:  int,
	copy:   bool,
}

filter_plan :: proc "contextless" (filter: Image_Filter, src, dst: Image_Info, back: Maybe(Image_Info), aliased: bool) -> (plan: Filter_Plan, ok: bool) {
	extent := [2]f32{f32(src.width), f32(src.height)}
	gray := src.format == .Gray8 || src.format == .Gray16
	if t, is_turbulence := filter.(Turbulence); is_turbulence {
		// The source is the lattice image, not the target's size.
		frag := turbulence_uniforms(t, dst.format == .RGBA16F)
		frag[9] = {f32(dst.width), f32(dst.height), 0, 0}
		frag[10] = {0, 0, 0, f32(Shader_Type.Filter_Turbulence)}
		plan.passes[0].paint = frag
		plan.count = 1
		return plan, true
	}
	_, is_bright := filter.(Bloom_Bright)
	if !is_bright && (src.width != dst.width || src.height != dst.height) {
		return {}, false
	}

	if sx, sy, edge, is_blur := blur_params(filter); is_blur {
		dirs := [2][2]f32{{1, 0}, {0, 1}}
		sigmas := [2]f32{sx, sy}
		// The intermediate already holds premultiplied color.
		tts := [2]f32{tex_type_for(src), 2 if gray else 0}
		for k in 0 ..< 2 {
			coeff, taps := blur_pass_coefficients(sigmas[k])
			params := default_params()
			params.shader_type = .Filter_Image
			params.extent = extent
			params.paint_mat = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0}
			params.image_blur_filter_coeff = coeff
			params.image_blur_filter_taps = f32(taps)
			params.image_blur_filter_edge = f32(edge)
			params.image_blur_filter_direction = dirs[k]
			params.tex_type = tts[k]
			plan.passes[k] = {pack_frag_uniforms(params), k == 1, k == 0}
		}
		plan.count = 2
		return plan, true
	}

	if m, is_morph := filter.(Morphology); is_morph {
		tts := [2]f32{tex_type_for(src), 2 if gray else 0}
		for axis in 0 ..< 2 {
			frag: [14][4]f32
			frag[0] = {m.radius[axis], 1 if m.dilate else 0, f32(axis), 0}
			frag[9] = {extent.x, extent.y, m.valid[0], m.valid[1]}
			frag[10] = {m.valid[2], m.valid[3], tts[axis], f32(Shader_Type.Filter_Morphology)}
			plan.passes[axis] = {frag, axis == 1, axis == 0}
		}
		plan.count = 2
		return plan, true
	}

	back_tt: f32
	if image_id_valid(filter_backdrop(filter)) {
		info, has_back := back.?
		_, is_lut := filter.(Component_Transfer)
		_, is_glow := filter.(Bloom_Add)
		if !has_back || (!is_lut && !is_glow && (info.width != src.width || info.height != src.height)) {
			return {}, false
		}
		back_tt = tex_type_for(info)
	}

	// Paint rows: frag[0..3] matrix rows, frag[4] offsets or k1..k4,
	// frag[9] = (extent, op), frag[10].zw = (tex type, shader type),
	// frag[13].x = the backdrop's tex type.
	frag: [14][4]f32
	frag[9] = {extent.x, extent.y, 0, 0}
	frag[10] = {0, 0, tex_type_for(src), 0}
	frag[13] = {back_tt, 0, 0, 0}
	set_valid :: proc "contextless" (frag: ^[14][4]f32, v: [4]f32) {
		frag[9].zw = v.xy
		frag[10].xy = v.zw
	}
	switch v in filter {
	case Color_Matrix:
		frag[10].w = f32(Shader_Type.Filter_Color_Matrix)
		for row in 0 ..< 4 {
			frag[row] = {v.m[row * 5], v.m[row * 5 + 1], v.m[row * 5 + 2], v.m[row * 5 + 3]}
			frag[4][row] = v.m[row * 5 + 4]
		}
	case Color_Space_Convert:
		frag[10].w = f32(Shader_Type.Filter_Color_Space)
		frag[9].z = 1 if v.to_linear else 0
	case Blend:
		frag[10].w = f32(Shader_Type.Filter_Blend)
		frag[9].z = f32(v.mode)
	case Composite:
		frag[10].w = f32(Shader_Type.Filter_Composite)
		frag[9].z = f32(v.op)
		frag[4] = v.k
	case Component_Transfer:
		frag[10].w = f32(Shader_Type.Filter_Component_Transfer)
	case Lighting:
		frag[10].w = f32(Shader_Type.Filter_Lighting)
		frag[0] = {v.color.r, v.color.g, v.color.b, v.surface_scale}
		frag[1] = {1 if v.specular else 0, f32(v.light), v.constant, v.specular_exponent}
		frag[2] = {v.position.x, v.position.y, v.position.z, v.spot_exponent}
		frag[3] = {v.points_at.x, v.points_at.y, v.points_at.z, v.cone_cos}
		set_valid(&frag, v.valid)
	case Tile:
		frag[10].w = f32(Shader_Type.Filter_Tile)
		frag[0] = v.rect
	case Displacement_Map:
		frag[10].w = f32(Shader_Type.Filter_Displacement)
		frag[0] = {v.scale.x, v.scale.y, f32(v.channels.x), f32(v.channels.y)}
		set_valid(&frag, v.valid)
	case Convolve_Matrix:
		frag[10].w = f32(Shader_Type.Filter_Convolve)
		for k, i in v.kernel {
			frag[i / 4][i % 4] = k
		}
		frag[11] = {f32(v.order.x), f32(v.order.y), f32(v.target.x), f32(v.target.y)}
		frag[12] = {v.divisor, v.bias, f32(v.edge), 1 if v.preserve_alpha else 0}
		set_valid(&frag, v.valid)
	case Bloom_Bright:
		frag[10].w = f32(Shader_Type.Filter_Bloom_Bright)
		frag[0] = {v.threshold, 1 if v.encoded else 0, f32(src.width), f32(src.height)}
	case Bloom_Add:
		frag[10].w = f32(Shader_Type.Filter_Bloom_Add)
		frag[0] = v.uv
		frag[1] = {v.intensity, 1 if v.encoded else 0, 0, 0}
	case Gaussian_Blur, Blur_XY, Morphology, Turbulence:
		return {}, false
	}
	plan.passes[0] = {frag, false, aliased}
	plan.count = 1
	plan.copy = aliased
	return plan, true
}

// feTurbulence's uniforms (see `turbulence` in shaders/filter.frag): frag[0] the
// lattice coordinate of target pixel x, y as (x + a) * b, frag[1] =
// (octaves, fractal, stitch, 0); stitching: frag[2] the tile size in
// cells and the region origin, frag[3].xy the frequencies; frag[3].z is 1
// for an RGBA16F target, which takes the noise unrounded. Computed in
// f64 here, so the shader's f32 starts from rounded exact values.
@(private = "file")
turbulence_uniforms :: proc "contextless" (t: Turbulence, half: bool) -> (frag: [14][4]f32) {
	freq, cells := turbulence_frequency(t.params, {t.region[2], t.region[3]})
	frag[0] = {f32(t.offset.x), f32(t.offset.y), f32(freq.x / t.scale.x), f32(freq.y / t.scale.y)}
	frag[1] = {f32(t.params.octaves), 1 if t.params.fractal_noise else 0, 1 if t.params.stitch else 0, 0}
	frag[2] = {f32(cells.x), f32(cells.y), f32(t.region[0]), f32(t.region[1])}
	frag[3] = {f32(freq.x), f32(freq.y), 1 if half else 0, 0}
	return
}

// Backend-owned state for one image. CPU backends keep `pixels`; GPU
// backends keep their texture in `user` (or a numeric name in `handle`).
Backend_Image :: struct {
	pixels: []u8,
	handle: u32,
	user:   rawptr,
}

Image_Entry :: struct {
	info:     Image_Info,
	image:    Backend_Image,
	// No storage: a stand-in id (see `image_store_alloc_virtual`).
	virtual:  bool,
	// Storage owned elsewhere (`Shared_Images`): never freed through
	// this store.
	borrowed: bool,
}

// Maps `Image_Id`s to backend images. Owned by the canvas; backends receive
// it in `render` to resolve the images a command references.
//
// A recording store (`canvas_init_recording`) has no backend: allocations,
// uploads and frees become `Image_Op`s, with the uploaded pixels, for a
// `Player` to apply on the thread that owns the backend. Ids are issued
// here either way, so recorded commands name the images the player makes.
Image_Store :: struct {
	backend:   Backend,
	entries:   Slot_Map(Image_Entry),
	recording: bool,
	ops:       [dynamic]Image_Op,
	// Copied upload pixels (`Image_Op.copied`).
	pixels:    [dynamic]u8,
}

Image_Op_Kind :: enum u8 {
	Alloc,
	Realloc,
	Update,
	Remove,
	// Alloc + Update of an image every player may share (`Shared_Images`),
	// found by `key`.
	Share,
}

// One step of image work logged by a recording store, applied in order.
Image_Op :: struct {
	kind:     Image_Op_Kind,
	id:       Image_Id,
	info:     Image_Info,
	// Update: the region written.
	x, y:     u32,
	width:    u32,
	height:   u32,
	// Update, Share: tightly packed pixels, borrowed from the caller (a
	// stable source) or copied into the store's `pixels`.
	borrowed: []u8,
	copied:   Range,
	key:      u64,
}

image_store_init :: proc(s: ^Image_Store, backend: Backend, allocator := context.allocator) {
	s.backend = backend
	slot_map_init(&s.entries, allocator)
	s.ops = make([dynamic]Image_Op, allocator)
	s.pixels = make([dynamic]u8, allocator)
}

image_store_alloc :: proc(s: ^Image_Store, info: Image_Info) -> (Image_Id, Error) {
	if s.recording {
		id := Image_Id{slot_map_insert(&s.entries, Image_Entry{info = info})}
		append(&s.ops, Image_Op{kind = .Alloc, id = id, info = info})
		return id, nil
	}
	img, err := s.backend.alloc_image(s.backend.data, info)
	if err != nil {
		return {}, err
	}
	return {slot_map_insert(&s.entries, Image_Entry{info = info, image = img})}, nil
}

// An image whose backend storage was made outside the store (a backend's
// own constructor, such as sdlgpu's image_borrow_texture); removing it
// frees the storage through the backend as any other.
image_store_add :: proc(s: ^Image_Store, info: Image_Info, image: Backend_Image) -> Image_Id {
	return {slot_map_insert(&s.entries, Image_Entry{info = info, image = image})}
}

// An id with `info` but no backend storage. The layer stack records drawing
// against such stand-ins and replaces them with real images before the frame
// reaches the backend.
image_store_alloc_virtual :: proc(s: ^Image_Store, info: Image_Info) -> Image_Id {
	return {slot_map_insert(&s.entries, Image_Entry{info = info, virtual = true})}
}

// An image filled with `src` that players of recorded frames create once
// under `key` and share (`Shared_Images`); elsewhere a plain image. With
// `stable`, `src.data` stays valid and unchanged until every recorded frame
// using it is played, and a recording borrows it instead of copying (as do
// players on backends that read images from memory).
image_store_alloc_shared :: proc(s: ^Image_Store, info: Image_Info, src: Image_Source, key: u64, stable: bool) -> (id: Image_Id, err: Error) {
	if !s.recording {
		id = image_store_alloc(s, info) or_return
		if err = image_store_update(s, id, src, 0, 0); err != nil {
			image_store_remove(s, id)
			return {}, err
		}
		return id, nil
	}
	if src.width != info.width || src.height != info.height || src.format != info.format {
		return {}, .Image_Update_With_Different_Format
	}
	id = Image_Id{slot_map_insert(&s.entries, Image_Entry{info = info, borrowed = true})}
	op := Image_Op{kind = .Share, id = id, info = info, width = src.width, height = src.height, key = key}
	// Borrowed pixels are level 0 alone: an image with levels copies, and the
	// player's upload builds them.
	if stable && .Generate_Mipmaps not_in info.flags && image_source_stride(src) == src.width * bytes_per_pixel(src.format) {
		op.borrowed = src.data[:src.width * src.height * bytes_per_pixel(src.format)]
	} else {
		op.copied = image_store_copy_pixels(s, src)
	}
	append(&s.ops, op)
	return id, nil
}

// Replaces the image's storage with a fresh allocation; contents are lost.
image_store_realloc :: proc(s: ^Image_Store, id: Image_Id, info: Image_Info) -> Error {
	entry := slot_map_get(&s.entries, id.key)
	if entry == nil {
		return .Image_Id_Not_Found
	}
	if s.recording {
		entry^ = {info = info}
		append(&s.ops, Image_Op{kind = .Realloc, id = id, info = info})
		return nil
	}
	img, err := s.backend.alloc_image(s.backend.data, info)
	if err != nil {
		return err
	}
	if !entry.borrowed {
		s.backend.delete_image(s.backend.data, entry.image, id)
	}
	entry^ = {info = info, image = img}
	return nil
}

image_store_get :: proc(s: ^Image_Store, id: Image_Id) -> ^Image_Entry {
	return slot_map_get(&s.entries, id.key)
}

image_store_info :: proc(s: ^Image_Store, id: Image_Id) -> (Image_Info, bool) {
	entry := slot_map_get(&s.entries, id.key)
	if entry == nil {
		return {}, false
	}
	return entry.info, true
}

image_store_update :: proc(s: ^Image_Store, id: Image_Id, src: Image_Source, x, y: u32) -> Error {
	entry := slot_map_get(&s.entries, id.key)
	if entry == nil {
		return .Image_Id_Not_Found
	}
	if x + src.width > entry.info.width || y + src.height > entry.info.height {
		return .Image_Update_Out_Of_Bounds
	}
	if src.format != entry.info.format {
		return .Image_Update_With_Different_Format
	}
	// Levels come from the whole of level 0.
	if .Generate_Mipmaps in entry.info.flags && (x != 0 || y != 0 || src.width != entry.info.width || src.height != entry.info.height) {
		return .Unsupported_Operation
	}
	if s.recording {
		append(&s.ops, Image_Op{kind = .Update, id = id, info = entry.info, x = x, y = y, width = src.width, height = src.height, copied = image_store_copy_pixels(s, src)})
		return nil
	}
	return s.backend.update_image(s.backend.data, &entry.image, entry.info, src, x, y)
}

image_store_remove :: proc(s: ^Image_Store, id: Image_Id) {
	entry, ok := slot_map_remove(&s.entries, id.key)
	if !ok || entry.virtual {
		return
	}
	if s.recording {
		append(&s.ops, Image_Op{kind = .Remove, id = id})
	} else if !entry.borrowed {
		s.backend.delete_image(s.backend.data, entry.image, id)
	}
}

image_store_destroy :: proc(s: ^Image_Store) {
	if !s.recording {
		for &slot, idx in s.entries.slots {
			if slot.occupied && !slot.value.virtual && !slot.value.borrowed {
				s.backend.delete_image(s.backend.data, slot.value.image, {Key{u32(idx), slot.gen}})
			}
		}
	}
	slot_map_destroy(&s.entries)
	delete(s.ops)
	delete(s.pixels)
}

// Appends `src`'s rows tightly packed to the store's pixels.
@(private)
image_store_copy_pixels :: proc(s: ^Image_Store, src: Image_Source) -> Range {
	row := int(src.width * bytes_per_pixel(src.format))
	stride := int(image_source_stride(src))
	start := len(s.pixels)
	if need := start + row * int(src.height); need > cap(s.pixels) {
		reserve(&s.pixels, max(need, 2 * cap(s.pixels)))
	}
	resize(&s.pixels, start + row * int(src.height))
	for y in 0 ..< int(src.height) {
		copy(s.pixels[start + y * row:][:row], src.data[y * stride:][:row])
	}
	return {u32(start), u32(row * int(src.height))}
}

// ---- mip levels -------------------------------------------------------------------

// The levels an image keeps, level 0 included: with .Generate_Mipmaps its
// chain down to 1 x 1 (level l `max(width >> l, 1) x max(height >> l, 1)`,
// at most IMAGE_MAX_LEVELS), else 1.
IMAGE_MAX_LEVELS :: 16

image_level_count :: proc "contextless" (info: Image_Info) -> int {
	if .Generate_Mipmaps not_in info.flags {
		return 1
	}
	n := 1
	for w, h := info.width, info.height; (w > 1 || h > 1) && n < IMAGE_MAX_LEVELS; n += 1 {
		w, h = max(w >> 1, 1), max(h >> 1, 1)
	}
	return n
}

// Level `l`'s size and where it starts in the image's chain: level 0, then
// each level after the one before, tightly packed.
image_level :: proc "contextless" (info: Image_Info, l: int) -> (width, height: u32, offset: int) {
	width, height = info.width, info.height
	bpp := int(bytes_per_pixel(info.format))
	for _ in 0 ..< l {
		offset += int(width) * int(height) * bpp
		width, height = max(width >> 1, 1), max(height >> 1, 1)
	}
	return
}

// The bytes an image's chain takes: all its levels.
image_chain_bytes :: proc "contextless" (info: Image_Info) -> int {
	_, _, n := image_level(info, image_level_count(info))
	return n
}

// Builds levels 1 and on of `chain` (image_chain_bytes, level 0 written)
// from level 0, each level from the one before: a texel is the average of
// the area of the level below that it covers (2 x 2 texels, or a fractional
// 2-3 a side where that level is odd), so a minified image averages what
// each pixel covers. Straight-alpha RGBA8 averages colour weighted by
// alpha, so the colour of transparent texels does not bleed in. A level
// halving an 8-bit one exactly averages each 2 x 2; any other takes each
// axis's weights from a table made once for the level. The format and the
// alpha are fixed per level, outside the loops.
image_levels_build :: proc(info: Image_Info, chain: []u8) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	straight := info.format == .RGBA8 && .Premultiplied not_in info.flags
	for l in 1 ..< image_level_count(info) {
		sw, sh, src_at := image_level(info, l - 1)
		dw, dh, dst_at := image_level(info, l)
		src, dst := chain[src_at:], chain[dst_at:]
		if sw == 2 * dw && sh == 2 * dh && (info.format == .RGBA8 || info.format == .Gray8) {
			switch {
			case info.format == .Gray8:
				level_halve_u8(src, dst, int(dw), int(dh), 1, false)
			case straight:
				level_halve_u8(src, dst, int(dw), int(dh), 4, true)
			case:
				level_halve_u8(src, dst, int(dw), int(dh), 4, false)
			}
			continue
		}
		xs := level_taps(int(sw), int(dw))
		ys := level_taps(int(sh), int(dh))
		switch info.format {
		case .RGBA8:
			if straight {
				level_area_u8(src, dst, int(sw), int(dw), xs, ys, 4, true)
			} else {
				level_area_u8(src, dst, int(sw), int(dw), xs, ys, 4, false)
			}
		case .Gray8:
			level_area_u8(src, dst, int(sw), int(dw), xs, ys, 1, false)
		case .Gray16:
			level_area_16(.Gray16, src, dst, int(sw), int(dw), xs, ys)
		case .RGBA16F:
			level_area_16(.RGBA16F, src, dst, int(sw), int(dw), xs, ys)
		}
	}
}

// The texels of a level `n` wide that texel i of the next (`m` wide)
// covers, [i, i + 1) * n / m, and the share of it each covers.
@(private = "file")
Level_Taps :: struct {
	first, n: int,
	w:        [4]f32,
}

@(private = "file")
level_taps :: proc(n, m: int) -> []Level_Taps {
	taps := make([]Level_Taps, m, context.temp_allocator)
	s := f32(n) / f32(m)
	for &t, i in taps {
		x0, x1 := f32(i) * s, f32(i + 1) * s
		t.first = int(x0)
		// s is under 3 (an odd level halves to floor), so at most 4.
		t.n = min(int(math.ceil(x1)), n) - t.first
		for k in 0 ..< t.n {
			j := f32(t.first + k)
			t.w[k] = (min(x1, j + 1) - max(x0, j)) / s
		}
	}
	return taps
}

// An 8-bit level of any size: across each source row by `xs`, each
// row's sums kept for the next texel row that reads it, then down by `ys`
// (`ch` channels; straight-alpha colour times alpha, divided back once a
// texel).
@(private = "file")
level_area_u8 :: proc(src, dst: []u8, sw, dw: int, xs, ys: []Level_Taps, $ch: int, $straight: bool) {
	across := make([]#simd[4]f32, 4 * dw, context.temp_allocator)
	// The source row each of `across`'s four rows holds (row r in slot r % 4).
	held := [4]int{-1, -1, -1, -1}
	for ty, y in ys {
		for j in 0 ..< ty.n {
			r := ty.first + j
			slot := r & 3
			if held[slot] == r {
				continue
			}
			held[slot] = r
			row := src[r * sw * ch:][:sw * ch]
			out := across[slot * dw:][:dw]
			#no_bounds_check for tx, x in xs {
				sum: #simd[4]f32
				for i in 0 ..< tx.n {
					when ch == 4 {
						t := cast(#simd[4]f32)simd.from_array(slice.reinterpret([][4]u8, row)[tx.first + i])
						when straight {
							t *= simd.replace(simd.swizzle(t, 3, 3, 3, 3), 3, 1)
						}
					} else {
						t := #simd[4]f32{f32(row[tx.first + i]), 0, 0, 0}
					}
					sum += t * tx.w[i]
				}
				out[x] = sum
			}
		}
		#no_bounds_check for x in 0 ..< dw {
			sum: #simd[4]f32
			for j in 0 ..< ty.n {
				sum += across[((ty.first + j) & 3) * dw + x] * ty.w[j]
			}
			when straight {
				// Colour times alpha over alpha.
				a := simd.extract(sum, 3)
				inv := 1 / a if a > 0 else 0
				sum *= #simd[4]f32{inv, inv, inv, 1}
			}
			c := simd.to_array(cast(#simd[4]u8)simd.min(sum + 0.5, 255))
			when ch == 4 {
				slice.reinterpret([][4]u8, dst[y * dw * 4:][:dw * 4])[x] = c
			} else {
				dst[y * dw + x] = c[0]
			}
		}
	}
}

// An 8-bit level halved exactly: each texel the rounded mean of its 2 x 2,
// straight-alpha colour weighted by alpha (none where all four are clear).
@(private = "file")
level_halve_u8 :: proc(src, dst: []u8, dw, dh: int, $ch: int, $straight: bool) {
	sw := 2 * dw
	for y in 0 ..< dh {
		r0 := src[2 * y * sw * ch:][:sw * ch]
		r1 := src[(2 * y + 1) * sw * ch:][:sw * ch]
		out := dst[y * dw * ch:][:dw * ch]
		when !straight {
			for x in 0 ..< dw {
				for k in 0 ..< ch {
					i := 2 * x * ch + k
					out[x * ch + k] = u8((u32(r0[i]) + u32(r0[i + ch]) + u32(r1[i]) + u32(r1[i + ch]) + 2) >> 2)
				}
			}
			continue
		}
		q0, q1 := slice.reinterpret([][4]u8, r0), slice.reinterpret([][4]u8, r1)
		o := slice.reinterpret([][4]u8, out)
		// Colour times alpha (alpha as is), summed: whole numbers, exact in f32.
		premul :: #force_inline proc "contextless" (p: [4]u8) -> #simd[4]f32 {
			t := cast(#simd[4]f32)simd.from_array(p)
			return t * simd.replace(simd.swizzle(t, 3, 3, 3, 3), 3, 1)
		}
		#no_bounds_check for x in 0 ..< dw {
			sum := premul(q0[2 * x]) + premul(q0[2 * x + 1]) + premul(q1[2 * x]) + premul(q1[2 * x + 1])
			a := simd.extract(sum, 3)
			// Colour over alpha, alpha a quarter of its sum; rounded.
			inv := 1 / a if a > 0 else 0
			o[x] = simd.to_array(cast(#simd[4]u8)(sum * #simd[4]f32{inv, inv, inv, 0.25} + 0.5))
		}
	}
}

// A 16-bit level (Gray16, RGBA16F), of any size: each texel the
// area-weighted sum of up to 4 x 4 texels below, by `xs` and `ys`.
@(private = "file")
level_area_16 :: proc($F: Pixel_Format, src, dst: []u8, sw, dw: int, xs, ys: []Level_Taps) where F == .Gray16 || F == .RGBA16F {
	for ty, y in ys {
		for tx, x in xs {
			sum: [4]f32
			for j in 0 ..< ty.n {
				row := (ty.first + j) * sw + tx.first
				for i in 0 ..< tx.n {
					sum += level_load(F, src, row + i) * (ty.w[j] * tx.w[i])
				}
			}
			level_store(F, dst, y * dw + x, sum)
		}
	}
}

// Texel `at` of a level as [0, 1] floats (RGBA16F as stored); Gray16's in
// .r.
@(private = "file")
level_load :: #force_inline proc "contextless" ($F: Pixel_Format, level: []u8, at: int) -> [4]f32 {
	when F == .Gray16 {
		return {f32(u16(level[at * 2]) | u16(level[at * 2 + 1]) << 8) / 65535, 0, 0, 0}
	} else {
		p := ([^]f16)(raw_data(level[at * 8:]))
		return {f32(p[0]), f32(p[1]), f32(p[2]), f32(p[3])}
	}
}

@(private = "file")
level_store :: #force_inline proc "contextless" ($F: Pixel_Format, level: []u8, at: int, t: [4]f32) {
	when F == .Gray16 {
		v := u16(clamp(t.r, 0, 1) * 65535 + 0.5)
		level[at * 2], level[at * 2 + 1] = u8(v), u8(v >> 8)
	} else {
		p := ([^]f16)(raw_data(level[at * 8:]))
		for k in 0 ..< 4 {
			p[k] = f16(t[k])
		}
	}
}

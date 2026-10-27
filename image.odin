package ovg

import "core:math"

Pixel_Format :: enum u8 {
	RGB8,
	RGBA8,
	Gray8,
	// 16-bit single channel (little-endian u16, sampled as value / 65535):
	// deep planes, e.g. 10- and 12-bit video, for custom programs.
	Gray16,
	// Half-float RGBA (four f16 per pixel), stored and sampled unclamped:
	// for custom program targets and channels (feedback buffers).
	RGBA16F,
}

bytes_per_pixel :: proc "contextless" (f: Pixel_Format) -> u32 {
	switch f {
	case .RGB8:
		return 3
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

image_source_rgb :: proc "contextless" (data: []u8, width, height: u32) -> Image_Source {
	return {.RGB8, data, width, height, 0}
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
// and write premultiplied images of one size (Gray8 and RGB8 sources are
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
// filter's source is the lattice image of `params.seed` (see
// `turbulence_lattice_pixels`). Target pixel (x, y) is user point
// ((x + offset.x) / scale.x, (y + offset.y) / scale.y); `region` (x, y, w,
// h in target pixels) is the stitching tile. GPU backends evaluate it in
// f32 from the lattice image, the software backend in f64 from the seed.
Turbulence :: struct {
	params: Turbulence_Params,
	seed:   i32,
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
	}
	return {}
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
	if stable && image_source_stride(src) == src.width * bytes_per_pixel(src.format) {
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

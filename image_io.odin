package ovg

import "core:mem"
import "core:os"
import image "deps:oicut/image"

// Decodes a PNG/JPEG/GIF/BMP/TGA/QOI/WebP (anything oicut's image reads) and
// uploads it as an RGBA8 image.
load_image_mem :: proc(c: ^Canvas, data: []u8, flags: Image_Flags = {}) -> (Image_Id, Error) {
	img, err := image.decode(data)
	if err != nil {
		return {}, .Image_Decode
	}
	defer image.destroy_image(&img)
	return create_image(c, image_source_rgba(img.pixels, u32(img.width), u32(img.height)), flags)
}

load_image_file :: proc(c: ^Canvas, path: string, flags: Image_Flags = {}) -> (Image_Id, Error) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return {}, .Io
	}
	defer delete(data)
	return load_image_mem(c, data, flags)
}

// Decoded straight-alpha RGBA8, owned by whoever decoded it.
Bitmap :: struct {
	pixels:        []u8,
	width, height: u32,
}

// Decodes PNG / JPEG / ... bytes to straight RGBA8 with `allocator`. Images
// over the budget's (or DEFAULT_LIMITS') Image_Pixels are not decoded.
decode_image :: proc(data: []u8, allocator: mem.Allocator, budget: ^Budget = nil) -> (pixels: []u8, width, height: u32, ok: bool) {
	info, ierr := image.info(data)
	if ierr != nil {
		return
	}
	if budget != nil && budget_over(budget, .Image_Pixels, info.width * info.height) {
		return
	} else if budget == nil && info.width * info.height > DEFAULT_LIMITS[.Image_Pixels] {
		return
	}
	// Only the pixels go in `allocator`; the decoder's scratch is its own.
	pixels = make([]u8, info.width * info.height * 4, allocator)
	if image.decode_into(data, pixels) != nil {
		delete(pixels, allocator)
		return nil, 0, 0, false
	}
	return pixels, u32(info.width), u32(info.height), true
}

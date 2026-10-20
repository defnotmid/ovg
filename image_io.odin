package ovg

import "core:os"
import image "deps:odecs/image"

// Decodes a PNG/JPEG/GIF/BMP/TGA/QOI/WebP (anything odecs' image reads) and
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

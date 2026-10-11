package ovg

import "core:os"
import "core:strings"
import stbi "vendor:stb/image"

// Decodes a PNG/JPEG/BMP/GIF/TGA/... (anything stb_image reads) and uploads
// it as an RGBA8 image.
load_image_mem :: proc(c: ^Canvas, data: []u8, flags: Image_Flags = {}) -> (Image_Id, Error) {
	w, h, channels: i32
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &channels, 4)
	if pixels == nil {
		return {}, .Image_Decode
	}
	defer stbi.image_free(pixels)
	return create_image(c, image_source_rgba(pixels[:w * h * 4], u32(w), u32(h)), flags)
}

load_image_file :: proc(c: ^Canvas, path: string, flags: Image_Flags = {}) -> (Image_Id, Error) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return {}, .Io
	}
	defer delete(data)
	return load_image_mem(c, data, flags)
}

// Writes tightly packed top-down RGBA8 pixels as a PNG file.
write_png :: proc(path: string, pixels: []u8, width, height: u32) -> Error {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if stbi.write_png(cpath, i32(width), i32(height), 4, raw_data(pixels), i32(width * 4)) == 0 {
		return .Io
	}
	return nil
}

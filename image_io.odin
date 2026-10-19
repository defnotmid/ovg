package ovg

import "core:encoding/endian"
import "core:hash"
import "core:os"
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

// Writes tightly packed top-down RGBA8 pixels as a PNG file: every row
// Paeth-filtered, deflated as runs of the previous byte (deflate.odin; on
// rendered frames several times faster than stb_image_write and smaller),
// streamed out as IDAT chunks of about PNG_CHUNK bytes.
write_png :: proc(path: string, pixels: []u8, width, height: u32) -> Error {
	if width == 0 || height == 0 || len(pixels) < int(width) * int(height) * 4 {
		return .Unsupported_Format
	}
	f, ferr := os.create(path)
	if ferr != nil {
		return .Io
	}
	defer os.close(f)
	return png_write(pixels, width, height, f, proc(f: rawptr, data: []u8) -> bool {
		_, err := os.write((^os.File)(f), data)
		return err == nil
	})
}

// write_png's encoding into memory: the PNG file's bytes.
encode_png :: proc(pixels: []u8, width, height: u32, allocator := context.allocator) -> ([]u8, Error) {
	if width == 0 || height == 0 || len(pixels) < int(width) * int(height) * 4 {
		return nil, .Unsupported_Format
	}
	out := make([dynamic]u8, allocator)
	err := png_write(pixels, width, height, &out, proc(out: rawptr, data: []u8) -> bool {
		_, err := append((^[dynamic]u8)(out), ..data)
		return err == nil
	})
	if err != nil {
		delete(out)
		return nil, err == .Io ? .Out_Of_Memory : err
	}
	return out[:], nil
}

@(private)
png_write :: proc(pixels: []u8, width, height: u32, ctx: rawptr, sink: proc(ctx: rawptr, data: []u8) -> bool) -> Error {
	stride := int(width) * 4
	ok := sink(ctx, {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})
	head: [8 + 13 + 4]u8
	ihdr := head[8:]
	endian.put_u32(ihdr[0:4], .Big, width)
	endian.put_u32(ihdr[4:8], .Big, height)
	copy(ihdr[8:13], []u8{8, 6, 0, 0, 0}) // 8 bits, RGBA, deflate, adaptive filtering, no interlace
	ok &&= png_chunk(head[:], "IHDR", ctx, sink)

	// The compressed stream builds up behind room for a chunk header, so
	// each IDAT goes out in place.
	z: Deflate
	deflate_init(&z, 8)
	defer deflate_destroy(&z)
	rows := make([]u8, stride * 2 + 1)
	defer delete(rows)
	zero, row := rows[:stride], rows[stride:]
	for y in 0 ..< int(height) {
		cur := pixels[y * stride:][:stride]
		prev := y > 0 ? pixels[(y - 1) * stride:][:stride] : zero
		png_filter_paeth(row, cur, prev)
		deflate_write(&z, row)
		if len(z.out) - 8 >= PNG_CHUNK && ok {
			ok &&= png_idat(&z, ctx, sink)
		}
	}
	deflate_finish(&z)
	ok &&= png_idat(&z, ctx, sink)
	iend: [12]u8
	ok &&= png_chunk(iend[:], "IEND", ctx, sink)
	return ok ? nil : .Io
}

// Sends `chunk`: its data sits between 8 bytes of room for the length and
// type and 4 for the CRC, which are filled in here.
@(private = "file")
png_chunk :: proc(chunk: []u8, type: string, ctx: rawptr, sink: proc(ctx: rawptr, data: []u8) -> bool) -> bool {
	n := len(chunk) - 12
	endian.put_u32(chunk[0:4], .Big, u32(n))
	copy(chunk[4:8], type)
	endian.put_u32(chunk[8 + n:][:4], .Big, hash.crc32(chunk[4:8 + n]))
	return sink(ctx, chunk)
}

@(private = "file")
png_idat :: proc(z: ^Deflate, ctx: rawptr, sink: proc(ctx: rawptr, data: []u8) -> bool) -> bool {
	resize(&z.out, len(z.out) + 4)
	ok := png_chunk(z.out[:], "IDAT", ctx, sink)
	resize(&z.out, 8)
	return ok
}

@(private)
PNG_CHUNK :: 1 << 18

// PNG filter type 4: each byte minus whichever of left, up and up-left is
// nearest to left + up - up-left.
@(private)
png_filter_paeth :: proc "contextless" (dst, cur, prev: []u8) {
	dst[0] = 4
	for i in 0 ..< 4 {
		dst[1 + i] = cur[i] - prev[i]
	}
	for i in 4 ..< len(cur) {
		a, b, c := i32(cur[i - 4]), i32(prev[i]), i32(prev[i - 4])
		pa, pb, pc := abs(b - c), abs(a - c), abs(a + b - 2 * c)
		p := pa <= pb && pa <= pc ? a : pb <= pc ? b : c
		dst[1 + i] = cur[i] - u8(p)
	}
}

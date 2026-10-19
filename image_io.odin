package ovg

import "core:encoding/endian"
import "core:os"
import stbi "vendor:stb/image"
import zlib "vendor:zlib"

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
// Paeth-filtered, deflated with zlib's run-length strategy (on rendered frames
// about 6-10x faster than stb_image_write and smaller), streamed out as IDAT
// chunks of up to PNG_CHUNK bytes.
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
	ok := true
	// One buffer per chunk: length and type, then the data, then the CRC.
	chunk := make([]u8, 8 + PNG_CHUNK + 4)
	defer delete(chunk)
	emit :: proc(chunk: []u8, type: string, n: int, ctx: rawptr, sink: proc(ctx: rawptr, data: []u8) -> bool) -> bool {
		endian.put_u32(chunk[0:4], .Big, u32(n))
		copy(chunk[4:8], type)
		crc := zlib.crc32(0, raw_data(chunk[4:]), zlib.uInt(4 + n))
		endian.put_u32(chunk[8 + n:][:4], .Big, u32(crc))
		return sink(ctx, chunk[:8 + n + 4])
	}

	ok &&= sink(ctx, {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})
	ihdr := chunk[8:]
	endian.put_u32(ihdr[0:4], .Big, width)
	endian.put_u32(ihdr[4:8], .Big, height)
	copy(ihdr[8:13], []u8{8, 6, 0, 0, 0}) // 8 bits, RGBA, deflate, adaptive filtering, no interlace
	ok &&= emit(chunk, "IHDR", 13, ctx, sink)

	z: zlib.z_stream
	if zlib.deflateInit2(&z, 1, zlib.DEFLATED, 15, 9, zlib.RLE) != zlib.OK {
		return .Out_Of_Memory
	}
	defer zlib.deflateEnd(&z)
	rows := make([]u8, stride * 2 + 1)
	defer delete(rows)
	zero, row := rows[:stride], rows[stride:]
	z.next_out, z.avail_out = raw_data(chunk[8:]), PNG_CHUNK
	for y in 0 ..< int(height) {
		cur := pixels[y * stride:][:stride]
		prev := y > 0 ? pixels[(y - 1) * stride:][:stride] : zero
		png_filter_paeth(row, cur, prev)
		z.next_in, z.avail_in = raw_data(row), zlib.uInt(len(row))
		last := y == int(height) - 1
		for ok {
			r := zlib.deflate(&z, last ? zlib.FINISH : zlib.NO_FLUSH)
			if r != zlib.OK && r != zlib.STREAM_END && r != zlib.BUF_ERROR {
				return .General
			}
			if z.avail_out == 0 || r == zlib.STREAM_END {
				ok &&= emit(chunk, "IDAT", PNG_CHUNK - int(z.avail_out), ctx, sink)
				z.next_out, z.avail_out = raw_data(chunk[8:]), PNG_CHUNK
			}
			if r == zlib.STREAM_END || (!last && z.avail_in == 0) {
				break
			}
		}
	}
	ok &&= emit(chunk, "IEND", 0, ctx, sink)
	return ok ? nil : .Io
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

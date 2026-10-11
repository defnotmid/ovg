package ovg

import "core:mem"

// Null backend: draws nothing, remembers the size of the last frame. For
// tests that only inspect recorded commands.
Void_Backend :: struct {
	width, height:       u32,
	last_frame_commands: int,
	last_frame_verts:    int,
}

void_backend :: proc(b: ^Void_Backend) -> Backend {
	return {
		data = b,
		set_size = proc(data: rawptr, width, height: u32, dpi: f32) {
			b := (^Void_Backend)(data)
			b.width, b.height = width, height
		},
		render = proc(data: rawptr, output: Render_Output, images: ^Image_Store, frame: Frame) {
			b := (^Void_Backend)(data)
			b.last_frame_commands = len(frame.commands)
			b.last_frame_verts = len(frame.verts)
		},
		alloc_image = proc(data: rawptr, info: Image_Info) -> (Backend_Image, Error) {
			return {}, nil
		},
		update_image = proc(data: rawptr, image: ^Backend_Image, info: Image_Info, src: Image_Source, x, y: u32) -> Error {
			return nil
		},
		delete_image = proc(data: rawptr, image: Backend_Image, id: Image_Id) {},
		screenshot = proc(data: rawptr, allocator: mem.Allocator) -> (Screenshot, Error) {
			return {}, .Unsupported_Operation
		},
		create_program = proc(data: rawptr, desc: Program_Desc) -> (Backend_Program, Error) {
			return {}, nil
		},
		delete_program = proc(data: rawptr, program: Backend_Program) {},
	}
}

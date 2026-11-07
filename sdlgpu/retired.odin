package ovg_sdlgpu

import "base:runtime"
import "core:sync"
import sdl "vendor:sdl3"

// GPU memory a backend has let go of, held until `retired_release` gives it back
// to SDL. For a device shared between threads: SDL frees a texture's or buffer's
// container as soon as it is released, while a submit's defragmenter may be
// writing the moved resource into that container under another lock, so a release
// during a present corrupts the heap (Vulkan, SDL 3.4.18). A submit defragments
// when it presents, or on a device with no claimed window, any submit.
//
// The zero value is ready. The caller owns the table, one per device, so a
// backend's `destroy` can push into it and go away, and calls `retired_release`
// between presents on the thread that presents, whether or not it presents this
// time: nothing else frees what is here.
//
// Only what a defrag can move belongs here. Transfer buffers stay out: SDL makes
// them dedicated allocations, which it never moves, so queuing them would only
// hold memory. Pipelines, samplers, shaders and fences have no memory to move.
Retired :: struct {
	mutex:    sync.Mutex,
	textures: [dynamic]^sdl.GPUTexture,
	buffers:  [dynamic]^sdl.GPUBuffer,
}

// Lets go of `t`: into the table, from any thread, or with a nil table to SDL at
// once. A nil `t` is nothing. The lists grow on the heap whatever the caller's
// allocator, since they outlive the frame and the thread that pushed. If the heap
// fails the texture leaks, which beats releasing it during a present.
retire_texture :: proc(device: ^sdl.GPUDevice, r: ^Retired, t: ^sdl.GPUTexture) {
	if t == nil {
		return
	}
	if r == nil {
		sdl.ReleaseGPUTexture(device, t)
		return
	}
	context.allocator = runtime.heap_allocator()
	sync.guard(&r.mutex)
	append(&r.textures, t)
}

// `retire_texture`, for a buffer.
retire_buffer :: proc(device: ^sdl.GPUDevice, r: ^Retired, b: ^sdl.GPUBuffer) {
	if b == nil {
		return
	}
	if r == nil {
		sdl.ReleaseGPUBuffer(device, b)
		return
	}
	context.allocator = runtime.heap_allocator()
	sync.guard(&r.mutex)
	append(&r.buffers, b)
}

// Gives everything in the table back to SDL, keeping the lists' capacity. A nil
// table has nothing to give.
retired_release :: proc(device: ^sdl.GPUDevice, r: ^Retired) {
	if r == nil {
		return
	}
	sync.guard(&r.mutex)
	for t in r.textures {
		sdl.ReleaseGPUTexture(device, t)
	}
	for b in r.buffers {
		sdl.ReleaseGPUBuffer(device, b)
	}
	clear(&r.textures)
	clear(&r.buffers)
}

// Frees the lists, after a last `retired_release`.
retired_destroy :: proc(r: ^Retired) {
	delete(r.textures)
	delete(r.buffers)
	r^ = {}
}

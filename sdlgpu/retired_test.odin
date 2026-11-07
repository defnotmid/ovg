package ovg_sdlgpu

import "base:runtime"
import "core:mem"
import "core:testing"
import "core:thread"
import sdl "vendor:sdl3"

// With no device SDL reports the call and stops there, so its error shows what
// reached it, and the handles need not be real.
@(private = "file")
FAKE_TEXTURE := (^sdl.GPUTexture)(uintptr(16))
@(private = "file")
FAKE_BUFFER := (^sdl.GPUBuffer)(uintptr(32))

@(private = "file")
reached_sdl :: proc() -> bool {
	return sdl.GetError() != ""
}

@(test)
test_retired_nil_table_releases_at_once :: proc(t: ^testing.T) {
	_ = sdl.ClearError()
	retire_texture(nil, nil, FAKE_TEXTURE)
	testing.expect(t, reached_sdl(), "texture")
	_ = sdl.ClearError()
	retire_buffer(nil, nil, FAKE_BUFFER)
	testing.expect(t, reached_sdl(), "buffer")
}

@(test)
test_retired_nothing_reaches_sdl_until_release :: proc(t: ^testing.T) {
	r: Retired
	defer retired_destroy(&r)
	// Each kind on its own, so that one reaching SDL can't stand in for the other.
	for texture in ([2]bool{true, false}) {
		_ = sdl.ClearError()
		if texture {
			retire_texture(nil, &r, FAKE_TEXTURE)
		} else {
			retire_buffer(nil, &r, FAKE_BUFFER)
		}
		testing.expect(t, !reached_sdl(), "pushed")
		testing.expect_value(t, len(r.textures) + len(r.buffers), 1)
		retired_release(nil, &r)
		testing.expect(t, reached_sdl(), "released")
		testing.expect_value(t, len(r.textures) + len(r.buffers), 0)
		// Released once: nothing is left to reach SDL again.
		_ = sdl.ClearError()
		retired_release(nil, &r)
		testing.expect(t, !reached_sdl(), "released again")
	}
	testing.expect(t, cap(r.textures) > 0 && cap(r.buffers) > 0, "capacity kept")
}

@(test)
test_retired_nil_handle_and_nil_table :: proc(t: ^testing.T) {
	r: Retired
	defer retired_destroy(&r)
	_ = sdl.ClearError()
	retire_texture(nil, nil, nil)
	retire_buffer(nil, nil, nil)
	retire_texture(nil, &r, nil)
	retire_buffer(nil, &r, nil)
	retired_release(nil, nil)
	testing.expect(t, !reached_sdl(), "nothing to release")
	testing.expect_value(t, len(r.textures) + len(r.buffers), 0)
}

// The lists grow on the heap, whatever allocator the pushing thread has: this one
// panics if asked, from a table's first push on.
@(test)
test_retired_ignores_the_callers_allocator :: proc(t: ^testing.T) {
	r: Retired
	defer retired_destroy(&r)
	{
		context.allocator = mem.panic_allocator()
		for _ in 0 ..< 1000 {
			retire_texture(nil, &r, FAKE_TEXTURE)
			retire_buffer(nil, &r, FAKE_BUFFER)
		}
	}
	testing.expect(t, r.textures.allocator.procedure == runtime.heap_allocator().procedure, "textures")
	testing.expect(t, r.buffers.allocator.procedure == runtime.heap_allocator().procedure, "buffers")
}

@(private = "file")
PUSHES :: 20_000

@(private = "file")
pusher :: proc(r: ^Retired) {
	context.allocator = mem.panic_allocator()
	for _ in 0 ..< PUSHES {
		retire_texture(nil, r, FAKE_TEXTURE)
		retire_buffer(nil, r, FAKE_BUFFER)
	}
}

// Threads pushing at once lose nothing, and pushing during a release is safe.
@(test)
test_retired_pushes_from_threads :: proc(t: ^testing.T) {
	r: Retired
	defer retired_destroy(&r)
	threads: [4]^thread.Thread
	for &th in threads {
		th = thread.create_and_start_with_poly_data(&r, pusher)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	n := len(threads) * PUSHES
	testing.expect_value(t, len(r.textures), n)
	testing.expect_value(t, len(r.buffers), n)

	for &th in threads {
		th = thread.create_and_start_with_poly_data(&r, pusher)
	}
	done := false
	for !done {
		retired_release(nil, &r)
		done = true
		for th in threads {
			done &&= thread.is_done(th)
		}
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	retired_release(nil, &r)
	testing.expect_value(t, len(r.textures) + len(r.buffers), 0)
}

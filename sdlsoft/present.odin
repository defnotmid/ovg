// Shows the software backend's screen in an SDL window, with no GPU device:
// the frame is copied into the window's surface, the framebuffer in main
// memory that SDL's video drivers keep for it (SDL_GetWindowSurface,
// SDL_UpdateWindowSurface), and nothing else draws to that window. An app
// can draw with ovg's SDL_GPU backend where SDL has a GPU device and fall
// back to this one where it hasn't, from the same frames.
package ovg_sdlsoft

import sdl "vendor:sdl3"
import vg ".."

// What presenting keeps from frame to frame: the screen as an SDL surface
// over the backend's pixels, made again only when they move or resize.
Presenter :: struct {
	window: ^sdl.Window,
	from:   ^sdl.Surface,
	pixels: rawptr,
	width:  u32,
	height: u32,
}

presenter_init :: proc(p: ^Presenter, window: ^sdl.Window) {
	p^ = {window = window}
}

presenter_destroy :: proc(p: ^Presenter) {
	if p.from != nil {
		sdl.DestroySurface(p.from)
	}
	p^ = {}
}

// The window's size in pixels: the size to give the canvas (vg.set_size)
// so the frame fills it.
window_pixels :: proc(window: ^sdl.Window) -> (width, height: u32) {
	w, h: i32
	if !sdl.GetWindowSizeInPixels(window, &w, &h) {
		return 0, 0
	}
	return u32(max(w, 0)), u32(max(h, 0))
}

// Copies the backend's screen into the window and shows it (present_pixels).
present :: proc(p: ^Presenter, b: ^vg.Software_Backend) -> bool {
	return present_pixels(p, vg.software_backend_pixels(b))
}

// Copies RGBA8 pixels into the window and shows them: the backend's screen,
// or an image of a software canvas (vg.software_backend_image), such as one a
// frame was drawn into whole. They're premultiplied: where they aren't
// opaque the window shows them over black. Pixels of another size than the
// window fill the corner they share. False for another format or tightly
// packed rows short of their size, or when SDL gives the window no surface
// or can't update it (sdl.GetError says why).
present_pixels :: proc(p: ^Presenter, src: vg.Image_Source) -> bool {
	if src.format != .RGBA8 || src.width == 0 || src.height == 0 || vg.image_source_stride(src) != src.width * 4 || len(src.data) < int(src.width * src.height * 4) {
		return false
	}
	if p.from == nil || p.pixels != raw_data(src.data) || p.width != src.width || p.height != src.height {
		if p.from != nil {
			sdl.DestroySurface(p.from)
		}
		// RGBA32: the bytes R, G, B, A in memory, as ovg stores them.
		p.from = sdl.CreateSurfaceFrom(i32(src.width), i32(src.height), .RGBA32, raw_data(src.data), i32(src.width * 4))
		if p.from == nil {
			p.pixels = nil
			return false
		}
		// Copied as they are, not blended over what the window held.
		sdl.SetSurfaceBlendMode(p.from, sdl.BLENDMODE_NONE)
		p.pixels, p.width, p.height = raw_data(src.data), src.width, src.height
	}
	surface := sdl.GetWindowSurface(p.window)
	if surface == nil {
		return false
	}
	return sdl.BlitSurface(p.from, nil, surface, nil) && sdl.UpdateWindowSurface(p.window)
}

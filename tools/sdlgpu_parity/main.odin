// Renders the shared scenes with the software and SDL_GPU backends
// (headless) and compares the pixels. Writes `<scene>_sw.png`,
// `<scene>_gpu.png` and `<scene>_diff.png` into the output directory.
//
//     odin run tools/sdlgpu_parity -- [out_dir]
//
// `SDL_GPU_DRIVER=vulkan|metal|direct3d12` picks SDL's GPU driver.
package sdlgpu_parity

import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"

import vg "../.."
import vgsdl "../../sdlgpu"
import "../scenes"

main :: proc() {
	out_dir := os.args[1] if len(os.args) > 1 else "parity_out"
	os.make_directory(out_dir)

	gpu: vgsdl.SDL_Backend
	if err := vgsdl.init(&gpu); err != nil {
		fmt.eprintln("SDL_GPU backend init failed:", err, sdl.GetError())
		os.exit(2)
	}
	defer vgsdl.destroy(&gpu)
	fmt.println("SDL_GPU driver:", sdl.GetGPUDeviceDriver(gpu.device))

	sw: vg.Software_Backend
	vg.software_backend_init(&sw)
	defer vg.software_backend_destroy(&sw)

	sw_canvas, gpu_canvas: vg.Canvas
	vg.canvas_init(&sw_canvas, vg.software_backend(&sw))
	vg.canvas_init(&gpu_canvas, vgsdl.backend(&gpu))
	defer vg.canvas_destroy(&sw_canvas)
	defer vg.canvas_destroy(&gpu_canvas)
	sw_res, gpu_res: scenes.Resources
	scenes.setup(&sw_canvas, &sw_res)
	scenes.setup(&gpu_canvas, &gpu_res)
	defer scenes.resources_destroy(&sw_canvas, &sw_res)
	defer scenes.resources_destroy(&gpu_canvas, &gpu_res)

	failed := 0
	for scene in scenes.ALL {
		scenes.draw_frame(&sw_canvas, scene, &sw_res)
		vg.flush(&sw_canvas)
		a, _ := vg.screenshot(&sw_canvas)

		scenes.draw_frame(&gpu_canvas, scene, &gpu_res)
		vg.flush(&gpu_canvas)
		b, err := vg.screenshot(&gpu_canvas)
		if err != nil {
			fmt.eprintln("screenshot failed:", err)
			os.exit(2)
		}

		d := scenes.compare(a.pixels, b.pixels)
		if !scenes.report(out_dir, scene.name, "sw", "gpu", a.pixels, b.pixels, d) {
			failed += 1
		}
		delete(d.image)
		delete(a.pixels)
		delete(b.pixels)
	}
	// A caller-owned output texture, once submitted by the backend and once
	// recorded into the caller's command buffer.
	tex := sdl.CreateGPUTexture(
		gpu.device,
		{
			type = .D2,
			format = .R8G8B8A8_UNORM,
			usage = {.COLOR_TARGET, .SAMPLER},
			width = scenes.W,
			height = scenes.H,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)
	defer sdl.ReleaseGPUTexture(gpu.device, tex)
	scenes.draw_frame(&sw_canvas, scenes.ALL[0], &sw_res)
	vg.flush(&sw_canvas)
	a, _ := vg.screenshot(&sw_canvas)
	defer delete(a.pixels)
	for caller_submits in ([2]bool{false, true}) {
		out := vgsdl.Output {
			texture = tex,
			format  = .R8G8B8A8_UNORM,
			width   = scenes.W,
			height  = scenes.H,
		}
		if caller_submits {
			out.command_buffer = sdl.AcquireGPUCommandBuffer(gpu.device)
		}
		scenes.draw_frame(&gpu_canvas, scenes.ALL[0], &gpu_res)
		vg.flush(&gpu_canvas, vgsdl.output(&out))
		if caller_submits {
			_ = sdl.SubmitGPUCommandBuffer(out.command_buffer)
		}
		b, _ := vgsdl.read_texture(&gpu, {texture = tex, format = .R8G8B8A8_UNORM, width = scenes.W, height = scenes.H})
		d := scenes.compare(a.pixels, b)
		if !scenes.report(out_dir, "output_cb" if caller_submits else "output", "sw", "gpu", a.pixels, b, d) {
			failed += 1
		}
		delete(d.image)
		delete(b)
	}

	total := len(scenes.ALL) + 2
	fmt.printfln("%d/%d checks match (images in %s)", total - failed, total, out_dir)
	if failed > 0 {
		os.exit(1)
	}
}

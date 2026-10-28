package ovg

// Plays frames recorded on a recording canvas (`canvas_init_recording`,
// `canvas_take`) through a backend, on the thread that owns it: applies the
// frame's image and program work to a mirror of the canvas's images (same
// ids), then renders the frame as `flush` would. Several recording canvases
// can feed one backend in turn, each through its own player; frames from one
// canvas are played in the order they were taken.
Player :: struct {
	backend:  Backend,
	images:   Image_Store,
	// Backend programs by the recording canvas's program key index.
	programs: [dynamic]Backend_Program,
	shared:   ^Shared_Images,
	// The frame's program references while it renders (player_render).
	recorded: [dynamic]Backend_Program,
}

// Images players share (`create_image_shared`): one backend image per key,
// made by the first player that meets it and freed with the table. Use it
// on the backend's thread only.
Shared_Images :: struct {
	backend: Backend,
	images:  map[u64]Backend_Image,
}

shared_images_init :: proc(s: ^Shared_Images, backend: Backend, allocator := context.allocator) {
	s.backend = backend
	s.images = make(map[u64]Backend_Image, allocator)
}

// Frees the images; call after the players that used them are destroyed.
shared_images_destroy :: proc(s: ^Shared_Images) {
	for _, img in s.images {
		s.backend.delete_image(s.backend.data, img, {})
	}
	delete(s.images)
	s^ = {}
}

// Frees the image shared under `key`, if any, once no frame still to be
// played uses it (the players' ids for it are then stale).
shared_images_remove :: proc(s: ^Shared_Images, key: u64) {
	if img, found := s.images[key]; found {
		delete_key(&s.images, key)
		s.backend.delete_image(s.backend.data, img, {})
	}
}

// `shared` may be nil: shared images are then the player's own.
player_init :: proc(p: ^Player, backend: Backend, shared: ^Shared_Images = nil, allocator := context.allocator) {
	p^ = {backend = backend, shared = shared, programs = make([dynamic]Backend_Program, allocator), recorded = make([dynamic]Backend_Program, allocator)}
	image_store_init(&p.images, backend, allocator)
}

player_destroy :: proc(p: ^Player) {
	image_store_destroy(&p.images)
	if p.backend.delete_program != nil {
		for prog in p.programs {
			if prog != {} {
				p.backend.delete_program(p.backend.data, prog)
			}
		}
	}
	delete(p.programs)
	delete(p.recorded)
	p^ = {}
}

// Applies the frame's image and program work. Errors leave the image out,
// as a failed allocation on a canvas would. Call before `player_render`;
// `player_update_image` may write images in between.
player_apply :: proc(p: ^Player, f: ^Recorded_Frame) {
	for op in f.program_ops {
		for len(p.programs) <= int(op.key.idx) {
			append(&p.programs, Backend_Program{})
		}
		slot := &p.programs[op.key.idx]
		if slot^ != {} && p.backend.delete_program != nil {
			// Deleted, or a reused key index whose old program is gone.
			p.backend.delete_program(p.backend.data, slot^)
		}
		slot^ = {}
		if !op.delete && p.backend.create_program != nil {
			slot^, _ = p.backend.create_program(p.backend.data, op.desc)
		}
	}
	s := &p.images
	for op in f.image_ops {
		pixels := op.borrowed if op.borrowed != nil else f.pixels[op.copied.start:][:op.copied.count]
		src := Image_Source{op.info.format, pixels, op.width, op.height, 0}
		switch op.kind {
		case .Alloc:
			if img, err := p.backend.alloc_image(p.backend.data, op.info); err == nil {
				slot_map_put(&s.entries, op.id.key, Image_Entry{info = op.info, image = img})
			}
		case .Realloc:
			if image_store_get(s, op.id) == nil {
				if img, err := p.backend.alloc_image(p.backend.data, op.info); err == nil {
					slot_map_put(&s.entries, op.id.key, Image_Entry{info = op.info, image = img})
				}
			} else {
				image_store_realloc(s, op.id, op.info)
			}
		case .Update:
			image_store_update(s, op.id, src, op.x, op.y)
		case .Remove:
			image_store_remove(s, op.id)
		case .Share:
			player_share(p, op, src)
		}
	}
}

@(private = "file")
player_share :: proc(p: ^Player, op: Image_Op, src: Image_Source) {
	if p.backend.memory_images && op.borrowed != nil {
		slot_map_put(&p.images.entries, op.id.key, Image_Entry{info = op.info, image = {pixels = op.borrowed}, borrowed = true})
		return
	}
	if p.shared != nil {
		if img, ok := p.shared.images[op.key]; ok {
			slot_map_put(&p.images.entries, op.id.key, Image_Entry{info = op.info, image = img, borrowed = true})
			return
		}
	}
	img, err := p.backend.alloc_image(p.backend.data, op.info)
	if err != nil {
		return
	}
	if p.backend.update_image(p.backend.data, &img, op.info, src, 0, 0) != nil {
		p.backend.delete_image(p.backend.data, img, op.id)
		return
	}
	slot_map_put(&p.images.entries, op.id.key, Image_Entry{info = op.info, image = img, borrowed = p.shared != nil})
	if p.shared != nil {
		p.shared.images[op.key] = img
	}
}

// Writes pixels into an image of the frame being played (content the
// recording thread could not produce, e.g. decoded video).
player_update_image :: proc(p: ^Player, id: Image_Id, src: Image_Source, x, y: u32) -> Error {
	return image_store_update(&p.images, id, src, x, y)
}

player_image_info :: proc(p: ^Player, id: Image_Id) -> (Image_Info, bool) {
	return image_store_info(&p.images, id)
}

// Renders the frame as `flush` would have on the recording canvas. The
// frame is left as it was: it may be rendered again.
player_render :: proc(p: ^Player, f: ^Recorded_Frame, output: Render_Output = 0) {
	p.backend.set_size(p.backend.data, f.width, f.height, f.dpi)
	// Program commands hold the canvas's key index: the backend's program
	// stands in for it while the frame renders.
	clear(&p.recorded)
	for &run in f.runs {
		append(&p.recorded, run.program)
		h := int(run.program.handle)
		run.program = p.programs[h] if h < len(p.programs) else {}
	}
	p.backend.render(p.backend.data, output, &p.images, {paints = f.paints[:], commands = f.commands[:], bytes = f.bytes[:], filters = f.filters[:], runs = f.runs[:], shapes = f.shapes[:], shape_words = f.shape_words[:], motion = f.motion, motions = f.motions[:]})
	for &run, i in f.runs {
		run.program = p.recorded[i]
	}
}

// Copy of the screen the last frame rendered, as RGBA8, top-down.
player_screenshot :: proc(p: ^Player, allocator := context.allocator) -> (Screenshot, Error) {
	return p.backend.screenshot(p.backend.data, allocator)
}

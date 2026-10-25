package ovg

// Generational handle. The zero key is never issued, so a zero-valued
// handle (`Image_Id{}`) always means "none".
Key :: struct {
	idx: u32,
	gen: u32,
}

@(private)
NO_FREE_SLOT :: max(u32)

// Stable-handle arena: removing a slot bumps its generation so stale keys
// fail lookup.
Slot_Map :: struct($T: typeid) {
	slots:     [dynamic]Slot(T),
	free_head: u32,
	len:       u32,
}

Slot :: struct($T: typeid) {
	value:     T,
	gen:       u32,
	next_free: u32,
	occupied:  bool,
}

slot_map_init :: proc(m: ^Slot_Map($T), allocator := context.allocator) {
	m.slots = make([dynamic]Slot(T), allocator)
	m.free_head = NO_FREE_SLOT
	m.len = 0
}

slot_map_destroy :: proc(m: ^Slot_Map($T)) {
	delete(m.slots)
	m^ = {}
	m.free_head = NO_FREE_SLOT
}

slot_map_insert :: proc(m: ^Slot_Map($T), value: T) -> Key {
	m.len += 1
	if m.free_head != NO_FREE_SLOT {
		idx := m.free_head
		slot := &m.slots[idx]
		m.free_head = slot.next_free
		slot.value = value
		slot.occupied = true
		return {idx, slot.gen}
	}
	append(&m.slots, Slot(T){value = value, gen = 1, occupied = true})
	return {u32(len(m.slots) - 1), 1}
}

slot_map_get :: proc(m: ^Slot_Map($T), key: Key) -> ^T {
	if int(key.idx) >= len(m.slots) {
		return nil
	}
	slot := &m.slots[key.idx]
	if !slot.occupied || slot.gen != key.gen {
		return nil
	}
	return &slot.value
}

slot_map_remove :: proc(m: ^Slot_Map($T), key: Key) -> (value: T, ok: bool) {
	if int(key.idx) >= len(m.slots) {
		return
	}
	slot := &m.slots[key.idx]
	if !slot.occupied || slot.gen != key.gen {
		return
	}
	value = slot.value
	slot.value = {}
	slot.occupied = false
	slot.gen += 1
	if slot.gen == 0 {
		slot.gen = 1
	}
	slot.next_free = m.free_head
	m.free_head = key.idx
	m.len -= 1
	return value, true
}

// Stores `value` under a key another map issued (a mirror of a recording
// canvas's images): grows the slots and takes the key's generation. A map
// filled this way never issues keys itself.
slot_map_put :: proc(m: ^Slot_Map($T), key: Key, value: T) {
	for len(m.slots) <= int(key.idx) {
		append(&m.slots, Slot(T){})
	}
	slot := &m.slots[key.idx]
	if !slot.occupied {
		m.len += 1
	}
	slot^ = {value = value, gen = key.gen, next_free = NO_FREE_SLOT, occupied = true}
}

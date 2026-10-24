package ovg

import cv "curves"

// Booleans of filled paths that keep their curves (curves/bool.odin): the
// pieces of the result follow the operands' own lines and cubics, cut where
// they meet.

Bool_Op :: cv.Bool_Op
Bool_Error :: cv.Bool_Error

Bool_Operand :: struct {
	path: ^Path,
	rule: Fill_Rule,
}

// Warm scratch for path booleans, kept by the caller: no allocation once
// warm. After a call, provenance of the result's segment i (in the order
// they were appended): it comes from verb `verbs[core.out_row[i]]` of its
// operand's path (a, then b), over core.out_t[i] of that segment's
// parameter; out_row max(u32) marks a closing line of an open contour.
Bool_Scratch :: struct {
	core:   cv.Bool_Scratch,
	input:  cv.Contours,
	verbs:  [dynamic]u32,
	inputs: [dynamic]cv.Bool_Input,
}

bool_scratch_destroy :: proc(s: ^Bool_Scratch) {
	cv.bool_scratch_destroy(&s.core)
	cv.contours_destroy(&s.input)
	delete(s.verbs)
	delete(s.inputs)
}

// Appends `a op b` to `out`: Solid-wound contours, holes reversed, none
// crossing another, so either fill rule fills the result alike. Difference
// is a minus b. On an error `out` is unchanged.
path_boolean :: proc(out: ^Path, a, b: Bool_Operand, op: Bool_Op, s: ^Bool_Scratch, max_steps := DEFAULT_LIMITS[.Boolean_Steps]) -> Bool_Error {
	ops := [2]Bool_Operand{a, b}
	return path_boolean_many(out, ops[:], op, s, max_steps)
}

// Appends `a` with its overlaps and self-crossings resolved under its fill
// rule (a union of one).
path_simplify :: proc(out: ^Path, a: Bool_Operand, s: ^Bool_Scratch, max_steps := DEFAULT_LIMITS[.Boolean_Steps]) -> Bool_Error {
	ops := [1]Bool_Operand{a}
	return path_boolean_many(out, ops[:], .Union, s, max_steps)
}

// `op` over any number of operands: union of all, the first minus the
// rest, the intersection of all, or the parts inside an odd number.
path_boolean_many :: proc(out: ^Path, operands: []Bool_Operand, op: Bool_Op, s: ^Bool_Scratch, max_steps := DEFAULT_LIMITS[.Boolean_Steps]) -> Bool_Error {
	cv.contours_clear(&s.input)
	clear(&s.verbs)
	clear(&s.inputs)
	for o in operands {
		first := u32(len(s.input.contours))
		contours_append_path(&s.input, o.path, verbs = &s.verbs)
		append(&s.inputs, cv.Bool_Input{first, u32(len(s.input.contours)) - first, o.rule == .Even_Odd})
	}
	budget := max_steps
	cv.bool_run(&s.core, &s.input, s.inputs[:], op, &budget) or_return
	path_append_contours(out, &s.core.out, 0, u32(len(s.core.out.contours)))
	return nil
}

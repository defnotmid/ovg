package ovg

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"

import cv "deps:ocurves"

// Limits on the work one file can cause: SVG and Lottie input may come from
// anyone, and a few hundred bytes can ask for billions of nodes, dashes or
// copies. Each limit is a row of one table: what it counts, whether it caps
// one item (`Max`) or a running total (`Total`), and its default. A parser or
// renderer keeps a `Budget`; when a limit is reached the work it guards is
// cut short and the limit is recorded (`Budget.hit`, one warning per limit
// in a document's `warnings`).
//
// Fonts are not covered: ovg/font and ovg/shape check every read, and
// shaping bounds its own work (the buffer's growth and lookup steps per
// character, as HarfBuzz does).
Limit :: enum u8 {
	// Nesting of SVG elements, of Lottie JSON and of Lottie shape groups.
	Depth,
	// Elements converted for one SVG document, <use> copies and SVG images
	// included.
	Svg_Elements,
	// Selector match steps of one SVG document's CSS cascade.
	Css_Steps,
	// Primitives of one SVG filter (each is a pass over the layer).
	Filter_Primitives,
	// feTurbulence numOctaves.
	Turbulence_Octaves,
	// Points of one Lottie star or polygon.
	Star_Points,
	// Repeater copies drawn by one `lottie.draw`, nested repeaters multiplied.
	Repeater_Copies,
	// Layers drawn by one `lottie.draw`, every precomp instance's included.
	Lottie_Layers,
	// Dashes of one stroke.
	Dash_Segments,
	// Paint records walked for one COLR glyph.
	Colr_Paints,
	// Pixels of one decoded image.
	Image_Pixels,
	// Work of one path boolean: curve comparisons and snap rounds.
	Boolean_Steps,
}

Limits :: [Limit]int

Limit_Kind :: enum u8 {
	// The limit caps one value (a depth, a count asked for).
	Max,
	// The limit caps a running total over a parse or a draw.
	Total,
}

Limit_Info :: struct {
	name: string,
	kind: Limit_Kind,
}

LIMIT_INFO :: [Limit]Limit_Info {
	.Depth              = {"nesting depth", .Max},
	.Svg_Elements       = {"SVG elements", .Total},
	.Css_Steps          = {"CSS selector steps", .Total},
	.Filter_Primitives  = {"filter primitives", .Max},
	.Turbulence_Octaves = {"feTurbulence octaves", .Max},
	.Star_Points        = {"star points", .Max},
	.Repeater_Copies    = {"repeater copies per draw", .Total},
	.Lottie_Layers      = {"Lottie layers per draw", .Total},
	.Dash_Segments      = {"dashes per stroke", .Total},
	.Colr_Paints        = {"COLR paints per glyph", .Total},
	.Image_Pixels       = {"image pixels", .Max},
	.Boolean_Steps      = {"boolean work", .Total},
}

// Far above what real files use; each bounds memory and time to what a
// desktop handles.
DEFAULT_LIMITS :: Limits {
	.Depth              = 256,
	.Svg_Elements       = 250_000,
	.Css_Steps          = 50_000_000,
	.Filter_Primitives  = 256,
	.Turbulence_Octaves = 24,
	.Star_Points        = 10_000,
	.Repeater_Copies    = 20_000,
	.Lottie_Layers      = 20_000,
	.Dash_Segments      = 100_000,
	.Colr_Paints        = 65_536,
	.Image_Pixels       = 1 << 26,
	.Boolean_Steps      = cv.DEFAULT_BUDGET,
}

Budget :: struct {
	limits: Limits,
	used:   Limits,
	// The limits reached.
	hit:    bit_set[Limit],
}

// Starts a budget: `limits`, or DEFAULT_LIMITS when nil.
budget_init :: proc "contextless" (b: ^Budget, limits: ^Limits = nil) {
	b^ = {limits = limits^ if limits != nil else DEFAULT_LIMITS}
}

// Starts the running totals over, keeping the limits and what was hit.
budget_reset :: proc "contextless" (b: ^Budget) {
	b.used = {}
}

// Counts `n` more of a `Total` limit; false (and recorded) when that would
// pass the limit, and nothing is counted.
budget_take :: #force_inline proc "contextless" (b: ^Budget, l: Limit, n := 1) -> bool {
	if b.used[l] + n > b.limits[l] {
		b.hit += {l}
		return false
	}
	b.used[l] += n
	return true
}

// Counts up to `n` more of a `Total` limit: how many fit (all of `n`, or
// what is left, recorded).
budget_take_up_to :: #force_inline proc "contextless" (b: ^Budget, l: Limit, n: int) -> int {
	got := clamp(b.limits[l] - b.used[l], 0, n)
	if got < n {
		b.hit += {l}
	}
	b.used[l] += got
	return got
}

// `v` capped by a `Max` limit, recording the limit when it cuts.
budget_cap :: #force_inline proc "contextless" (b: ^Budget, l: Limit, v: int) -> int {
	if v > b.limits[l] {
		b.hit += {l}
		return b.limits[l]
	}
	return v
}

// Whether `v` passes a `Max` limit (recorded).
budget_over :: #force_inline proc "contextless" (b: ^Budget, l: Limit, v: int) -> bool {
	if v > b.limits[l] {
		b.hit += {l}
		return true
	}
	return false
}

// Appends one warning per limit hit, its strings from `allocator`.
budget_warn :: proc(b: ^Budget, warnings: ^[dynamic]string, allocator: mem.Allocator) {
	// What this puts on the temp allocator goes when it returns (unless the
	// warnings are the temp allocator's).
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	info := LIMIT_INFO
	for l in b.hit {
		append(warnings, strings.clone(fmt.tprintf("limit reached: %s (%d); the rest is skipped", info[l].name, b.limits[l]), allocator))
	}
}

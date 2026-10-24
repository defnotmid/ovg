package ovg

import "core:unicode"

import sh "shape"

// Bidi levels of a line in a left-to-right paragraph (UAX #9 without
// explicit embeddings or bracket pairs): weak types resolved (W1-W7),
// neutrals between text of one direction take it and others the
// paragraph's (N1, N2), then levels 0 (L), 1 (R) and 2 (numbers in R text).

// UAX #9's classes, reduced: B, S, WS and ON are one neutral class.
@(private)
Bidi_Class :: enum u8 {
	L,
	R,
	AL,
	EN,
	AN,
	ES,
	CS,
	ET,
	NSM,
	BN,
	ON,
}

// The class of `r`, whose letters' direction comes from their script.
@(private)
bidi_class :: proc(r: rune, script: sh.Script) -> Bidi_Class {
	switch r {
	case '0' ..= '9', 0xB2, 0xB3, 0xB9, 0x06F0 ..= 0x06F9, 0x2070, 0x2074 ..= 0x2079, 0x2080 ..= 0x2089, 0xFF10 ..= 0xFF19:
		return .EN
	case 0x0660 ..= 0x0669, 0x066B, 0x066C, 0x10E60 ..= 0x10E7E:
		return .AN
	case '+', '-', 0x207A, 0x207B, 0x208A, 0x208B, 0x2212, 0xFB29, 0xFE62, 0xFE63, 0xFF0B, 0xFF0D:
		return .ES
	case ',', '.', '/', ':', 0xA0, 0x060C, 0x202F, 0x2044, 0xFE50, 0xFE52, 0xFE55, 0xFF0C, 0xFF0E, 0xFF0F, 0xFF1A:
		return .CS
	case '#', '$', '%', 0xA2 ..= 0xA5, 0xB0, 0xB1, 0x0609, 0x060A, 0x066A, 0x09F2, 0x09F3, 0x0AF1, 0x0BF9, 0x0E3F, 0x17DB, 0x2030 ..= 0x2034, 0x20A0 ..= 0x20CF, 0x212E, 0x2213, 0xFE5F, 0xFE69, 0xFE6A, 0xFF03 ..= 0xFF05, 0xFFE0, 0xFFE1, 0xFFE5, 0xFFE6:
		return .ET
	case 0x200E:
		return .L // left-to-right mark
	case 0x200F:
		return .R // right-to-left mark
	case 0x061C:
		return .AL // Arabic letter mark
	case 0x200B ..= 0x200D, 0x2060 ..= 0x2064, 0xFEFF, 0xFE00 ..= 0xFE0F, 0xE0000 ..= 0xE0FFF:
		// Joiners, variation selectors and tags go with what they follow.
		return .BN
	}
	if unicode.is_nonspacing_mark(r) || unicode.is_enclosing_mark(r) {
		return .NSM
	}
	if unicode.is_letter(r) || unicode.is_spacing_mark(r) || unicode.is_digit(r) {
		if !sh.script_is_rtl(script) {
			return .L
		}
		#partial switch script {
		case .Arabic, .Syriac, .Thaana, .Hanifi_Rohingya:
			return .AL
		}
		return .R
	}
	return .ON
}

// Resolves `cls` (rewritten) into `level`.
@(private)
bidi_resolve :: proc(cls: []Bidi_Class, level: []u8) {
	n := len(cls)
	// W1: marks and ignored format characters take the class before them.
	prev := Bidi_Class.L
	for &c in cls {
		if c == .NSM || c == .BN {
			c = prev
		}
		prev = c
	}
	// W2: European numbers after Arabic letters are Arabic numbers. W3:
	// Arabic letters are R.
	strong := Bidi_Class.L
	for &c in cls {
		#partial switch c {
		case .L, .R, .AL:
			strong = c
		case .EN:
			if strong == .AL {
				c = .AN
			}
		}
		if c == .AL {
			c = .R
		}
	}
	// W4: one separator between two numbers of a kind joins them.
	for i in 1 ..< n - 1 {
		a, b := cls[i - 1], cls[i + 1]
		if cls[i] == .ES && a == .EN && b == .EN {
			cls[i] = .EN
		} else if cls[i] == .CS && a == b && (a == .EN || a == .AN) {
			cls[i] = a
		}
	}
	// W5: terminators next to European numbers join them.
	for i := 0; i < n; {
		if cls[i] != .ET {
			i += 1
			continue
		}
		j := i
		for j < n && cls[j] == .ET {
			j += 1
		}
		if (i > 0 && cls[i - 1] == .EN) || (j < n && cls[j] == .EN) {
			for k in i ..< j {
				cls[k] = .EN
			}
		}
		i = j
	}
	// W6: other separators and terminators are neutral. W7: European
	// numbers after L text (or the paragraph start) are L.
	strong = .L
	for &c in cls {
		#partial switch c {
		case .ES, .CS, .ET:
			c = .ON
		case .L, .R:
			strong = c
		case .EN:
			if strong == .L {
				c = .L
			}
		}
	}
	// N1, N2: neutrals between text of one direction take it (numbers count
	// as R); others take the paragraph's, L.
	dir :: proc "contextless" (c: Bidi_Class) -> Bidi_Class {
		return .L if c == .L else .R
	}
	for i := 0; i < n; {
		if cls[i] != .ON {
			i += 1
			continue
		}
		j := i
		for j < n && cls[j] == .ON {
			j += 1
		}
		before := Bidi_Class.L if i == 0 else dir(cls[i - 1])
		after := Bidi_Class.L if j == n else dir(cls[j])
		d := before if before == after else Bidi_Class.L
		for k in i ..< j {
			cls[k] = d
		}
		i = j
	}
	// I1.
	for c, i in cls {
		level[i] = 0 if c == .L else 1 if c == .R else 2
	}
}

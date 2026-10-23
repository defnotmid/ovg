package font

import "base:runtime"

// Glyph names, for a glyph browser: post's (TrueType) or the CFF charset's.

// Sets `out[g]` to the name of each glyph g below len(out): a slice of the
// font data or a static string, "" when the face names none (post format 3,
// a CID-keyed CFF, whose charset holds CIDs). All at once, since post's
// names are found only by walking its strings.
glyph_names :: proc(f: ^Face, out: []string) {
	for &n in out {
		n = ""
	}
	if f.cff.table != nil {
		cff_glyph_names(&f.cff, out)
		return
	}
	post := f.tables[.post]
	d := f.data[post.at:][:post.size]
	switch read_u32(d, 0) {
	case 0x10000:
		copy(out, MAC_GLYPH_NAMES[:])
	case 0x20000:
		count := int(read_u16(d, 32))
		index := records_clamped(d, 34, count, U16)
		// Pascal strings follow the indexes: the kth is name 258 + k.
		first := 34 + 2 * count
		n := 0
		for at := first; at < len(d) && at + 1 + int(d[at]) <= len(d); at += 1 + int(d[at]) {
			n += 1
		}
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		custom := make([]string, n, context.temp_allocator)
		at := first
		for &s in custom {
			s = string(d[at + 1:][:d[at]])
			at += 1 + int(d[at])
		}
		for x, g in index[:min(len(index), len(out))] {
			if k := int(x.v); k < len(MAC_GLYPH_NAMES) {
				out[g] = MAC_GLYPH_NAMES[k]
			} else if k - len(MAC_GLYPH_NAMES) < len(custom) {
				out[g] = custom[k - len(MAC_GLYPH_NAMES)]
			}
		}
	}
}

@(private)
cff_glyph_names :: proc(c: ^Cff, out: []string) {
	if c.fontdicts != nil || len(out) == 0 {
		return
	}
	name :: proc(c: ^Cff, sid: int) -> string {
		if sid < len(CFF_STRINGS) {
			return CFF_STRINGS[sid]
		}
		return string(index_get(c.strings, sid - len(CFF_STRINGS)))
	}
	out[0] = ".notdef"
	switch c.charset {
	case 0:
		// ISOAdobe: glyph g is SID g.
		copy(out[1:], CFF_STRINGS[1:229])
	case 1, 2:
	// The Expert sets, for expert fonts only: not named here.
	case:
		// The glyphs past .notdef: a SID each (format 0), or ranges of
		// consecutive SIDs with an 8-bit (1) or 16-bit (2) count after the
		// first.
		b := Buf{c.table, c.charset}
		format := get8(&b)
		if format > 2 {
			return
		}
		for g := 1; g < len(out) && b.pos < len(b.d); {
			if format == 0 {
				out[g] = name(c, get(&b, 2))
				g += 1
				continue
			}
			sid := get(&b, 2)
			left := get(&b, format)
			for _ in 0 ..= left {
				if g == len(out) {
					break
				}
				out[g] = name(c, sid)
				g, sid = g + 1, sid + 1
			}
		}
	}
}

// The standard Macintosh glyph names (post formats 1 and 2).
@(private, rodata)
MAC_GLYPH_NAMES := [258]string{
	".notdef", ".null", "nonmarkingreturn", "space", "exclam", "quotedbl", "numbersign", "dollar",
	"percent", "ampersand", "quotesingle", "parenleft", "parenright", "asterisk", "plus", "comma",
	"hyphen", "period", "slash", "zero", "one", "two", "three", "four", "five", "six", "seven",
	"eight", "nine", "colon", "semicolon", "less", "equal", "greater", "question", "at", "A", "B",
	"C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U",
	"V", "W", "X", "Y", "Z", "bracketleft", "backslash", "bracketright", "asciicircum", "underscore",
	"grave", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r",
	"s", "t", "u", "v", "w", "x", "y", "z", "braceleft", "bar", "braceright", "asciitilde",
	"Adieresis", "Aring", "Ccedilla", "Eacute", "Ntilde", "Odieresis", "Udieresis", "aacute",
	"agrave", "acircumflex", "adieresis", "atilde", "aring", "ccedilla", "eacute", "egrave",
	"ecircumflex", "edieresis", "iacute", "igrave", "icircumflex", "idieresis", "ntilde", "oacute",
	"ograve", "ocircumflex", "odieresis", "otilde", "uacute", "ugrave", "ucircumflex", "udieresis",
	"dagger", "degree", "cent", "sterling", "section", "bullet", "paragraph", "germandbls",
	"registered", "copyright", "trademark", "acute", "dieresis", "notequal", "AE", "Oslash",
	"infinity", "plusminus", "lessequal", "greaterequal", "yen", "mu", "partialdiff", "summation",
	"product", "pi", "integral", "ordfeminine", "ordmasculine", "Omega", "ae", "oslash",
	"questiondown", "exclamdown", "logicalnot", "radical", "florin", "approxequal", "Delta",
	"guillemotleft", "guillemotright", "ellipsis", "nonbreakingspace", "Agrave", "Atilde", "Otilde",
	"OE", "oe", "endash", "emdash", "quotedblleft", "quotedblright", "quoteleft", "quoteright",
	"divide", "lozenge", "ydieresis", "Ydieresis", "fraction", "currency", "guilsinglleft",
	"guilsinglright", "fi", "fl", "daggerdbl", "periodcentered", "quotesinglbase", "quotedblbase",
	"perthousand", "Acircumflex", "Ecircumflex", "Aacute", "Edieresis", "Egrave", "Iacute",
	"Icircumflex", "Idieresis", "Igrave", "Oacute", "Ocircumflex", "apple", "Ograve", "Uacute",
	"Ucircumflex", "Ugrave", "dotlessi", "circumflex", "tilde", "macron", "breve", "dotaccent",
	"ring", "cedilla", "hungarumlaut", "ogonek", "caron", "Lslash", "lslash", "Scaron", "scaron",
	"Zcaron", "zcaron", "brokenbar", "Eth", "eth", "Yacute", "yacute", "Thorn", "thorn", "minus",
	"multiply", "onesuperior", "twosuperior", "threesuperior", "onehalf", "onequarter",
	"threequarters", "franc", "Gbreve", "gbreve", "Idotaccent", "Scedilla", "scedilla", "Cacute",
	"cacute", "Ccaron", "ccaron", "dcroat",
}

// CFF's standard strings: SIDs below 391.
@(private, rodata)
CFF_STRINGS := [391]string{
	".notdef", "space", "exclam", "quotedbl", "numbersign", "dollar", "percent", "ampersand",
	"quoteright", "parenleft", "parenright", "asterisk", "plus", "comma", "hyphen", "period", "slash",
	"zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "colon",
	"semicolon", "less", "equal", "greater", "question", "at", "A", "B", "C", "D", "E", "F", "G", "H",
	"I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
	"bracketleft", "backslash", "bracketright", "asciicircum", "underscore", "quoteleft", "a", "b",
	"c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u",
	"v", "w", "x", "y", "z", "braceleft", "bar", "braceright", "asciitilde", "exclamdown", "cent",
	"sterling", "fraction", "yen", "florin", "section", "currency", "quotesingle", "quotedblleft",
	"guillemotleft", "guilsinglleft", "guilsinglright", "fi", "fl", "endash", "dagger", "daggerdbl",
	"periodcentered", "paragraph", "bullet", "quotesinglbase", "quotedblbase", "quotedblright",
	"guillemotright", "ellipsis", "perthousand", "questiondown", "grave", "acute", "circumflex",
	"tilde", "macron", "breve", "dotaccent", "dieresis", "ring", "cedilla", "hungarumlaut", "ogonek",
	"caron", "emdash", "AE", "ordfeminine", "Lslash", "Oslash", "OE", "ordmasculine", "ae",
	"dotlessi", "lslash", "oslash", "oe", "germandbls", "onesuperior", "logicalnot", "mu",
	"trademark", "Eth", "onehalf", "plusminus", "Thorn", "onequarter", "divide", "brokenbar",
	"degree", "thorn", "threequarters", "twosuperior", "registered", "minus", "eth", "multiply",
	"threesuperior", "copyright", "Aacute", "Acircumflex", "Adieresis", "Agrave", "Aring", "Atilde",
	"Ccedilla", "Eacute", "Ecircumflex", "Edieresis", "Egrave", "Iacute", "Icircumflex", "Idieresis",
	"Igrave", "Ntilde", "Oacute", "Ocircumflex", "Odieresis", "Ograve", "Otilde", "Scaron", "Uacute",
	"Ucircumflex", "Udieresis", "Ugrave", "Yacute", "Ydieresis", "Zcaron", "aacute", "acircumflex",
	"adieresis", "agrave", "aring", "atilde", "ccedilla", "eacute", "ecircumflex", "edieresis",
	"egrave", "iacute", "icircumflex", "idieresis", "igrave", "ntilde", "oacute", "ocircumflex",
	"odieresis", "ograve", "otilde", "scaron", "uacute", "ucircumflex", "udieresis", "ugrave",
	"yacute", "ydieresis", "zcaron", "exclamsmall", "Hungarumlautsmall", "dollaroldstyle",
	"dollarsuperior", "ampersandsmall", "Acutesmall", "parenleftsuperior", "parenrightsuperior",
	"twodotenleader", "onedotenleader", "zerooldstyle", "oneoldstyle", "twooldstyle", "threeoldstyle",
	"fouroldstyle", "fiveoldstyle", "sixoldstyle", "sevenoldstyle", "eightoldstyle", "nineoldstyle",
	"commasuperior", "threequartersemdash", "periodsuperior", "questionsmall", "asuperior",
	"bsuperior", "centsuperior", "dsuperior", "esuperior", "isuperior", "lsuperior", "msuperior",
	"nsuperior", "osuperior", "rsuperior", "ssuperior", "tsuperior", "ff", "ffi", "ffl",
	"parenleftinferior", "parenrightinferior", "Circumflexsmall", "hyphensuperior", "Gravesmall",
	"Asmall", "Bsmall", "Csmall", "Dsmall", "Esmall", "Fsmall", "Gsmall", "Hsmall", "Ismall",
	"Jsmall", "Ksmall", "Lsmall", "Msmall", "Nsmall", "Osmall", "Psmall", "Qsmall", "Rsmall",
	"Ssmall", "Tsmall", "Usmall", "Vsmall", "Wsmall", "Xsmall", "Ysmall", "Zsmall", "colonmonetary",
	"onefitted", "rupiah", "Tildesmall", "exclamdownsmall", "centoldstyle", "Lslashsmall",
	"Scaronsmall", "Zcaronsmall", "Dieresissmall", "Brevesmall", "Caronsmall", "Dotaccentsmall",
	"Macronsmall", "figuredash", "hypheninferior", "Ogoneksmall", "Ringsmall", "Cedillasmall",
	"questiondownsmall", "oneeighth", "threeeighths", "fiveeighths", "seveneighths", "onethird",
	"twothirds", "zerosuperior", "foursuperior", "fivesuperior", "sixsuperior", "sevensuperior",
	"eightsuperior", "ninesuperior", "zeroinferior", "oneinferior", "twoinferior", "threeinferior",
	"fourinferior", "fiveinferior", "sixinferior", "seveninferior", "eightinferior", "nineinferior",
	"centinferior", "dollarinferior", "periodinferior", "commainferior", "Agravesmall", "Aacutesmall",
	"Acircumflexsmall", "Atildesmall", "Adieresissmall", "Aringsmall", "AEsmall", "Ccedillasmall",
	"Egravesmall", "Eacutesmall", "Ecircumflexsmall", "Edieresissmall", "Igravesmall", "Iacutesmall",
	"Icircumflexsmall", "Idieresissmall", "Ethsmall", "Ntildesmall", "Ogravesmall", "Oacutesmall",
	"Ocircumflexsmall", "Otildesmall", "Odieresissmall", "OEsmall", "Oslashsmall", "Ugravesmall",
	"Uacutesmall", "Ucircumflexsmall", "Udieresissmall", "Yacutesmall", "Thornsmall",
	"Ydieresissmall", "001.000", "001.001", "001.002", "001.003", "Black", "Bold", "Book", "Light",
	"Medium", "Regular", "Roman", "Semibold",
}
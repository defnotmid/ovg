# Builds assets/colr_test.ttf, the tiny COLR/CPAL font of ovg's colour
# glyph tests (fontTools):  python3 tools/colr_test_font/build.py
#
#   A  COLRv0: red square, foreground (0xFFFF) inner square
#   B  COLRv1: square, linear gradient red -> blue, left to right
#   C  COLRv1: square, sweep gradient red -> blue around the centre
#   D  COLRv1: green square, then the inner square in the foreground at
#      alpha 0.5, translated 100 units right
#   E  COLRv1: SRC_IN composite: linear gradient in the inner square's shape
#   F  COLRv1: square, radial gradient red (centre) -> blue
import os
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.colorLib.builder import buildCOLR, buildCPAL
from fontTools.ttLib.tables.otTables import PaintFormat, ExtendMode, CompositeMode

def rect(x0, y0, x1, y1):
    pen = TTGlyphPen(None)
    pen.moveTo((x0, y0)); pen.lineTo((x0, y1)); pen.lineTo((x1, y1)); pen.lineTo((x1, y0)); pen.closePath()
    return pen.glyph()

order = [".notdef", "full", "inner", "A", "B", "C", "D", "E", "F"]
fb = FontBuilder(1000, isTTF=True)
fb.setupGlyphOrder(order)
fb.setupCharacterMap({ord(c): c for c in "ABCDEF"})
empty = TTGlyphPen(None).glyph()
glyphs = {g: empty for g in order}
glyphs[".notdef"] = rect(100, 0, 900, 800)
glyphs["full"] = rect(100, 0, 900, 800)
glyphs["inner"] = rect(300, 200, 700, 600)
fb.setupGlyf(glyphs)
# Each side bearing is the glyph's xMin, as glyf and hmtx must agree.
glyf = fb.font["glyf"]
fb.setupHorizontalMetrics({g: (1000, getattr(glyf[g], "xMin", 0)) for g in order})
fb.setupHorizontalHeader(ascent=800, descent=-200)
fb.setupNameTable({"familyName": "ColrTest", "styleName": "Regular"})
fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
fb.setupPost()

def line(*stops):
    return {"Extend": ExtendMode.PAD, "ColorStop": [{"StopOffset": o, "PaletteIndex": i, "Alpha": 1.0} for o, i in stops]}

def glyph(name, paint):
    return {"Format": PaintFormat.PaintGlyph, "Glyph": name, "Paint": paint}

linear = {"Format": PaintFormat.PaintLinearGradient, "ColorLine": line((0, 0), (1, 1)), "x0": 100, "y0": 0, "x1": 900, "y1": 0, "x2": 100, "y2": 800}
colr = {
    "A": [("full", 0), ("inner", 0xFFFF)],
    "B": glyph("full", linear),
    "C": glyph("full", {"Format": PaintFormat.PaintSweepGradient, "ColorLine": line((0, 0), (1, 1)), "centerX": 500, "centerY": 400, "startAngle": 0, "endAngle": 360}),
    "D": {"Format": PaintFormat.PaintColrLayers, "Layers": [
        glyph("full", {"Format": PaintFormat.PaintSolid, "PaletteIndex": 2, "Alpha": 1.0}),
        {"Format": PaintFormat.PaintTranslate, "dx": 100, "dy": 0, "Paint": glyph("inner", {"Format": PaintFormat.PaintSolid, "PaletteIndex": 0xFFFF, "Alpha": 0.5})},
    ]},
    "E": {"Format": PaintFormat.PaintComposite, "CompositeMode": CompositeMode.SRC_IN, "SourcePaint": linear,
          "BackdropPaint": glyph("inner", {"Format": PaintFormat.PaintSolid, "PaletteIndex": 2, "Alpha": 1.0})},
    "F": glyph("full", {"Format": PaintFormat.PaintRadialGradient, "ColorLine": line((0, 0), (1, 1)), "x0": 500, "y0": 400, "r0": 0, "x1": 500, "y1": 400, "r1": 400}),
}
fb.font["COLR"] = buildCOLR(colr, glyphMap=fb.font.getReverseGlyphMap(), clipBoxes={"B": (100, 0, 900, 800)})
fb.font["CPAL"] = buildCPAL([[(1, 0, 0, 1), (0, 0, 1, 1), (0, 1, 0, 1)]])
out = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "colr_test.ttf")
fb.save(out)
print("wrote", os.path.normpath(out), os.path.getsize(out), "bytes")

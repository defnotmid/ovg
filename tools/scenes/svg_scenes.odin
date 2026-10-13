package scenes

import vg "../.."

// The SVG importer (svg.odin) on both backends: shapes, gradients (focal
// radial, spread), a pattern, clip paths, a mask, dashes and caps, text, an
// sRGB drop shadow with a filter region, opacity and an override.
SVG_SCENE :: `<svg xmlns="http://www.w3.org/2000/svg" width="256" height="192" viewBox="0 0 256 192">
  <defs>
    <linearGradient id="lg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#f97316"/>
      <stop offset="0.5" stop-color="#fde047" stop-opacity="0.6"/>
      <stop offset="1" stop-color="#22c55e"/>
    </linearGradient>
    <radialGradient id="rg" cx="0.5" cy="0.5" r="0.5" fx="0.3" fy="0.3" spreadMethod="reflect">
      <stop offset="0" stop-color="#ffffff"/>
      <stop offset="1" stop-color="#2563eb"/>
    </radialGradient>
    <pattern id="pat" width="12" height="12" patternUnits="userSpaceOnUse">
      <rect width="6" height="6" fill="#7c3aed"/>
      <circle cx="9" cy="9" r="3" fill="#f472b6"/>
    </pattern>
    <clipPath id="clip"><circle cx="190" cy="50" r="34"/></clipPath>
    <clipPath id="clip2"><rect x="20" y="110" width="40" height="60"/><rect x="70" y="110" width="20" height="60"/></clipPath>
    <mask id="mask"><rect x="100" y="100" width="70" height="80" fill="url(#lg)"/></mask>
    <filter id="shadow" x="-10%" y="-10%" width="130%" height="140%" color-interpolation-filters="sRGB">
      <feDropShadow dx="3" dy="4" stdDeviation="3" flood-color="#000" flood-opacity="0.5"/>
    </filter>
  </defs>
  <rect x="8" y="8" width="100" height="80" rx="12" fill="url(#lg)" stroke="#1e293b" stroke-width="2"/>
  <ellipse cx="190" cy="50" rx="60" ry="40" fill="url(#pat)" clip-path="url(#clip)"/>
  <circle id="ball" cx="140" cy="60" r="22" fill="url(#rg)" filter="url(#shadow)"/>
  <g clip-path="url(#clip2)" opacity="0.8">
    <rect x="10" y="100" width="100" height="80" fill="#0ea5e9"/>
    <path d="M10 180 L60 105 L110 180 Z" fill="#facc15"/>
  </g>
  <rect x="100" y="100" width="70" height="80" fill="#dc2626" mask="url(#mask)"/>
  <path d="M180 110 Q 210 90 240 120 T 240 170" fill="none" stroke="#0f172a" stroke-width="6"
        stroke-dasharray="10 6 0 6" stroke-linecap="round"/>
  <text x="182" y="185" font-family="Bitstream Vera Sans" font-size="16" fill="#334155">Svg</text>
</svg>`

@(private = "file")
svg_overrides := [?]vg.Svg_Override{{id = "ball", transform = vg.Transform2D{1, 0, 0, 1, -6, 4}, opacity = 0.9}}

scene_svg :: proc(c: ^vg.Canvas, r: ^Resources) {
	if !r.svg_ready {
		r.svg_doc, _ = vg.svg_parse(transmute([]u8)string(SVG_SCENE), {fonts = &r.svg_fonts})
		vg.svg_layout(&r.svg_doc, &r.svg_fonts, &r.svg_text)
		r.svg_ready = true
	}
	vg.layer_stack_begin(&r.layers, c, W, H)
	vg.svg_draw(c, &r.layers, &r.svg, &r.svg_doc, &r.svg_text, vg.TRANSFORM_IDENTITY, svg_overrides[:])
	vg.layer_stack_end(&r.layers, c)
}

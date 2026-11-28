// What the shape units (shape.frag, group.frag, markers.frag) share, after
// common.glsl and ocurves' curves.glsl (curves.GLSL): the instances, the
// shapes' words and the instances' motion.
//
// A shape instance is a quad over the shape's bounds, grown by a pixel,
// whose fragments compute coverage from the shape's curves (`shape_coverage`
// in shape.odin is the same steps). The instances and the shapes come from
// storage buffers: no vertex input.

// Shape units to drawing coordinates (m: a b c d; t.xy: translation), the
// shape units one pixel spans per axis (t.zw), the shape's bounds, the
// pixel's sides in shape units (uv: u.xy, v.xy: its footprint), its word
// offset in `shapes`, paint row and flags (bit 0: even-odd; bit 1:
// aliased, the pixel centre's winding; bit 2: an eased edge; a hairline's
// width instead), and its scissor's pixels (target pixels x0, y0, x1, y1:
// draws aren't scissored, so instances of any scissor draw together).
struct Shape_Instance {
    vec4 m;
    vec4 t;
    vec4 bounds;
    vec4 uv;
    uvec4 data;
    vec4 clip;
};

// An instance's motion (ovg Shape_Motion): at drawing coordinates p its
// velocity is velocity.xy * p.x + velocity.zw * p.y + offset.xy, and
// offset.z its nearness (0: it writes no motion). Row for row with the
// frame's instances; declared and bound for the motion variants only, so a
// still variant reflects (and SDL_GPU binds) three storage buffers.
#ifdef MOTION
struct Shape_Motion {
    vec4 velocity;
    vec4 offset;
};
#endif

// The shapes' words (curves.FORMAT).
layout(std430) readonly buffer Shapes { uint words[]; } shapes;
// The frame's instances (and groups' records), for scissors and groups.
layout(std430) readonly buffer Members { Shape_Instance rows[]; } members;
#ifdef MOTION
layout(std430) readonly buffer Motions { Shape_Motion rows[]; } motions;
#endif

uint curves_word(uint i) { return shapes.words[i]; }

// uv and data are the same at every pixel of an instance: the software
// backend passes them as uniforms (shader_cpu_defines), so oksl's CPU program
// works out what follows from them alone once a call instead of at every
// pixel. There rc and fpos are no stage inputs either: shape_clip sets them
// from gl_FragCoord, rc by the backend's map to shape units (rc_linear,
// rc_offset), as the vertex shader's quad interpolates them.
#ifdef SHAPE_FLAT_UNIFORMS
uniform vec4 uv;
uniform uvec4 data;
// ovg.Transform2D {a, b, c, d, e, f}: rc_linear (a, b, c, d), rc_offset (e, f).
uniform vec4 rc_linear;
uniform vec2 rc_offset;
// Shape units.
vec2 rc;
// Drawing coordinates.
vec2 fpos;
#else
// Shape units.
layout(location = 0) in vec2 rc;
// Drawing coordinates.
layout(location = 1) in vec2 fpos;
layout(location = 2) flat in vec4 uv;
// The instance's data, its w the instance's index, with bit 31 set when its
// quad reaches out of its scissor.
layout(location = 3) flat in uvec4 data;
#endif

layout(location = 0) out vec4 color;
#ifdef MOTION
layout(location = 1) out vec4 motion;
#endif

// Leaves the pixels outside the instance's scissor, as a scissored draw
// would, before any coverage work; only an instance whose quad reaches out
// of it reads it. Every unit's main calls it first; on the CPU it sets rc
// and fpos too.
void shape_clip() {
#ifdef SHAPE_FLAT_UNIFORMS
    fpos = gl_FragCoord.xy;
    rc = fpos.x * rc_linear.xy + fpos.y * rc_linear.zw + rc_offset;
#endif
    if ((data.w & 0x80000000u) != 0u) {
        vec4 clip = members.rows[data.w & 0x7fffffffu].clip;
        if (any(lessThan(gl_FragCoord.xy, clip.xy)) || any(greaterThanEqual(gl_FragCoord.xy, clip.zw))) {
            discard;
        }
    }
}

// The coverage of the paint row's clip at the pixel (ovg clip_path): 1
// without one (P(0).w 0), 0 for one cut away whole (-1); else its image
// (`glyphtex`, its clip's coverage times each parent's) read exactly, by
// texelFetch at the pixel's drawing coordinates (which stay right on a
// layer's window too) less its cell's corner (P(1).w, P(2).w), 0 outside
// the cell (to P(3).w, P(4).w).
float clip_coverage() {
    float state = P(0).w;
    if (state == 0.0) {
        return 1.0;
    }
    vec2 p = floor(fpos);
    if (state < 0.0 || p.x < P(1).w || p.y < P(2).w || p.x >= P(3).w || p.y >= P(4).w) {
        return 0.0;
    }
    return texelFetch(glyphtex, ivec2(p - vec2(P(1).w, P(2).w)), 0).a;
}

// A fill's coverage, eased across its edge (smoothstep) when its flags
// have 4: a feathered fill's (ovg Shape_Edge.Smooth), whose wide edge then
// has no visible shoulder.
float shape_ease(uint flags, float coverage) {
    return (flags & 4u) != 0u ? coverage * coverage * (3.0 - 2.0 * coverage) : coverage;
}

// An instance's fill rule: bit 0 of its flags (CURVES_NON_ZERO or
// CURVES_EVEN_ODD).
int shape_rule(uint flags) {
    return int(flags & 1u);
}

#ifdef MOTION
// Instance `index`'s motion at p over `under` (a twin pixel) by coverage a.
vec4 motion_over(uint index, vec2 p, float a, vec4 under) {
    Shape_Motion m = motions.rows[index];
    if (m.offset.z == 0.0) {
        return under;
    }
    vec2 v = m.velocity.xy * p.x + m.velocity.zw * p.y + m.offset.xy;
    return vec4(v, m.offset.z, 1.0) * a + under * (1.0 - a);
}
#endif

// The cells of a group's grid (Cmd_Draw_Shapes.group) the pixel's cell
// lists: its first word `at` and the lists' start (`lists`), from the
// grid at word `grid` (its columns and rows in its first word).
uvec2 group_cell(uint grid) {
    uint dims = shapes.words[grid];
    uint nx = dims & 0xffffu;
    uvec2 cell = min(uvec2(max(rc, 0.0)), uvec2(nx, dims >> 16) - 1u);
    return uvec2(grid + 1u + cell.y * nx + cell.x, grid + 1u + nx * (dims >> 16) + 1u);
}

// A member's shape units at the pixel (drawing coordinates to the
// instance's), and whether the pixel is within its quad.
bool member_point(Shape_Instance s, out vec2 r) {
    vec2 d = fpos - s.t.xy;
    r = vec2(s.m.w * d.x - s.m.z * d.y, s.m.x * d.y - s.m.y * d.x) / (s.m.x * s.m.w - s.m.z * s.m.y);
    vec2 epp = s.t.zw;
    return !(any(lessThan(r, s.bounds.xy - epp)) || any(greaterThan(r, s.bounds.zw + epp)));
}

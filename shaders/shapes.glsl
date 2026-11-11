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
// frame's instances; read by the motion variants only.
struct Shape_Motion {
    vec4 velocity;
    vec4 offset;
};

// The shapes' words (curves.FORMAT).
layout(std430) readonly buffer Shapes { uint words[]; } shapes;
// The frame's instances (and groups' records), for scissors and groups.
layout(std430) readonly buffer Members { Shape_Instance rows[]; } members;
layout(std430) readonly buffer Motions { Shape_Motion rows[]; } motions;

uint curves_word(uint i) { return shapes.words[i]; }

// Shape units.
layout(location = 0) in vec2 rc;
// Drawing coordinates.
layout(location = 1) in vec2 fpos;
layout(location = 2) flat in vec4 uv;
// The instance's data, its w the instance's index, with bit 31 set when its
// quad reaches out of its scissor.
layout(location = 3) flat in uvec4 data;

layout(location = 0) out vec4 color;
#ifdef MOTION
layout(location = 1) out vec4 motion;
#endif

// Leaves the pixels outside the instance's scissor, as a scissored draw
// would, before any coverage work; only an instance whose quad reaches out
// of it reads it.
void shape_clip() {
    if ((data.w & 0x80000000u) != 0u) {
        vec4 clip = members.rows[data.w & 0x7fffffffu].clip;
        if (any(lessThan(gl_FragCoord.xy, clip.xy)) || any(greaterThanEqual(gl_FragCoord.xy, clip.zw))) {
            discard;
        }
    }
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

// Instance `index`'s motion at p over `under` (a twin pixel) by coverage a.
vec4 motion_over(uint index, vec2 p, float a, vec4 under) {
    Shape_Motion m = motions.rows[index];
    if (m.offset.z == 0.0) {
        return under;
    }
    vec2 v = m.velocity.xy * p.x + m.velocity.zw * p.y + m.offset.xy;
    return vec4(v, m.offset.z, 1.0) * a + under * (1.0 - a);
}

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

// ovg's vertex shader for shape instances and groups, in GLSL ES 3.0 as
// oksl compiles it: a quad over the instance's bounds, grown by a pixel. A
// draw of N instances is 6 N vertices from 6 times its first, so
// gl_VertexID / 6 is the instance's row in `instances` (the frame's
// instances, then its groups' records).

struct Shape_Instance {
    vec4 m;
    vec4 t;
    vec4 bounds;
    vec4 uv;
    uvec4 data;
    vec4 clip;
};

layout(std430) readonly buffer Instances { Shape_Instance rows[]; } instances;

// Target size (xy) and the drawing coordinates of its top-left pixel (zw).
uniform vec4 view;

// Shape units.
layout(location = 0) out vec2 rc;
// Drawing coordinates.
layout(location = 1) out vec2 fpos;
layout(location = 2) flat out vec4 uv;
// The instance's data, its w the instance's index, with bit 31 set when its
// quad reaches out of its scissor.
layout(location = 3) flat out uvec4 data;

void main() {
    uint id = uint(gl_VertexID) / 6u;
    // Two triangles: (0,0) (1,0) (1,1), (0,0) (1,1) (0,1).
    uint k = uint(gl_VertexID) % 6u;
    Shape_Instance s = instances.rows[id];
    float cx = (k == 1u || k == 2u || k == 4u) ? 1.0 : 0.0;
    float cy = (k == 2u || k == 4u || k == 5u) ? 1.0 : 0.0;
    vec2 epp = s.t.zw;
    vec2 r = vec2(mix(s.bounds.x - epp.x, s.bounds.z + epp.x, cx), mix(s.bounds.y - epp.y, s.bounds.w + epp.y, cy));
    vec2 d = vec2(s.m.x * r.x + s.m.z * r.y + s.t.x, s.m.y * r.x + s.m.w * r.y + s.t.y);
    rc = r;
    fpos = d;
    uv = s.uv;
    // Whether any corner of the quad lies outside the scissor.
    vec2 lo = vec2(s.bounds.x - epp.x, s.bounds.y - epp.y);
    vec2 hi = vec2(s.bounds.z + epp.x, s.bounds.w + epp.y);
    vec2 c0 = vec2(s.m.x * lo.x + s.m.z * lo.y, s.m.y * lo.x + s.m.w * lo.y) + s.t.xy - view.zw;
    vec2 ex = vec2(s.m.x * (hi.x - lo.x), s.m.y * (hi.x - lo.x));
    vec2 ey = vec2(s.m.z * (hi.y - lo.y), s.m.w * (hi.y - lo.y));
    vec2 qmin = min(min(c0, c0 + ex), min(c0 + ey, c0 + ex + ey));
    vec2 qmax = max(max(c0, c0 + ex), max(c0 + ey, c0 + ex + ey));
    bool cut = any(lessThan(qmin, s.clip.xy)) || any(greaterThan(qmax, s.clip.zw));
    data = uvec4(s.data.xyz, id | (cut ? 0x80000000u : 0u));
    vec2 p = d - view.zw;
    gl_Position = vec4(2.0 * p.x / view.x - 1.0, 1.0 - 2.0 * p.y / view.y, 0.0, 1.0);
}

// Shared instanced SDF line and shape helpers for Tier L hacks (`lines: Some(...)`).
//
// A Tier L hack defines `fn shape(idx: u32, t: f32) -> Shape` in addition to
// `fn hack(p: vec2<f32>, t: f32) -> vec3<f32>`. Each frame, `lines.count` instances
// are rendered as tight screen-space bounding quads into the offscreen target right
// after `hack(p, t)`, sharing the same orbit offset before the limiter and care pass.
//
// Coordinate conventions:
// - Positions and radii use canvas-height coordinates (`x` in `0..aspect()`, `y` in `0..1`).
// - Constructors take full stroke widths (in canvas heights) and store half-widths internally.
// - `col_a` / `col_b` are straight RGBA in `0..1` (RGB intensity plus opacity in `.a`).

const SHAPE_NONE: u32 = 0u;
const SHAPE_SEGMENT: u32 = 1u;
const SHAPE_DISC: u32 = 2u;
const SHAPE_RING: u32 = 3u;
const SHAPE_BOX: u32 = 4u;
const SHAPE_TRIANGLE: u32 = 5u;

struct Shape {
    kind: u32,
    a: vec2<f32>,
    b: vec2<f32>,
    c: vec2<f32>,
    r0: f32,
    r1: f32,
    glow: f32,
    glow_strength: f32,
    col_a: vec4<f32>,
    col_b: vec4<f32>,
};

fn line_count() -> u32 {
    return u32(g.line_count + 0.5);
}

fn shape_none() -> Shape {
    return Shape(
        SHAPE_NONE,
        vec2<f32>(0.0),
        vec2<f32>(0.0),
        vec2<f32>(0.0),
        0.0,
        0.0,
        0.0,
        0.0,
        vec4<f32>(0.0),
        vec4<f32>(0.0),
    );
}

fn shape_segment_taper(
    a: vec2<f32>,
    b: vec2<f32>,
    width_a: f32,
    width_b: f32,
    col_a: vec4<f32>,
    col_b: vec4<f32>,
    glow: f32,
) -> Shape {
    let gs = select(0.0, 0.38, glow > 0.0);
    return Shape(
        SHAPE_SEGMENT,
        a,
        b,
        vec2<f32>(0.0),
        max(width_a, 0.0) * 0.5,
        max(width_b, 0.0) * 0.5,
        max(glow, 0.0),
        gs,
        col_a,
        col_b,
    );
}

fn shape_segment(a: vec2<f32>, b: vec2<f32>, width: f32, col: vec4<f32>) -> Shape {
    return shape_segment_taper(a, b, width, width, col, col, 0.0);
}

fn shape_disc(center: vec2<f32>, radius: f32, col: vec4<f32>, glow: f32) -> Shape {
    let gs = select(0.0, 0.38, glow > 0.0);
    return Shape(
        SHAPE_DISC,
        center,
        vec2<f32>(0.0),
        vec2<f32>(0.0),
        max(radius, 0.0),
        0.0,
        max(glow, 0.0),
        gs,
        col,
        col,
    );
}

fn shape_ring(center: vec2<f32>, radius: f32, width: f32, col: vec4<f32>, glow: f32) -> Shape {
    let gs = select(0.0, 0.38, glow > 0.0);
    return Shape(
        SHAPE_RING,
        center,
        vec2<f32>(max(radius, 0.0), 0.0),
        vec2<f32>(0.0, 0.0),
        max(width, 0.0) * 0.5,
        0.0,
        max(glow, 0.0),
        gs,
        col,
        col,
    );
}

fn shape_arc(
    center: vec2<f32>,
    radius: f32,
    width: f32,
    center_angle: f32,
    half_angle: f32,
    col_a: vec4<f32>,
    col_b: vec4<f32>,
    glow: f32,
) -> Shape {
    let gs = select(0.0, 0.38, glow > 0.0);
    return Shape(
        SHAPE_RING,
        center,
        vec2<f32>(max(radius, 0.0), clamp(half_angle, 0.0, PI)),
        vec2<f32>(center_angle, 1.0),
        max(width, 0.0) * 0.5,
        0.0,
        max(glow, 0.0),
        gs,
        col_a,
        col_b,
    );
}

fn shape_box(
    center: vec2<f32>,
    half_size: vec2<f32>,
    angle: f32,
    corner: f32,
    stroke: f32,
    col: vec4<f32>,
    glow: f32,
) -> Shape {
    let gs = select(0.0, 0.38, glow > 0.0);
    let hs = max(half_size, vec2<f32>(0.0));
    let c_rad = clamp(corner, 0.0, min(hs.x, hs.y));
    let r1 = select(0.0, stroke * 0.5, stroke > 0.0);
    return Shape(
        SHAPE_BOX,
        center,
        hs,
        vec2<f32>(angle, 0.0),
        c_rad,
        r1,
        max(glow, 0.0),
        gs,
        col,
        col,
    );
}

fn shape_triangle(
    a: vec2<f32>,
    b: vec2<f32>,
    c: vec2<f32>,
    stroke: f32,
    col: vec4<f32>,
    glow: f32,
) -> Shape {
    let gs = select(0.0, 0.38, glow > 0.0);
    let r1 = select(0.0, stroke * 0.5, stroke > 0.0);
    return Shape(
        SHAPE_TRIANGLE,
        a,
        b,
        c,
        0.0,
        r1,
        max(glow, 0.0),
        gs,
        col,
        col,
    );
}

fn shape_glow(s: Shape, radius: f32, strength: f32) -> Shape {
    var out = s;
    out.glow = max(radius, 0.0);
    out.glow_strength = max(strength, 0.0);
    return out;
}

fn shape_grad(s: Shape, col_b: vec4<f32>) -> Shape {
    var out = s;
    out.col_b = col_b;
    return out;
}

fn sd_segment_2d(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
    let pa = p - a;
    let ba = b - a;
    let denom = dot(ba, ba);
    let h = select(0.0, clamp(dot(pa, ba) / max(denom, 1e-10), 0.0, 1.0), denom > 1e-10);
    return length(pa - ba * h);
}

fn sd_triangle_2d(p: vec2<f32>, p0: vec2<f32>, p1: vec2<f32>, p2: vec2<f32>) -> f32 {
    let e0 = p1 - p0;
    let e1 = p2 - p1;
    let e2 = p0 - p2;
    let area2 = e0.x * e2.y - e0.y * e2.x;
    if (abs(area2) < 1e-10) {
        return 1e5;
    }
    let v0 = p - p0;
    let v1 = p - p1;
    let v2 = p - p2;
    let pq0 = v0 - e0 * clamp(dot(v0, e0) / max(dot(e0, e0), 1e-10), 0.0, 1.0);
    let pq1 = v1 - e1 * clamp(dot(v1, e1) / max(dot(e1, e1), 1e-10), 0.0, 1.0);
    let pq2 = v2 - e2 * clamp(dot(v2, e2) / max(dot(e2, e2), 1e-10), 0.0, 1.0);
    let s = select(-1.0, 1.0, area2 > 0.0);
    let d = min(
        min(
            vec2<f32>(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
            vec2<f32>(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x)),
        ),
        vec2<f32>(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)),
    );
    return select(sqrt(d.x), -sqrt(d.x), d.y > 0.0);
}

fn line_world_to_clip(p: vec2<f32>) -> vec4<f32> {
    let sx = p.x * g.canvas.y - g.orbit.x;
    let sy = (1.0 - p.y) * g.canvas.y - g.orbit.y;
    let u = sx / max(g.canvas.x, 1.0);
    let v = sy / max(g.canvas.y, 1.0);
    return vec4<f32>(u * 2.0 - 1.0, 1.0 - v * 2.0, 0.0, 1.0);
}

struct LineVsOut {
    @builtin(position) clip_pos: vec4<f32>,
    @location(0) @interpolate(flat) ab: vec4<f32>,
    @location(1) @interpolate(flat) c_rot: vec2<f32>,
    @location(2) @interpolate(flat) col_a: vec4<f32>,
    @location(3) @interpolate(flat) col_b: vec4<f32>,
    @location(4) @interpolate(flat) params: vec4<f32>,
    @location(5) @interpolate(flat) kind: u32,
};

fn line_is_finite_vec2(v: vec2<f32>) -> bool {
    return all(v == v) && all(abs(v) < vec2<f32>(1e5));
}

fn line_vertex(vi: u32, s: Shape) -> LineVsOut {
    var out: LineVsOut;
    out.ab = vec4<f32>(s.a, s.b);
    out.c_rot = s.c;
    out.col_a = s.col_a;
    out.col_b = s.col_b;
    out.params = vec4<f32>(s.r0, s.r1, s.glow, s.glow_strength);
    out.kind = s.kind;

    let visible = s.kind != SHAPE_NONE
        && max(s.col_a.a, s.col_b.a) > 1e-4
        && line_is_finite_vec2(s.a)
        && line_is_finite_vec2(s.b)
        && line_is_finite_vec2(s.c);
    if (!visible) {
        out.clip_pos = vec4<f32>(2.0, 2.0, 0.0, 1.0);
        return out;
    }

    if (s.kind == SHAPE_TRIANGLE) {
        let e0 = s.b - s.a;
        let e2 = s.a - s.c;
        let area2 = abs(e0.x * e2.y - e0.y * e2.x);
        if (area2 < 1e-10) {
            out.clip_pos = vec4<f32>(2.0, 2.0, 0.0, 1.0);
            return out;
        }
    }

    let px = 1.0 / max(g.target_size.y, 1.0);
    let min_r = 0.5 * px;
    let aa = 0.75 * px;
    let glow = max(s.glow, 0.0);
    let u = select(-1.0, 1.0, (vi & 2u) != 0u);
    let v = select(-1.0, 1.0, (vi & 1u) != 0u);

    var pos_w = s.a;
    if (s.kind == SHAPE_SEGMENT) {
        let d = s.b - s.a;
        let len = length(d);
        let dir = select(vec2<f32>(1.0, 0.0), d / max(len, 1e-6), len > 1e-6);
        let perp = vec2<f32>(-dir.y, dir.x);
        let mid = 0.5 * (s.a + s.b);
        let pad = max(max(s.r0, s.r1), min_r) + glow + aa * 1.5;
        let half_len = 0.5 * len + pad;
        pos_w = mid + dir * (u * half_len) + perp * (v * pad);
    } else if (s.kind == SHAPE_DISC) {
        let pad = max(s.r0, min_r) + glow + aa * 1.5;
        pos_w = s.a + vec2<f32>(u, v) * pad;
    } else if (s.kind == SHAPE_RING) {
        let pad = max(s.b.x, 0.0) + max(s.r0, min_r) + glow + aa * 1.5;
        pos_w = s.a + vec2<f32>(u, v) * pad;
    } else if (s.kind == SHAPE_BOX) {
        let stroke_pad = select(0.0, max(s.r1, min_r), s.r1 > 0.0);
        let ext = max(s.b, vec2<f32>(0.0)) + vec2<f32>(stroke_pad + glow + aa * 1.5);
        let ca = cos(s.c.x);
        let sa = sin(s.c.x);
        let ax = vec2<f32>(ca, sa);
        let ay = vec2<f32>(-sa, ca);
        pos_w = s.a + ax * (u * ext.x) + ay * (v * ext.y);
    } else if (s.kind == SHAPE_TRIANGLE) {
        let stroke_pad = select(0.0, max(s.r1, min_r), s.r1 > 0.0);
        let pad = max(s.r0, 0.0) + stroke_pad + glow + aa * 1.5;
        let bmin = min(s.a, min(s.b, s.c)) - vec2<f32>(pad);
        let bmax = max(s.a, max(s.b, s.c)) + vec2<f32>(pad);
        pos_w = mix(bmin, bmax, vec2<f32>(0.5 + 0.5 * u, 0.5 + 0.5 * v));
    } else {
        out.clip_pos = vec4<f32>(2.0, 2.0, 0.0, 1.0);
        return out;
    }

    out.clip_pos = line_world_to_clip(pos_w);
    return out;
}

fn line_fragment(in: LineVsOut) -> vec4<f32> {
    if (in.kind == SHAPE_NONE) {
        discard;
    }

    let cp = in.clip_pos.xy * (g.canvas / g.target_size) + g.orbit;
    let p = vec2<f32>(cp.x / g.canvas.y, 1.0 - cp.y / g.canvas.y);

    let px = 1.0 / max(g.target_size.y, 1.0);
    let min_r = 0.5 * px;
    let aa = 0.75 * px;
    let r0 = in.params.x;
    let r1 = in.params.y;
    let glow = max(in.params.z, 0.0);
    let glow_strength = max(in.params.w, 0.0);

    var d_core = 1e5;
    var d_glow = 1e5;
    var energy = 1.0;
    var col = in.col_a;

    if (in.kind == SHAPE_SEGMENT) {
        let a = in.ab.xy;
        let b = in.ab.zw;
        let pa = p - a;
        let ba = b - a;
        let denom = dot(ba, ba);
        let h = select(0.0, clamp(dot(pa, ba) / max(denom, 1e-10), 0.0, 1.0), denom > 1e-10);
        let d_center = length(pa - ba * h);
        let r_raw = max(mix(r0, r1, h), 0.0);
        let r_eff = max(r_raw, min_r);
        energy = clamp(r_raw / r_eff, 0.0, 1.0);
        d_core = d_center - r_eff;
        d_glow = max(d_center - r_raw, 0.0);
        col = mix(in.col_a, in.col_b, h);
    } else if (in.kind == SHAPE_DISC) {
        let d_center = length(p - in.ab.xy);
        let r_raw = max(r0, 0.0);
        let r_eff = max(r_raw, min_r);
        let ratio = clamp(r_raw / r_eff, 0.0, 1.0);
        energy = ratio * ratio;
        d_core = d_center - r_eff;
        d_glow = max(d_center - r_raw, 0.0);
        let gt = clamp(d_center / max(r_eff, 1e-6), 0.0, 1.0);
        col = mix(in.col_a, in.col_b, gt);
    } else if (in.kind == SHAPE_RING) {
        let q = p - in.ab.xy;
        let ring_r = max(in.ab.z, 0.0);
        let arc_half = clamp(in.ab.w, 0.0, PI);
        let is_arc = in.c_rot.y > 0.5;
        let r_raw = max(r0, 0.0);
        let r_eff = max(r_raw, min_r);
        energy = clamp(r_raw / r_eff, 0.0, 1.0);
        var d_center = abs(length(q) - ring_r);
        if (is_arc && arc_half < PI - 1e-4) {
            let ca = cos(in.c_rot.x);
            let sa = sin(in.c_rot.x);
            let qr = vec2<f32>(q.x * ca + q.y * sa, -q.x * sa + q.y * ca);
            let cap_dir = vec2<f32>(cos(arc_half), sin(arc_half));
            let qf = vec2<f32>(qr.x, abs(qr.y));
            let in_wedge = (qf.x * cap_dir.y - qf.y * cap_dir.x) > 0.0;
            d_center = select(length(qf - cap_dir * ring_r), abs(length(qf) - ring_r), in_wedge);
            let theta = atan2(qr.y, qr.x);
            let ht = clamp(0.5 + 0.5 * theta / max(arc_half, 1e-4), 0.0, 1.0);
            col = mix(in.col_a, in.col_b, ht);
        } else {
            let ang = atan2(q.y, q.x);
            col = mix(in.col_a, in.col_b, 0.5 - 0.5 * cos(ang));
        }
        d_core = d_center - r_eff;
        d_glow = max(d_center - r_raw, 0.0);
    } else if (in.kind == SHAPE_BOX) {
        let hs = max(in.ab.zw, vec2<f32>(0.0));
        let c_rad = clamp(r0, 0.0, min(hs.x, hs.y));
        let ca = cos(in.c_rot.x);
        let sa = sin(in.c_rot.x);
        let delta = p - in.ab.xy;
        let local = vec2<f32>(delta.x * ca + delta.y * sa, -delta.x * sa + delta.y * ca);
        let qb = abs(local) - (hs - vec2<f32>(c_rad));
        let d_box = length(max(qb, vec2<f32>(0.0))) + min(max(qb.x, qb.y), 0.0) - c_rad;
        if (r1 > 0.0) {
            let r_eff = max(r1, min_r);
            energy = clamp(r1 / r_eff, 0.0, 1.0);
            d_core = abs(d_box) - r_eff;
            d_glow = max(abs(d_box) - r1, 0.0);
        } else {
            d_core = d_box;
            d_glow = max(d_box, 0.0);
        }
        let gt = clamp(0.5 + 0.5 * local.y / max(hs.y, 1e-4), 0.0, 1.0);
        col = mix(in.col_a, in.col_b, gt);
    } else if (in.kind == SHAPE_TRIANGLE) {
        let a = in.ab.xy;
        let b = in.ab.zw;
        let c = in.c_rot;
        let d_tri = sd_triangle_2d(p, a, b, c) - max(r0, 0.0);
        if (r1 > 0.0) {
            let r_eff = max(r1, min_r);
            energy = clamp(r1 / r_eff, 0.0, 1.0);
            d_core = abs(d_tri) - r_eff;
            d_glow = max(abs(d_tri) - r1, 0.0);
        } else {
            d_core = d_tri;
            d_glow = max(d_tri, 0.0);
        }
        let min_y = min(a.y, min(b.y, c.y));
        let max_y = max(a.y, max(b.y, c.y));
        let gt = clamp((p.y - min_y) / max(max_y - min_y, 1e-4), 0.0, 1.0);
        col = mix(in.col_a, in.col_b, gt);
    } else {
        discard;
    }

    let cov = clamp(1.0 - smoothstep(-aa, aa, d_core), 0.0, 1.0) * energy;
    var halo = 0.0;
    if (glow > 1e-5 && glow_strength > 1e-5) {
        let gt = clamp(1.0 - max(d_glow, 0.0) / glow, 0.0, 1.0);
        halo = gt * gt * exp(-2.2 * (1.0 - gt)) * glow_strength * energy;
    }
    let w = clamp(cov + halo * (1.0 - cov), 0.0, 1.0);
    if (w <= 1e-4 || col.a <= 1e-4) {
        discard;
    }
    let rgb_out = clamp(col.rgb * (col.a * w), vec3<f32>(0.0), vec3<f32>(1.0));
    let a_out = clamp(col.a * cov, 0.0, 1.0);
    return vec4<f32>(rgb_out, a_out);
}

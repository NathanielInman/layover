// Hyper Cell: four-dimensional regular polytopes rotating across 6 planes of SO(4)
// and turning inside out through double perspective projection on Tier L instanced
// SDF lines in stationary isotropic full-canvas coordinates.
// After xscreensaver's Hypercube (Joe Keane and Jamie Zawinski, 1992) and
// Polytopes (Carsten Steger, 2003).

const EPOCH_SECS: f32 = 44.0;
const MARGIN_X: f32 = 0.05;
const MARGIN_Y: f32 = 0.045;
const INV_SQRT2: f32 = 0.70710678;
const C5: f32 = 0.55901699;
const PHI: f32 = 1.61803399;
const QA: f32 = 0.80901699;
const QB: f32 = 0.50000000;
const QC: f32 = 0.30901699;

fn reflect_range(x: f32, lo: f32, hi: f32) -> f32 {
    let span = max(hi - lo, 1e-4);
    let u = (x - lo) / span;
    let m = u - 2.0 * floor(u * 0.5);
    let f = select(2.0 - m, m, m <= 1.0);
    return lo + f * span;
}

// Four RGB-balanced 5-stop phosphor palettes.
fn poly_palette(pal: u32, x: f32) -> vec3<f32> {
    let p = pal % 4u;
    var c0 = vec3<f32>(0.14, 0.94, 1.00);
    var c1 = vec3<f32>(1.00, 0.34, 0.30);
    var c2 = vec3<f32>(0.22, 0.96, 0.56);
    var c3 = vec3<f32>(0.74, 0.34, 1.00);
    var c4 = vec3<f32>(0.98, 0.80, 0.22);
    if (p == 1u) {
        c0 = vec3<f32>(1.00, 0.64, 0.18);
        c1 = vec3<f32>(0.20, 0.66, 1.00);
        c2 = vec3<f32>(0.98, 0.26, 0.72);
        c3 = vec3<f32>(0.18, 0.96, 0.68);
        c4 = vec3<f32>(0.52, 0.38, 1.00);
    } else if (p == 2u) {
        c0 = vec3<f32>(0.20, 0.90, 0.96);
        c1 = vec3<f32>(0.98, 0.30, 0.44);
        c2 = vec3<f32>(0.58, 0.96, 0.24);
        c3 = vec3<f32>(0.58, 0.42, 1.00);
        c4 = vec3<f32>(1.00, 0.52, 0.20);
    } else if (p == 3u) {
        c0 = vec3<f32>(1.00, 0.38, 0.24);
        c1 = vec3<f32>(0.18, 0.96, 0.54);
        c2 = vec3<f32>(0.26, 0.58, 1.00);
        c3 = vec3<f32>(0.92, 0.30, 0.92);
        c4 = vec3<f32>(0.96, 0.84, 0.24);
    }
    let s = fract(x) * 5.0;
    let i = u32(floor(s)) % 5u;
    let f = smoothstep(0.0, 1.0, fract(s));
    if (i == 0u) { return mix(c0, c1, f); }
    if (i == 1u) { return mix(c1, c2, f); }
    if (i == 2u) { return mix(c2, c3, f); }
    if (i == 3u) { return mix(c3, c4, f); }
    return mix(c4, c0, f);
}

struct ChapterSpec {
    chapter: u32,
    n_bodies: u32,
    stride: u32,
    pal_id: u32,
    env: f32,
    phase: f32,
    gen: u32,
};

fn chapter_spec(t: f32) -> ChapterSpec {
    let gen = u32(max(floor(t / EPOCH_SECS), 0.0));
    let phase = t - f32(gen) * EPOCH_SECS;
    let env = smoothstep(0.0, 1.8, phase) * smoothstep(EPOCH_SECS, EPOCH_SECS - 1.8, phase);
    let chapter = (gen + u32(floor(g.seed * 13.0))) % 4u;
    let pal_id = (gen * 3u + u32(floor(g.seed * 17.0))) % 4u;
    let wide = aspect() > 2.35;

    var n_bodies = select(2u, 4u, wide);
    var stride = 48u;
    if (chapter == 1u) {
        n_bodies = select(2u, 3u, wide);
        stride = 80u;
    } else if (chapter == 2u) {
        n_bodies = select(2u, 3u, wide);
        stride = 120u;
    } else if (chapter == 3u) {
        n_bodies = select(1u, 2u, wide);
        stride = 720u;
    }

    return ChapterSpec(chapter, n_bodies, stride, pal_id, env, phase, gen);
}

struct BodyPose {
    center: vec2<f32>,
    radius: f32,
    hue_off: f32,
    a_xw: f32,
    a_yw: f32,
    a_zw: f32,
    a_xy: f32,
    a_yz: f32,
    a_zx: f32,
};

fn body_pose(spec: ChapterSpec, b: u32) -> BodyPose {
    let b_seed = f32(b) * 29.3 + f32(spec.gen) * 13.7 + g.seed * 67.0;
    let hb = hash22(vec2<f32>(b_seed, f32(spec.chapter) * 6.1 + 1.9));
    let hb2 = hash22(vec2<f32>(b_seed * 1.43 + 3.7, hb.x * 21.1 + 2.3));
    let hb3 = hash22(vec2<f32>(b_seed * 1.79 + 8.3, hb2.y * 31.7 + 4.9));
    let hb4 = hash22(vec2<f32>(b_seed * 2.17 + 14.1, hb3.x * 41.3 + 7.1));

    var r_min = 0.28;
    var r_max = 0.33;
    if (spec.chapter == 1u || spec.chapter == 2u) {
        r_min = 0.32;
        r_max = 0.37;
    } else if (spec.chapter == 3u) {
        r_min = 0.36;
        r_max = 0.41;
    }
    let radius = min(mix(r_min, r_max, hb.x), 0.42 * aspect());

    let x_lo_all = max(MARGIN_X + radius * 0.92, MARGIN_X + 0.12);
    let x_hi_all = max(aspect() - MARGIN_X - radius * 0.92, x_lo_all + 0.15);
    let span_all = x_hi_all - x_lo_all;

    var x_lo = x_lo_all;
    var x_hi = x_hi_all;
    if (spec.n_bodies == 4u) {
        let lane = (b + spec.gen) % 4u;
        if (lane == 0u) {
            x_hi = x_lo_all + span_all * 0.30;
        } else if (lane == 1u) {
            x_lo = x_lo_all + span_all * 0.22;
            x_hi = x_lo_all + span_all * 0.53;
        } else if (lane == 2u) {
            x_lo = x_lo_all + span_all * 0.47;
            x_hi = x_lo_all + span_all * 0.78;
        } else {
            x_lo = x_hi_all - span_all * 0.30;
        }
    } else if (spec.n_bodies == 3u) {
        let lane = (b + spec.gen) % 3u;
        if (lane == 0u) {
            x_hi = x_lo_all + span_all * 0.44;
        } else if (lane == 1u) {
            x_lo = x_lo_all + span_all * 0.28;
            x_hi = x_hi_all - span_all * 0.28;
        } else {
            x_lo = x_hi_all - span_all * 0.44;
        }
    } else if (spec.n_bodies == 2u) {
        let lane = (b + spec.gen) % 2u;
        let reach = select(0.58, 0.40, spec.chapter == 3u);
        if (lane == 0u) {
            x_hi = x_lo_all + span_all * reach;
        } else {
            x_lo = x_hi_all - span_all * reach;
        }
    }

    let y_lo = clamp(MARGIN_Y + radius * 0.94, 0.32, 0.46);
    let y_hi = clamp(1.0 - MARGIN_Y - radius * 0.94, 0.54, 0.68);

    let start_frac_x = 0.28 + hb2.x * 0.44;
    let x_start = mix(x_lo, x_hi, start_frac_x);
    let x_dir = select(-1.0, 1.0, ((b + spec.gen) % 2u) == 0u);
    let vx_base = select(mix(0.16, 0.23, hb2.y), mix(0.22, 0.28, hb2.y), spec.chapter == 3u);
    let x_travel = x_start + x_dir * (spec.phase * vx_base + 0.04 * sin(spec.phase * 0.31 + hb.y * TAU));
    let cx = reflect_range(x_travel, x_lo, x_hi);

    let start_frac_y = fract(f32(b) * 0.39 + hb3.y * 0.5);
    let y_start = mix(y_lo, y_hi, start_frac_y);
    let y_dir = select(-1.0, 1.0, ((b * 3u + spec.gen) % 2u) == 0u);
    let vy_base = select(mix(0.08, 0.125, hb3.x), mix(0.10, 0.14, hb3.x), spec.chapter == 3u);
    let y_travel = y_start + y_dir * (spec.phase * vy_base + 0.025 * sin(spec.phase * 0.37 + hb2.x * TAU));
    let cy = reflect_range(y_travel, y_lo, y_hi);

    let t_eval = spec.phase + 6.0;
    let sgn0 = select(-1.0, 1.0, (b % 2u) == 0u);
    let sgn1 = select(-1.0, 1.0, ((b + spec.chapter) % 2u) == 0u);
    let sgn2 = select(-1.0, 1.0, ((b * 3u + 1u) % 2u) == 0u);

    let a_xw = hb.x * TAU + sgn0 * t_eval * mix(0.36, 0.52, hb4.x);
    let a_yw = hb.y * TAU + sgn1 * t_eval * mix(0.28, 0.42, hb4.y);
    let a_zw = hb2.x * TAU + sgn2 * t_eval * mix(0.22, 0.34, hb3.y);
    let a_xy = hb2.y * TAU + sgn1 * t_eval * mix(0.30, 0.46, hb.x);
    let a_yz = hb3.x * TAU + sgn0 * t_eval * mix(0.24, 0.38, hb2.y);
    let a_zx = hb3.y * TAU + sgn2 * t_eval * mix(0.19, 0.31, hb4.x);

    let hue_off = hb.y * 0.35 + f32(b) * 0.21;

    return BodyPose(
        vec2<f32>(cx, cy),
        radius,
        hue_off,
        a_xw,
        a_yw,
        a_zw,
        a_xy,
        a_yz,
        a_zx,
    );
}

fn rotate4(v: vec4<f32>, pose: BodyPose) -> vec4<f32> {
    var p = v;
    let xw = rot2(pose.a_xw) * vec2<f32>(p.x, p.w);
    p.x = xw.x;
    p.w = xw.y;
    let yw = rot2(pose.a_yw) * vec2<f32>(p.y, p.w);
    p.y = yw.x;
    p.w = yw.y;
    let zw = rot2(pose.a_zw) * vec2<f32>(p.z, p.w);
    p.z = zw.x;
    p.w = zw.y;
    let xy = rot2(pose.a_xy) * vec2<f32>(p.x, p.y);
    p.x = xy.x;
    p.y = xy.y;
    let yz = rot2(pose.a_yz) * vec2<f32>(p.y, p.z);
    p.y = yz.x;
    p.z = yz.y;
    let zx = rot2(pose.a_zx) * vec2<f32>(p.z, p.x);
    p.z = zx.x;
    p.x = zx.y;
    return p;
}

struct Proj4 {
    p2: vec2<f32>,
    p3: vec3<f32>,
    w: f32,
    depth: f32,
};

fn project4(r4: vec4<f32>, pose: BodyPose, d4: f32) -> Proj4 {
    let norm4 = sqrt(max(d4 * d4 - 1.0, 0.25));
    let denom4 = max(d4 - r4.w, 0.35);
    let p3 = r4.xyz * (norm4 / denom4);
    let s3 = 2.85 / max(3.25 - p3.z, 0.5);
    let p2 = pose.center + p3.xy * s3 * pose.radius;
    let depth = clamp(0.5 + 0.36 * r4.w + 0.22 * p3.z, 0.0, 1.0);
    return Proj4(p2, p3, r4.w, depth);
}

fn axis_vec4(a: u32, val: f32) -> vec4<f32> {
    if (a == 0u) { return vec4<f32>(val, 0.0, 0.0, 0.0); }
    if (a == 1u) { return vec4<f32>(0.0, val, 0.0, 0.0); }
    if (a == 2u) { return vec4<f32>(0.0, 0.0, val, 0.0); }
    return vec4<f32>(0.0, 0.0, 0.0, val);
}

fn pair4(idx: u32) -> vec2<u32> {
    let k = idx % 6u;
    if (k == 0u) { return vec2<u32>(0u, 1u); }
    if (k == 1u) { return vec2<u32>(0u, 2u); }
    if (k == 2u) { return vec2<u32>(0u, 3u); }
    if (k == 3u) { return vec2<u32>(1u, 2u); }
    if (k == 4u) { return vec2<u32>(1u, 3u); }
    return vec2<u32>(2u, 3u);
}

fn pair3(idx: u32) -> vec2<u32> {
    let k = idx % 3u;
    if (k == 0u) { return vec2<u32>(0u, 1u); }
    if (k == 1u) { return vec2<u32>(0u, 2u); }
    return vec2<u32>(1u, 2u);
}

fn pair5(idx: u32) -> vec2<u32> {
    let k = idx % 10u;
    if (k == 0u) { return vec2<u32>(0u, 1u); }
    if (k == 1u) { return vec2<u32>(0u, 2u); }
    if (k == 2u) { return vec2<u32>(0u, 3u); }
    if (k == 3u) { return vec2<u32>(0u, 4u); }
    if (k == 4u) { return vec2<u32>(1u, 2u); }
    if (k == 5u) { return vec2<u32>(1u, 3u); }
    if (k == 6u) { return vec2<u32>(1u, 4u); }
    if (k == 7u) { return vec2<u32>(2u, 3u); }
    if (k == 8u) { return vec2<u32>(2u, 4u); }
    return vec2<u32>(3u, 4u);
}

fn other_idx(skip: u32, k: u32) -> u32 {
    return select(k, k + 1u, k >= skip);
}

fn cell8_vertex(v: u32) -> vec4<f32> {
    let s0 = select(-0.5, 0.5, (v & 1u) != 0u);
    let s1 = select(-0.5, 0.5, ((v >> 1u) & 1u) != 0u);
    let s2 = select(-0.5, 0.5, ((v >> 2u) & 1u) != 0u);
    let s3 = select(-0.5, 0.5, ((v >> 3u) & 1u) != 0u);
    return vec4<f32>(s0, s1, s2, s3);
}

fn cell16_vertex(v: u32) -> vec4<f32> {
    let a = v / 2u;
    let s = select(-1.0, 1.0, (v & 1u) != 0u);
    return axis_vec4(a, s);
}

fn cell5_vertex(v: u32) -> vec4<f32> {
    let i = v % 5u;
    if (i == 0u) { return vec4<f32>(0.0, 0.0, 0.0, 1.0); }
    if (i == 1u) { return vec4<f32>(C5, C5, C5, -0.25); }
    if (i == 2u) { return vec4<f32>(C5, -C5, -C5, -0.25); }
    if (i == 3u) { return vec4<f32>(-C5, C5, -C5, -0.25); }
    return vec4<f32>(-C5, -C5, C5, -0.25);
}

fn cell24_vertex(v: u32) -> vec4<f32> {
    let pr = pair4(v / 4u);
    let s0 = select(-INV_SQRT2, INV_SQRT2, (v & 1u) != 0u);
    let s1 = select(-INV_SQRT2, INV_SQRT2, ((v >> 1u) & 1u) != 0u);
    return axis_vec4(pr.x, s0) + axis_vec4(pr.y, s1);
}

fn qmul(a: vec4<f32>, b: vec4<f32>) -> vec4<f32> {
    return vec4<f32>(
        a.w * b.xyz + b.w * a.xyz + cross(a.xyz, b.xyz),
        a.w * b.w - dot(a.xyz, b.xyz),
    );
}

fn cell600_vertex(v: u32) -> vec4<f32> {
    if (v < 8u) {
        return cell16_vertex(v);
    }
    if (v < 24u) {
        return cell8_vertex(v - 8u);
    }
    let k = v - 24u;
    let perm = k / 8u;
    let signs = k % 8u;
    let v0 = select(-QB, QB, (signs & 1u) != 0u);
    let v1 = select(-QC, QC, ((signs >> 1u) & 1u) != 0u);
    let v2 = 0.0;
    let v3 = select(-QA, QA, ((signs >> 2u) & 1u) != 0u);
    if (perm == 0u) { return vec4<f32>(v0, v1, v2, v3); }
    if (perm == 1u) { return vec4<f32>(v0, v2, v3, v1); }
    if (perm == 2u) { return vec4<f32>(v0, v3, v1, v2); }
    if (perm == 3u) { return vec4<f32>(v1, v0, v3, v2); }
    if (perm == 4u) { return vec4<f32>(v1, v3, v2, v0); }
    if (perm == 5u) { return vec4<f32>(v1, v2, v0, v3); }
    if (perm == 6u) { return vec4<f32>(v2, v3, v0, v1); }
    if (perm == 7u) { return vec4<f32>(v2, v0, v1, v3); }
    if (perm == 8u) { return vec4<f32>(v2, v1, v3, v0); }
    if (perm == 9u) { return vec4<f32>(v3, v2, v1, v0); }
    if (perm == 10u) { return vec4<f32>(v3, v1, v0, v2); }
    return vec4<f32>(v3, v0, v2, v1);
}

fn cell600_gen(gen_idx: u32) -> vec4<f32> {
    if (gen_idx == 0u) { return vec4<f32>(QB, QC, 0.0, QA); }
    if (gen_idx == 1u) { return vec4<f32>(QB, -QC, 0.0, QA); }
    if (gen_idx == 2u) { return vec4<f32>(0.0, QB, QC, QA); }
    if (gen_idx == 3u) { return vec4<f32>(0.0, QB, -QC, QA); }
    if (gen_idx == 4u) { return vec4<f32>(QC, 0.0, QB, QA); }
    return vec4<f32>(-QC, 0.0, QB, QA);
}

fn edge_shape(
    spec: ChapterSpec,
    pa: Proj4,
    pb: Proj4,
    hue_a: f32,
    hue_b: f32,
    w_min: f32,
    w_max: f32,
    alpha_scale: f32,
    glow_max: f32,
) -> Shape {
    var col_a = poly_palette(spec.pal_id, hue_a);
    var col_b = poly_palette(spec.pal_id, hue_b);
    col_a = mix(col_a, vec3<f32>(1.0), 0.08 + 0.24 * pow(pa.depth, 1.6));
    col_b = mix(col_b, vec3<f32>(1.0), 0.08 + 0.24 * pow(pb.depth, 1.6));

    let wa = mix(w_min, w_max, pa.depth);
    let wb = mix(w_min, w_max, pb.depth);
    let aa = (0.30 + 0.68 * pow(pa.depth, 1.05)) * alpha_scale * spec.env;
    let ab = (0.30 + 0.68 * pow(pb.depth, 1.05)) * alpha_scale * spec.env;
    let dm = 0.5 * (pa.depth + pb.depth);
    let glow_r = mix(glow_max * 0.28, glow_max, dm);
    let glow_s = mix(0.20, 0.48, dm);

    return shape_glow(
        shape_segment_taper(
            pa.p2,
            pb.p2,
            wa,
            wb,
            vec4<f32>(col_a, aa),
            vec4<f32>(col_b, ab),
            glow_r,
        ),
        glow_r,
        glow_s,
    );
}

fn vertex_jewel(spec: ChapterSpec, pv: Proj4, hue: f32, r_scale: f32, alpha_scale: f32) -> Shape {
    var col = poly_palette(spec.pal_id, hue);
    col = mix(col, vec3<f32>(1.0), 0.22 + 0.32 * pv.depth);
    let rad = mix(0.0030, 0.0066, pv.depth) * r_scale;
    let glow_r = mix(0.009, 0.024, pv.depth) * r_scale;
    let alpha = (0.40 + 0.58 * pv.depth) * alpha_scale * spec.env;
    return shape_glow(
        shape_disc(pv.p2, rad, vec4<f32>(col, alpha), glow_r),
        glow_r,
        0.38 + 0.26 * pv.depth,
    );
}

fn draw_cell8_edge(spec: ChapterSpec, pose: BodyPose, e: u32, d4: f32, scale: f32, hue_base: f32) -> Shape {
    let axis = e / 8u;
    let m = e % 8u;
    let lo_mask = (1u << axis) - 1u;
    let va_idx = ((m & ~lo_mask) << 1u) | (m & lo_mask);
    let vb_idx = va_idx | (1u << axis);

    let ra = rotate4(cell8_vertex(va_idx) * scale, pose);
    let rb = rotate4(cell8_vertex(vb_idx) * scale, pose);
    let pa = project4(ra, pose, d4);
    let pb = project4(rb, pose, d4);
    let h_fam = hue_base + f32(axis) * 0.16;
    return edge_shape(spec, pa, pb, h_fam + 0.12 * pa.w, h_fam + 0.12 * pb.w, 0.0024, 0.0060, 1.0, 0.019);
}

fn draw_cell16_edge(
    spec: ChapterSpec,
    pose: BodyPose,
    e: u32,
    d4: f32,
    scale: f32,
    hue_base: f32,
    coaxial_twist: bool,
) -> Shape {
    let pr = pair4(e / 4u);
    let s0 = select(-scale, scale, (e & 1u) != 0u);
    let s1 = select(-scale, scale, ((e >> 1u) & 1u) != 0u);
    var va = axis_vec4(pr.x, s0);
    var vb = axis_vec4(pr.y, s1);
    if (coaxial_twist) {
        let ang = 0.25 * PI;
        let va_xw = rot2(ang) * vec2<f32>(va.x, va.w);
        let va_yz = rot2(ang) * vec2<f32>(va.y, va.z);
        va = vec4<f32>(va_xw.x, va_yz.x, va_yz.y, va_xw.y);
        let vb_xw = rot2(ang) * vec2<f32>(vb.x, vb.w);
        let vb_yz = rot2(ang) * vec2<f32>(vb.y, vb.z);
        vb = vec4<f32>(vb_xw.x, vb_yz.x, vb_yz.y, vb_xw.y);
    }
    let ra = rotate4(va, pose);
    let rb = rotate4(vb, pose);
    let pa = project4(ra, pose, d4);
    let pb = project4(rb, pose, d4);
    let h_fam = hue_base + f32(pr.x + pr.y) * 0.07;
    return edge_shape(spec, pa, pb, h_fam + 0.14 * pa.w, h_fam + 0.14 * pb.w, 0.0024, 0.0058, 0.96, 0.018);
}

fn shape_chapter0(spec: ChapterSpec, b: u32, slot: u32) -> Shape {
    let pose = body_pose(spec, b);
    let hue_base = spec.phase * 0.075 + pose.hue_off;
    let d4 = 2.25;
    if (slot < 32u) {
        return draw_cell8_edge(spec, pose, slot, d4, 1.0, hue_base);
    }
    let v = slot - 32u;
    if (v < 16u) {
        let pv = project4(rotate4(cell8_vertex(v), pose), pose, d4);
        return vertex_jewel(spec, pv, hue_base + 0.45 + 0.16 * pv.w, 1.0, 0.95);
    }
    return shape_none();
}

fn shape_chapter1(spec: ChapterSpec, b: u32, slot: u32) -> Shape {
    let pose = body_pose(spec, b);
    let hue_base = spec.phase * 0.075 + pose.hue_off;
    let d4 = 2.25;
    let kind = (b + spec.gen) % 3u;

    if (kind == 0u) {
        // Dual 8-cell + 16-cell compound.
        if (slot < 32u) {
            return draw_cell8_edge(spec, pose, slot, d4, 1.0, hue_base);
        }
        if (slot < 56u) {
            return draw_cell16_edge(spec, pose, slot - 32u, d4, 1.06, hue_base + 0.44, false);
        }
        if (slot < 72u) {
            let pv = project4(rotate4(cell8_vertex(slot - 56u), pose), pose, d4);
            return vertex_jewel(spec, pv, hue_base + 0.12 * pv.w, 0.9, 0.88);
        }
        if (slot < 80u) {
            let pv = project4(rotate4(cell16_vertex(slot - 72u) * 1.06, pose), pose, d4);
            return vertex_jewel(spec, pv, hue_base + 0.46 + 0.12 * pv.w, 1.15, 0.95);
        }
        return shape_none();
    }

    if (kind == 1u) {
        // Dual 5-cell star inside a rectified 5-cell hull.
        if (slot < 20u) {
            let dual = slot >= 10u;
            let pr = pair5(select(slot, slot - 10u, dual));
            let sgn = select(1.0, -1.0, dual);
            let ra = rotate4(cell5_vertex(pr.x) * sgn, pose);
            let rb = rotate4(cell5_vertex(pr.y) * sgn, pose);
            let pa = project4(ra, pose, d4);
            let pb = project4(rb, pose, d4);
            let h_off = select(0.0, 0.46, dual);
            return edge_shape(
                spec,
                pa,
                pb,
                hue_base + h_off + 0.14 * pa.w,
                hue_base + h_off + 0.14 * pb.w,
                0.0028,
                0.0066,
                1.0,
                0.020,
            );
        }
        if (slot < 50u) {
            let e = slot - 20u;
            let a = e / 6u;
            let pr = pair4(e % 6u);
            let p = other_idx(a, pr.x);
            let q = other_idx(a, pr.y);
            let va = normalize(cell5_vertex(a) + cell5_vertex(p)) * 1.02;
            let vb = normalize(cell5_vertex(a) + cell5_vertex(q)) * 1.02;
            let pa = project4(rotate4(va, pose), pose, d4);
            let pb = project4(rotate4(vb, pose), pose, d4);
            return edge_shape(
                spec,
                pa,
                pb,
                hue_base + 0.24 + 0.10 * pa.w,
                hue_base + 0.24 + 0.10 * pb.w,
                0.0017,
                0.0036,
                0.56,
                0.009,
            );
        }
        if (slot < 60u) {
            let v = slot - 50u;
            let dual = v >= 5u;
            let sgn = select(1.0, -1.0, dual);
            let pv = project4(rotate4(cell5_vertex(v % 5u) * sgn, pose), pose, d4);
            let h_off = select(0.06, 0.50, dual);
            return vertex_jewel(spec, pv, hue_base + h_off + 0.14 * pv.w, 1.15, 0.96);
        }
        return shape_none();
    }

    // Twin nested 16-cell orthoplex.
    if (slot < 24u) {
        return draw_cell16_edge(spec, pose, slot, d4, 1.02, hue_base + 0.06, false);
    }
    if (slot < 48u) {
        return draw_cell16_edge(spec, pose, slot - 24u, d4, 0.80, hue_base + 0.48, true);
    }
    if (slot < 56u) {
        let pv = project4(rotate4(cell16_vertex(slot - 48u) * 1.02, pose), pose, d4);
        return vertex_jewel(spec, pv, hue_base + 0.10 + 0.12 * pv.w, 1.15, 0.95);
    }
    if (slot < 64u) {
        var v = cell16_vertex(slot - 56u) * 0.80;
        let ang = 0.25 * PI;
        let v_xw = rot2(ang) * vec2<f32>(v.x, v.w);
        let v_yz = rot2(ang) * vec2<f32>(v.y, v.z);
        v = vec4<f32>(v_xw.x, v_yz.x, v_yz.y, v_xw.y);
        let pv = project4(rotate4(v, pose), pose, d4);
        return vertex_jewel(spec, pv, hue_base + 0.52 + 0.12 * pv.w, 1.0, 0.90);
    }
    return shape_none();
}

fn shape_chapter2(spec: ChapterSpec, b: u32, slot: u32) -> Shape {
    let pose = body_pose(spec, b);
    let hue_base = spec.phase * 0.075 + pose.hue_off;
    let d4 = 2.65;

    if (slot < 96u) {
        let a = slot / 24u;
        let rem = slot % 24u;
        let sa = select(-INV_SQRT2, INV_SQRT2, (rem / 12u) != 0u);
        let rem2 = rem % 12u;
        let pr = pair3(rem2 / 4u);
        let p = other_idx(a, pr.x);
        let q = other_idx(a, pr.y);
        let sp = select(-INV_SQRT2, INV_SQRT2, (rem2 & 1u) != 0u);
        let sq = select(-INV_SQRT2, INV_SQRT2, ((rem2 >> 1u) & 1u) != 0u);

        let va = axis_vec4(a, sa) + axis_vec4(p, sp);
        let vb = axis_vec4(a, sa) + axis_vec4(q, sq);
        let ra = rotate4(va, pose);
        let rb = rotate4(vb, pose);
        let pa = project4(ra, pose, d4);
        let pb = project4(rb, pose, d4);

        let w_mid = 0.5 * (ra.w + rb.w);
        let front = smoothstep(-0.62, 0.35, w_mid);
        if (front <= 1e-4) {
            return shape_none();
        }
        let h_fam = hue_base + f32(a) * 0.17;
        return edge_shape(
            spec,
            pa,
            pb,
            h_fam + 0.16 * pa.w,
            h_fam + 0.16 * pb.w,
            0.0020,
            0.0048,
            0.90 * front,
            0.015,
        );
    }

    let v = slot - 96u;
    if (v < 24u) {
        let pv = project4(rotate4(cell24_vertex(v), pose), pose, d4);
        let front = smoothstep(-0.55, 0.35, pv.w);
        if (front <= 1e-4) {
            return shape_none();
        }
        return vertex_jewel(spec, pv, hue_base + 0.42 + 0.18 * pv.w, 0.92, 0.92 * front);
    }
    return shape_none();
}

fn shape_chapter3(spec: ChapterSpec, b: u32, slot: u32) -> Shape {
    if (slot >= 720u) {
        return shape_none();
    }
    let pose = body_pose(spec, b);
    let hue_base = spec.phase * 0.08 + pose.hue_off;
    let d4 = 2.75;

    let v_idx = slot / 6u;
    let g_idx = slot % 6u;
    let va = cell600_vertex(v_idx);
    let vb = qmul(va, cell600_gen(g_idx));

    let ra = rotate4(va, pose);
    let rb = rotate4(vb, pose);
    let w_mid = 0.5 * (ra.w + rb.w);
    if (w_mid <= -0.18) {
        return shape_none();
    }
    let front_fade = smoothstep(-0.18, 0.42, w_mid);

    let pa = project4(ra, pose, d4);
    let pb = project4(rb, pose, d4);
    let h_a = hue_base + 0.28 * pa.w + 0.12 * pa.p3.z + f32(g_idx) * 0.04;
    let h_b = hue_base + 0.28 * pb.w + 0.12 * pb.p3.z + f32(g_idx) * 0.04;

    return edge_shape(
        spec,
        pa,
        pb,
        h_a,
        h_b,
        0.0020,
        0.0044,
        0.95 * front_fade,
        0.014,
    );
}

fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> {
    return vec3<f32>(0.0);
}

fn shape(idx: u32, t: f32) -> Shape {
    let spec = chapter_spec(t);
    if (spec.env <= 1e-4) {
        return shape_none();
    }
    let total = spec.n_bodies * spec.stride;
    if (idx >= total) {
        return shape_none();
    }
    let b = idx / spec.stride;
    let slot = idx % spec.stride;

    if (spec.chapter == 0u) {
        return shape_chapter0(spec, b, slot);
    }
    if (spec.chapter == 1u) {
        return shape_chapter1(spec, b, slot);
    }
    if (spec.chapter == 2u) {
        return shape_chapter2(spec, b, slot);
    }
    return shape_chapter3(spec, b, slot);
}

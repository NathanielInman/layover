// Phase Knot: phase-drifting Lissajous loops, beaded harmonic worms, 3D knots
// and twisted phase ribbons across a stationary isotropic full-canvas dark field
// on Tier L instanced SDF lines.
// After xscreensaver's Lissie (Alexander Jolk, 1996) and Lisa (Caleb Cullen, 1997).

const EPOCH_SECS: f32 = 44.0;
const MARGIN_X: f32 = 0.05;
const MARGIN_Y: f32 = 0.045;

fn reflect_range(x: f32, lo: f32, hi: f32) -> f32 {
    let span = max(hi - lo, 1e-4);
    let u = (x - lo) / span;
    let m = u - 2.0 * floor(u * 0.5);
    let f = select(2.0 - m, m, m <= 1.0);
    return lo + f * span;
}

// Four RGB-balanced 5-stop phosphor palettes.
fn knot_palette(pal: u32, x: f32) -> vec3<f32> {
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

    var n_bodies = select(2u, 3u, wide);
    var stride = 204u;
    if (chapter == 1u) {
        n_bodies = select(2u, 4u, wide);
        stride = 92u;
    } else if (chapter == 2u) {
        n_bodies = select(2u, 3u, wide);
        stride = 230u;
    } else if (chapter == 3u) {
        n_bodies = select(2u, 3u, wide);
        stride = 320u;
    }

    return ChapterSpec(chapter, n_bodies, stride, pal_id, env, phase, gen);
}

struct BodyPose {
    center: vec2<f32>,
    radius: f32,
    preset: u32,
    hue_off: f32,
    hr: vec2<f32>,
    hr2: vec2<f32>,
    hr3: vec2<f32>,
    hr4: vec2<f32>,
    rx: f32,
    ry: f32,
    rz: f32,
};

fn body_pose(spec: ChapterSpec, b: u32) -> BodyPose {
    let b_seed = f32(b) * 27.9 + f32(spec.gen) * 14.3 + g.seed * 59.0;
    let hr = hash22(vec2<f32>(b_seed, f32(spec.chapter) * 5.9 + 1.7));
    let hr2 = hash22(vec2<f32>(b_seed * 1.47 + 3.3, hr.x * 19.7 + 2.1));
    let hr3 = hash22(vec2<f32>(b_seed * 1.83 + 7.9, hr2.y * 29.3 + 4.7));
    let hr4 = hash22(vec2<f32>(b_seed * 2.23 + 13.1, hr3.x * 37.9 + 6.3));

    let r_min = select(0.32, 0.30, spec.n_bodies == 4u);
    let r_max = select(0.38, 0.36, spec.n_bodies == 4u);
    let radius = min(mix(r_min, r_max, hr.x), 0.42 * aspect());

    let x_lo_all = max(MARGIN_X + radius * 0.92, MARGIN_X + 0.12);
    let x_hi_all = max(aspect() - MARGIN_X - radius * 0.92, x_lo_all + 0.15);
    let span_all = x_hi_all - x_lo_all;

    var x_lo = x_lo_all;
    var x_hi = x_hi_all;
    if (spec.n_bodies == 4u) {
        let lane = (b + spec.gen) % 4u;
        if (lane == 0u) {
            x_hi = x_lo_all + span_all * 0.26;
        } else if (lane == 1u) {
            x_lo = x_lo_all + span_all * 0.23;
            x_hi = x_lo_all + span_all * 0.51;
        } else if (lane == 2u) {
            x_lo = x_lo_all + span_all * 0.49;
            x_hi = x_lo_all + span_all * 0.77;
        } else {
            x_lo = x_hi_all - span_all * 0.26;
        }
    } else if (spec.n_bodies == 3u) {
        let lane = (b + spec.gen) % 3u;
        if (lane == 0u) {
            x_hi = x_lo_all + span_all * 0.30;
        } else if (lane == 1u) {
            x_lo = x_lo_all + span_all * 0.35;
            x_hi = x_hi_all - span_all * 0.35;
        } else {
            x_lo = x_hi_all - span_all * 0.30;
        }
    } else if (spec.n_bodies == 2u) {
        let lane = (b + spec.gen) % 2u;
        if (lane == 0u) {
            x_hi = x_lo_all + span_all * 0.55;
        } else {
            x_lo = x_hi_all - span_all * 0.55;
        }
    }

    let y_lo = clamp(MARGIN_Y + radius * 0.92, 0.32, 0.46);
    let y_hi = clamp(1.0 - MARGIN_Y - radius * 0.92, 0.54, 0.68);

    let start_frac_x = 0.28 + hr2.x * 0.44;
    let x_start = mix(x_lo, x_hi, start_frac_x);
    let x_dir = select(-1.0, 1.0, ((b + spec.gen) % 2u) == 0u);
    let vx = mix(0.16, 0.23, hr2.y);
    let x_travel = x_start + x_dir * (spec.phase * vx + 0.045 * sin(spec.phase * 0.31 + hr.y * TAU));
    let cx = reflect_range(x_travel, x_lo, x_hi);

    let start_frac_y = fract(f32(b) * 0.37 + hr3.y * 0.5);
    let y_start = mix(y_lo, y_hi, start_frac_y);
    let y_dir = select(-1.0, 1.0, ((b * 3u + spec.gen) % 2u) == 0u);
    let vy = mix(0.08, 0.125, hr3.x);
    let y_travel = y_start + y_dir * (spec.phase * vy + 0.025 * sin(spec.phase * 0.37 + hr2.x * TAU));
    let cy = reflect_range(y_travel, y_lo, y_hi);

    let t_eval = spec.phase + 6.0;
    let s0 = select(-1.0, 1.0, (b % 2u) == 0u);
    let s1 = select(-1.0, 1.0, ((b + spec.chapter) % 2u) == 0u);
    let s2 = select(-1.0, 1.0, ((b * 3u + 1u) % 2u) == 0u);

    let rx = hr.x * TAU + s0 * t_eval * mix(0.22, 0.36, hr4.x);
    let ry = hr.y * TAU + s1 * t_eval * mix(0.28, 0.44, hr4.y);
    let rz = hr2.x * TAU + s2 * t_eval * mix(0.16, 0.28, hr3.y);

    let preset = (b + spec.gen * 2u + u32(floor(g.seed * 7.0))) % 6u;
    let hue_off = hr.y * 0.36 + f32(b) * 0.24;

    return BodyPose(
        vec2<f32>(cx, cy),
        radius,
        preset,
        hue_off,
        hr,
        hr2,
        hr3,
        hr4,
        rx,
        ry,
        rz,
    );
}

struct Proj3 {
    p2: vec2<f32>,
    depth: f32,
};

fn project3(p_in: vec3<f32>, pose: BodyPose) -> Proj3 {
    var p = p_in;
    let yz = rot2(pose.rx) * vec2<f32>(p.y, p.z);
    p.y = yz.x;
    p.z = yz.y;
    let xz = rot2(pose.ry) * vec2<f32>(p.x, p.z);
    p.x = xz.x;
    p.z = xz.y;
    let xy = rot2(pose.rz) * vec2<f32>(p.x, p.y);
    p.x = xy.x;
    p.y = xy.y;

    let s3 = 2.85 / max(3.25 - p.z, 0.5);
    let p2 = pose.center + p.xy * s3 * pose.radius;
    let depth = clamp(0.5 + 0.48 * p.z, 0.0, 1.0);
    return Proj3(p2, depth);
}

fn loop_freq_pair(preset: u32) -> vec4<f32> {
    let idx = preset % 6u;
    if (idx == 0u) { return vec4<f32>(3.0, 2.0, 5.0, 4.0); }
    if (idx == 1u) { return vec4<f32>(4.0, 3.0, 5.0, 2.0); }
    if (idx == 2u) { return vec4<f32>(5.0, 3.0, 3.0, 4.0); }
    if (idx == 3u) { return vec4<f32>(5.0, 4.0, 7.0, 4.0); }
    if (idx == 4u) { return vec4<f32>(3.0, 5.0, 4.0, 5.0); }
    return vec4<f32>(7.0, 5.0, 3.0, 2.0);
}

fn worm_freq_pair(preset: u32) -> vec2<f32> {
    let idx = preset % 6u;
    if (idx == 0u) { return vec2<f32>(3.0, 2.0); }
    if (idx == 1u) { return vec2<f32>(4.0, 3.0); }
    if (idx == 2u) { return vec2<f32>(5.0, 3.0); }
    if (idx == 3u) { return vec2<f32>(5.0, 4.0); }
    if (idx == 4u) { return vec2<f32>(3.0, 5.0); }
    return vec2<f32>(7.0, 4.0);
}

fn knot_freq_triple(preset: u32) -> vec3<f32> {
    let idx = preset % 6u;
    if (idx == 0u) { return vec3<f32>(2.0, 3.0, 5.0); }
    if (idx == 1u) { return vec3<f32>(3.0, 4.0, 5.0); }
    if (idx == 2u) { return vec3<f32>(2.0, 5.0, 7.0); }
    if (idx == 3u) { return vec3<f32>(3.0, 5.0, 7.0); }
    if (idx == 4u) { return vec3<f32>(3.0, 4.0, 7.0); }
    return vec3<f32>(4.0, 5.0, 7.0);
}

fn ribbon_freq_pair(preset: u32) -> vec2<f32> {
    let idx = preset % 6u;
    if (idx == 0u) { return vec2<f32>(3.0, 2.0); }
    if (idx == 1u) { return vec2<f32>(4.0, 3.0); }
    if (idx == 2u) { return vec2<f32>(5.0, 3.0); }
    if (idx == 3u) { return vec2<f32>(5.0, 4.0); }
    if (idx == 4u) { return vec2<f32>(2.0, 3.0); }
    return vec2<f32>(3.0, 4.0);
}

fn eval_ch0_loop(spec: ChapterSpec, pose: BodyPose, h: f32) -> Proj3 {
    let u = h * TAU;
    let fp = loop_freq_pair(pose.preset);
    let morph = smoothstep(14.0, 30.0, spec.phase);
    let delta = spec.phase * mix(0.45, 0.65, pose.hr4.x) + pose.hr.y * TAU;
    let p_a = vec3<f32>(sin(fp.x * u + delta), sin(fp.y * u), 0.72 * cos(fp.x * u + delta));
    let p_b = vec3<f32>(sin(fp.z * u + delta), sin(fp.w * u), 0.72 * cos(fp.z * u + delta));
    let p3 = mix(p_a, p_b, morph) * 0.78;
    return project3(p3, pose);
}

fn eval_ch1_worm(pose: BodyPose, u: f32, tau: f32) -> Proj3 {
    let fq = worm_freq_pair(pose.preset);
    let delta = tau * mix(0.24, 0.34, pose.hr4.x) + pose.hr.y * TAU;
    let p3 = vec3<f32>(
        sin(fq.x * u + delta),
        sin(fq.y * u),
        0.65 * cos(fq.x * u + delta),
    ) * 0.78;
    return project3(p3, pose);
}

fn eval_ch2_knot(spec: ChapterSpec, pose: BodyPose, h: f32) -> Proj3 {
    let u = h * TAU;
    let fk = knot_freq_triple(pose.preset);
    let px = 0.71 + pose.hr2.x * 1.4 + spec.phase * 0.16;
    let py = 1.93 + pose.hr2.y * 1.4 - spec.phase * 0.12;
    let pz = 3.17 + pose.hr3.x * 1.4 + spec.phase * 0.20;
    let p3 = vec3<f32>(
        cos(fk.x * u + px),
        cos(fk.y * u + py),
        cos(fk.z * u + pz),
    ) * 0.58;
    return project3(p3, pose);
}

fn eval_ch3_rail(spec: ChapterSpec, pose: BodyPose, h: f32, rail_b: bool) -> Proj3 {
    let u = h * TAU;
    let fq = ribbon_freq_pair(pose.preset);
    let delta_a = spec.phase * mix(0.32, 0.46, pose.hr4.x) + pose.hr.y * TAU;
    let dphi = 0.42 + 0.16 * sin(spec.phase * 0.41 + pose.hr3.y * TAU);
    let dz = 0.32 * cos(spec.phase * 0.29 + pose.hr2.x * TAU);
    let delta = select(delta_a, delta_a + dphi, rail_b);
    let z_shift = select(0.0, dz, rail_b);
    let sc = select(0.78, 0.64, rail_b);
    let p3 = vec3<f32>(
        sin(fq.x * u + delta),
        sin(fq.y * u + select(0.0, dphi * 0.65, rail_b)),
        0.72 * cos(fq.x * u + delta) + z_shift,
    ) * sc;
    return project3(p3, pose);
}

fn strand_segment(
    spec: ChapterSpec,
    pa: Proj3,
    pb: Proj3,
    hue_a: f32,
    hue_b: f32,
    boost_a: f32,
    boost_b: f32,
    w_min: f32,
    w_max: f32,
    alpha_scale: f32,
    glow_max: f32,
) -> Shape {
    var col_a = knot_palette(spec.pal_id, hue_a);
    var col_b = knot_palette(spec.pal_id, hue_b);
    col_a = mix(col_a, vec3<f32>(1.0), 0.10 + 0.28 * pow(pa.depth, 1.5) + 0.34 * boost_a);
    col_b = mix(col_b, vec3<f32>(1.0), 0.10 + 0.28 * pow(pb.depth, 1.5) + 0.34 * boost_b);

    let wa = mix(w_min, w_max, pa.depth) * (1.0 + 0.28 * boost_a);
    let wb = mix(w_min, w_max, pb.depth) * (1.0 + 0.28 * boost_b);
    let aa = clamp((0.34 + 0.64 * pow(pa.depth, 1.0) + 0.18 * boost_a) * alpha_scale, 0.0, 0.98) * spec.env;
    let ab = clamp((0.34 + 0.64 * pow(pb.depth, 1.0) + 0.18 * boost_b) * alpha_scale, 0.0, 0.98) * spec.env;

    let dm = clamp(0.5 * (pa.depth + pb.depth) + 0.35 * max(boost_a, boost_b), 0.0, 1.0);
    let glow_r = mix(glow_max * 0.30, glow_max, dm);
    let glow_s = mix(0.22, 0.52, dm);

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

fn spark_disc(spec: ChapterSpec, pv: Proj3, hue: f32, rad: f32, glow_r: f32, alpha: f32) -> Shape {
    let col = mix(knot_palette(spec.pal_id, hue), vec3<f32>(1.0), 0.38 + 0.26 * pv.depth);
    return shape_glow(
        shape_disc(pv.p2, rad, vec4<f32>(col, alpha * spec.env), glow_r),
        glow_r,
        0.52,
    );
}

fn beam_pulse(h: f32, beam_h: f32) -> f32 {
    let d0 = abs(fract(h - beam_h + 0.5) - 0.5);
    let d1 = abs(fract(h - (beam_h + 0.5) + 0.5) - 0.5);
    return max(exp(-d0 * d0 * 44.0), exp(-d1 * d1 * 44.0));
}

fn shape_chapter0(spec: ChapterSpec, b: u32, slot: u32) -> Shape {
    let pose = body_pose(spec, b);
    let hue_base = spec.phase * 0.08 + pose.hue_off;
    let beam_h = fract(spec.phase * 0.18 + pose.hr3.x);

    if (slot < 200u) {
        let h0 = f32(slot) / 200.0;
        let h1 = f32(slot + 1u) / 200.0;
        let pa = eval_ch0_loop(spec, pose, h0);
        let pb = eval_ch0_loop(spec, pose, h1);
        let p0 = beam_pulse(h0, beam_h);
        let p1 = beam_pulse(h1, beam_h);
        return strand_segment(
            spec,
            pa,
            pb,
            hue_base + h0 * 2.0,
            hue_base + h1 * 2.0,
            p0,
            p1,
            0.0022,
            0.0058,
            0.94,
            0.020,
        );
    }

    let k = slot - 200u;
    if (k < 4u) {
        let hs = fract(beam_h + f32(k) * 0.25);
        let ps = eval_ch0_loop(spec, pose, hs);
        let rad = mix(0.0036, 0.0064, ps.depth);
        return spark_disc(spec, ps, hue_base + hs * 2.0 + 0.12, rad, 0.022, 0.94);
    }
    return shape_none();
}

fn shape_chapter1(spec: ChapterSpec, b: u32, slot: u32) -> Shape {
    let pose = body_pose(spec, b);
    let hue_base = spec.phase * 0.09 + pose.hue_off;
    let u_speed = mix(1.15, 1.55, pose.hr4.y);
    let u_head = (spec.phase + 6.0) * u_speed + pose.hr.y * TAU;
    let span_u = 1.45;

    if (slot < 44u) {
        let h = f32(slot) / 43.0;
        let du = (1.0 - h) * span_u;
        let u = u_head - du;
        let tau = spec.phase - du / max(u_speed, 0.1);
        let pv = eval_ch1_worm(pose, u, tau);

        let wave = 1.0 + 0.16 * sin(h * 14.0 - spec.phase * 5.0);
        let rad = mix(0.0065, 0.022, pow(h, 0.72)) * wave * (0.88 + 0.26 * pv.depth);
        let stroke = mix(0.0020, 0.0044, pow(h, 0.72));
        var col = knot_palette(spec.pal_id, hue_base + h * 0.62);
        col = mix(col, vec3<f32>(1.0), 0.12 + 0.26 * pv.depth + 0.24 * smoothstep(0.84, 1.0, h));
        let alpha = (0.28 + 0.68 * pow(h, 0.78)) * smoothstep(0.0, 0.08, h) * (0.68 + 0.32 * pv.depth) * spec.env;
        let glow_r = mix(0.006, 0.017, h);
        return shape_glow(
            shape_ring(pv.p2, rad, stroke, vec4<f32>(col, alpha), glow_r),
            glow_r,
            mix(0.22, 0.48, h),
        );
    }

    if (slot < 87u) {
        let k = slot - 44u;
        let h0 = f32(k) / 43.0;
        let h1 = f32(k + 1u) / 43.0;
        let du0 = (1.0 - h0) * span_u;
        let du1 = (1.0 - h1) * span_u;
        let pa = eval_ch1_worm(pose, u_head - du0, spec.phase - du0 / max(u_speed, 0.1));
        let pb = eval_ch1_worm(pose, u_head - du1, spec.phase - du1 / max(u_speed, 0.1));
        return strand_segment(
            spec,
            pa,
            pb,
            hue_base + h0 * 0.62,
            hue_base + h1 * 0.62,
            smoothstep(0.85, 1.0, h0) * 0.4,
            smoothstep(0.85, 1.0, h1) * 0.4,
            0.0018,
            0.0042,
            0.65 * smoothstep(0.0, 0.10, h0),
            0.012,
        );
    }

    if (slot >= 88u && slot < 92u) {
        let k = 40u + (slot - 88u);
        let h = f32(k) / 43.0;
        let du = (1.0 - h) * span_u;
        let pv = eval_ch1_worm(pose, u_head - du, spec.phase - du / max(u_speed, 0.1));
        return spark_disc(spec, pv, hue_base + 0.66, 0.0046, 0.018, 0.90);
    }
    return shape_none();
}

fn shape_chapter2(spec: ChapterSpec, b: u32, slot: u32) -> Shape {
    let pose = body_pose(spec, b);
    let hue_base = spec.phase * 0.08 + pose.hue_off;

    if (slot < 224u) {
        let h0 = f32(slot) / 224.0;
        let h1 = f32(slot + 1u) / 224.0;
        let pa = eval_ch2_knot(spec, pose, h0);
        let pb = eval_ch2_knot(spec, pose, h1);
        return strand_segment(
            spec,
            pa,
            pb,
            hue_base + h0 * 3.0,
            hue_base + h1 * 3.0,
            0.0,
            0.0,
            0.0022,
            0.0070,
            0.96,
            0.021,
        );
    }

    let k = slot - 224u;
    if (k < 6u) {
        let hs = fract(spec.phase * 0.14 + f32(k) / 6.0 + pose.hr3.x);
        let ps = eval_ch2_knot(spec, pose, hs);
        let rad = mix(0.0036, 0.0066, ps.depth);
        return spark_disc(spec, ps, hue_base + hs * 3.0 + 0.10, rad, 0.022, 0.95);
    }
    return shape_none();
}

fn shape_chapter3(spec: ChapterSpec, b: u32, slot: u32) -> Shape {
    let pose = body_pose(spec, b);
    let hue_base = spec.phase * 0.08 + pose.hue_off;

    if (slot < 296u) {
        let rail_b = slot >= 148u;
        let seg = select(slot, slot - 148u, rail_b);
        let h0 = f32(seg) / 148.0;
        let h1 = f32(seg + 1u) / 148.0;
        let pa = eval_ch3_rail(spec, pose, h0, rail_b);
        let pb = eval_ch3_rail(spec, pose, h1, rail_b);
        let h_off = select(0.0, 0.38, rail_b);
        return strand_segment(
            spec,
            pa,
            pb,
            hue_base + h_off + h0 * 2.0,
            hue_base + h_off + h1 * 2.0,
            0.0,
            0.0,
            0.0024,
            0.0062,
            0.94,
            0.019,
        );
    }

    if (slot < 320u) {
        let k = slot - 296u;
        let h = fract(f32(k) / 24.0 + spec.phase * 0.09 + pose.hr3.x);
        let pa = eval_ch3_rail(spec, pose, h, false);
        let pb = eval_ch3_rail(spec, pose, h, true);
        return strand_segment(
            spec,
            pa,
            pb,
            hue_base + h * 2.0,
            hue_base + 0.38 + h * 2.0,
            0.0,
            0.0,
            0.0018,
            0.0038,
            0.66,
            0.012,
        );
    }
    return shape_none();
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

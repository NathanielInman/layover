// Cycloid Rose: nested spirograph gears, Ptolemaic epicycle linkages and
// twin-pen guilloche rosettes drifting across a full-canvas dark field on
// Tier L instanced SDF lines.
// After xscreensaver's XSpirograph (Rohit Singh, 2000) and Epicycle
// (James Youngman, 1998).

const EPOCH_SECS: f32 = 44.0;
const CURVE_SLOTS: u32 = 496u;
const MECH_SLOTS_PER_ROSE: u32 = 16u;
const MARGIN_X: f32 = 0.05;
const MARGIN_Y: f32 = 0.05;

fn reflect_range(x: f32, lo: f32, hi: f32) -> f32 {
    let span = max(hi - lo, 1e-4);
    let u = (x - lo) / span;
    let m = u - 2.0 * floor(u * 0.5);
    let f = select(2.0 - m, m, m <= 1.0);
    return lo + f * span;
}

fn dir2(a: f32) -> vec2<f32> {
    return vec2<f32>(cos(a), sin(a));
}

// Four RGB-balanced 5-stop phosphor palettes.
fn rose_palette(pal: u32, x: f32) -> vec3<f32> {
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
    n_roses: u32,
    segs_per_rose: u32,
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
    let n_roses = select(2u, 3u, aspect() > 2.35);
    let segs_per_rose = select(248u, 164u, n_roses == 3u);
    return ChapterSpec(chapter, n_roses, segs_per_rose, pal_id, env, phase, gen);
}

struct RosePose {
    center: vec2<f32>,
    radius: f32,
    rot: f32,
    hr: vec2<f32>,
    hr2: vec2<f32>,
    hr3: vec2<f32>,
    hr4: vec2<f32>,
    preset: u32,
    u_speed: f32,
    hue_off: f32,
};

fn rose_pose(spec: ChapterSpec, r: u32) -> RosePose {
    let r_seed = f32(r) * 23.7 + f32(spec.gen) * 11.3 + g.seed * 61.0;
    let hr = hash22(vec2<f32>(r_seed, f32(spec.chapter) * 5.3 + 1.7));
    let hr2 = hash22(vec2<f32>(r_seed * 1.41 + 3.1, hr.x * 19.3 + 2.9));
    let hr3 = hash22(vec2<f32>(r_seed * 1.73 + 7.9, hr2.y * 29.1 + 4.3));
    let hr4 = hash22(vec2<f32>(r_seed * 2.11 + 13.7, hr3.x * 37.3 + 6.1));

    let radius = min(mix(0.32, 0.40, hr.x), 0.42 * aspect());
    let x_lo_all = max(MARGIN_X + radius * 0.85, MARGIN_X + 0.12);
    let x_hi_all = max(aspect() - MARGIN_X - radius * 0.85, x_lo_all + 0.15);
    let span_all = x_hi_all - x_lo_all;
    // Overlapping horizontal roaming lanes keep all rosettes distributed across 32:9
    // while still wandering broadly across the full canvas over time.
    var x_lo = x_lo_all;
    var x_hi = x_hi_all;
    if (spec.n_roses == 3u) {
        let lane = (r + spec.gen) % 3u;
        if (lane == 0u) {
            x_hi = x_lo_all + span_all * 0.46;
        } else if (lane == 1u) {
            x_lo = x_lo_all + span_all * 0.27;
            x_hi = x_hi_all - span_all * 0.27;
        } else {
            x_lo = x_hi_all - span_all * 0.46;
        }
    } else if (spec.n_roses == 2u) {
        let lane = (r + spec.gen) % 2u;
        if (lane == 0u) {
            x_hi = x_lo_all + span_all * 0.64;
        } else {
            x_lo = x_hi_all - span_all * 0.64;
        }
    }

    let y_lo = clamp(MARGIN_Y + radius * 0.95, 0.30, 0.46);
    let y_hi = clamp(1.0 - MARGIN_Y - radius * 0.95, 0.54, 0.70);

    let start_frac_x = fract(0.25 + hr2.x * 0.5);
    let x_start = mix(x_lo, x_hi, start_frac_x);
    let x_dir = select(-1.0, 1.0, ((r + spec.gen) % 2u) == 0u);
    let vx = mix(0.14, 0.21, hr2.y);
    let x_travel = x_start + x_dir * (spec.phase * vx + 0.06 * sin(spec.phase * 0.31 + hr.y * TAU));
    let cx = reflect_range(x_travel, x_lo, x_hi);

    let start_frac_y = fract(f32(r) * 0.37 + hr3.y * 0.5);
    let y_start = mix(y_lo, y_hi, start_frac_y);
    let y_dir = select(-1.0, 1.0, ((r * 3u + spec.gen) % 2u) == 0u);
    let vy = mix(0.075, 0.115, hr3.x);
    let y_travel = y_start + y_dir * (spec.phase * vy + 0.03 * sin(spec.phase * 0.37 + hr2.x * TAU));
    let cy = reflect_range(y_travel, y_lo, y_hi);

    let rot_dir = select(-1.0, 1.0, ((r + spec.chapter) % 2u) == 0u);
    let rot = hr.x * TAU + rot_dir * spec.phase * mix(0.26, 0.42, hr3.y);

    let preset = (r + spec.gen * 2u + u32(floor(g.seed * 7.0))) % 6u;
    var u_speed = mix(1.45, 2.05, hr4.y);
    if (spec.chapter == 1u) {
        u_speed = mix(0.72, 1.00, hr4.y);
    } else if (spec.chapter == 2u) {
        u_speed = mix(1.30, 1.85, hr4.y);
    } else if (spec.chapter == 3u) {
        u_speed = mix(1.35, 1.95, hr4.y);
    }
    let hue_off = hr.y * 0.42 + f32(r) * 0.23;

    return RosePose(
        vec2<f32>(cx, cy),
        radius,
        rot,
        hr,
        hr2,
        hr3,
        hr4,
        preset,
        u_speed,
        hue_off,
    );
}

fn to_world(pose: RosePose, local: vec2<f32>) -> vec2<f32> {
    return pose.center + rot2(pose.rot) * local;
}

fn hypo_gear_pq(preset: u32) -> vec2<u32> {
    let idx = preset % 6u;
    if (idx == 0u) { return vec2<u32>(7u, 3u); }
    if (idx == 1u) { return vec2<u32>(8u, 3u); }
    if (idx == 2u) { return vec2<u32>(7u, 2u); }
    if (idx == 3u) { return vec2<u32>(9u, 4u); }
    if (idx == 4u) { return vec2<u32>(5u, 2u); }
    return vec2<u32>(10u, 3u);
}

fn epi_gear_pq(preset: u32) -> vec2<u32> {
    let idx = preset % 6u;
    if (idx == 0u) { return vec2<u32>(5u, 2u); }
    if (idx == 1u) { return vec2<u32>(7u, 2u); }
    if (idx == 2u) { return vec2<u32>(5u, 3u); }
    if (idx == 3u) { return vec2<u32>(8u, 3u); }
    if (idx == 4u) { return vec2<u32>(7u, 3u); }
    return vec2<u32>(9u, 2u);
}

fn twin_gear_pq(preset: u32) -> vec2<u32> {
    let idx = preset % 6u;
    if (idx == 0u) { return vec2<u32>(5u, 2u); }
    if (idx == 1u) { return vec2<u32>(7u, 3u); }
    if (idx == 2u) { return vec2<u32>(7u, 2u); }
    if (idx == 3u) { return vec2<u32>(8u, 3u); }
    if (idx == 4u) { return vec2<u32>(5u, 1u); }
    return vec2<u32>(6u, 1u);
}

struct EpicycleSample {
    j0: vec2<f32>,
    j1: vec2<f32>,
    j2: vec2<f32>,
    j3: vec2<f32>,
    j4: vec2<f32>,
    r0: f32,
    r1: f32,
    r2: f32,
    r3: f32,
};

fn epicycle_sample(pose: RosePose, u: f32, tau: f32) -> EpicycleSample {
    let idx = pose.preset % 6u;
    var k = vec4<f32>(1.0, -3.0, 5.0, -9.0);
    var w = vec4<f32>(0.43, 0.27, 0.18, 0.12);
    if (idx == 1u) {
        k = vec4<f32>(1.0, 4.0, -7.0, 11.0);
        w = vec4<f32>(0.45, 0.26, 0.17, 0.12);
    } else if (idx == 2u) {
        k = vec4<f32>(1.0, -2.0, 5.0, -8.0);
        w = vec4<f32>(0.42, 0.27, 0.19, 0.12);
    } else if (idx == 3u) {
        k = vec4<f32>(1.0, 3.0, -6.0, 10.0);
        w = vec4<f32>(0.44, 0.26, 0.18, 0.12);
    } else if (idx == 4u) {
        k = vec4<f32>(1.0, -4.0, 7.0, -11.0);
        w = vec4<f32>(0.43, 0.27, 0.18, 0.12);
    } else if (idx == 5u) {
        k = vec4<f32>(1.0, 2.0, -5.0, 9.0);
        w = vec4<f32>(0.44, 0.26, 0.18, 0.12);
    }

    let r0 = w.x * pose.radius;
    let r1 = w.y * pose.radius;
    let r2 = w.z * pose.radius;
    let r3 = w.w * pose.radius;

    let a0 = k.x * u;
    let a1 = k.y * u + 0.16 * tau + pose.hr2.x * TAU;
    let a2 = k.z * u - 0.24 * tau + pose.hr2.y * TAU;
    let a3 = k.w * u + 0.31 * tau + pose.hr3.x * TAU;

    let j0 = vec2<f32>(0.0, 0.0);
    let j1 = j0 + r0 * dir2(a0);
    let j2 = j1 + r1 * dir2(a1);
    let j3 = j2 + r2 * dir2(a2);
    let j4 = j3 + r3 * dir2(a3);

    return EpicycleSample(j0, j1, j2, j3, j4, r0, r1, r2, r3);
}

struct GearSample {
    wheel_center: vec2<f32>,
    pen_a: vec2<f32>,
    pen_b: vec2<f32>,
    stator_r: f32,
    wheel_r: f32,
    theta_spin: f32,
};

fn hypotrochoid_sample(pose: RosePose, u: f32, tau: f32) -> GearSample {
    let pq = hypo_gear_pq(pose.preset);
    let r_outer = f32(pq.x);
    let r_gear = f32(pq.y);
    let scale = pose.radius / r_outer;
    let d_raw = r_gear * mix(0.68, 0.94, pose.hr4.x) * (1.0 + 0.14 * sin(tau * 0.34 + pose.hr4.y * TAU));
    let d_pen = min(d_raw, 0.96 * r_gear);

    let c_wheel = (r_outer - r_gear) * dir2(u);
    let theta_spin = -((r_outer - r_gear) / r_gear) * u;
    let p_a = (c_wheel + d_pen * dir2(theta_spin)) * scale;

    return GearSample(
        c_wheel * scale,
        p_a,
        p_a,
        r_outer * scale,
        r_gear * scale,
        theta_spin,
    );
}

fn epitrochoid_sample(pose: RosePose, u: f32, tau: f32) -> GearSample {
    let pq = epi_gear_pq(pose.preset);
    let r_stator = f32(pq.x);
    let r_gear = f32(pq.y);
    let scale = pose.radius / (r_stator + r_gear + r_gear * 1.95);
    let d_pen = r_gear * mix(1.30, 1.75, pose.hr4.x) * (1.0 + 0.10 * sin(tau * 0.34 + pose.hr4.y * TAU));

    let c_wheel = (r_stator + r_gear) * dir2(u);
    let theta_spin = ((r_stator + r_gear) / r_gear) * u;
    let p_a = (c_wheel - d_pen * dir2(theta_spin)) * scale;

    return GearSample(
        c_wheel * scale,
        p_a,
        p_a,
        r_stator * scale,
        r_gear * scale,
        theta_spin,
    );
}

fn twin_pen_sample(pose: RosePose, u: f32, tau: f32) -> GearSample {
    let pq = twin_gear_pq(pose.preset);
    let r_outer = f32(pq.x);
    let r_gear = f32(pq.y);
    let scale = pose.radius / r_outer;

    let d0_raw = r_gear * mix(0.82, 0.96, pose.hr4.x) * (1.0 + 0.08 * sin(tau * 0.29 + pose.hr4.y * TAU));
    let d0 = min(d0_raw, 0.98 * r_gear);
    let d1_raw = r_gear * mix(0.40, 0.58, pose.hr4.y) * (1.0 + 0.12 * cos(tau * 0.35 + pose.hr4.x * TAU));
    let d1 = min(d1_raw, 0.68 * r_gear);

    let c_wheel = (r_outer - r_gear) * dir2(u);
    let theta_spin = -((r_outer - r_gear) / r_gear) * u;
    let p0 = (c_wheel + d0 * dir2(theta_spin)) * scale;
    let p1 = (c_wheel + d1 * dir2(theta_spin + PI)) * scale;

    return GearSample(
        c_wheel * scale,
        p0,
        p1,
        r_outer * scale,
        r_gear * scale,
        theta_spin,
    );
}

fn trail_span_u(spec: ChapterSpec, pose: RosePose) -> f32 {
    if (spec.chapter == 0u) {
        let pq = hypo_gear_pq(pose.preset);
        return TAU * f32(pq.y) * 1.15;
    }
    if (spec.chapter == 1u) {
        return TAU * 1.18;
    }
    if (spec.chapter == 2u) {
        let pq = epi_gear_pq(pose.preset);
        return TAU * f32(pq.y) * 1.12;
    }
    let pq = twin_gear_pq(pose.preset);
    return TAU * f32(pq.y) * 0.94;
}

fn eval_curve_world(spec: ChapterSpec, pose: RosePose, pen: u32, h: f32) -> vec2<f32> {
    let span_u = trail_span_u(spec, pose);
    let u_head = (spec.phase + 8.0) * pose.u_speed + pose.hr.y * TAU;
    let du_back = (1.0 - h) * span_u;
    let u = u_head - du_back;
    let tau = spec.phase - du_back / max(pose.u_speed, 0.1);

    var local = vec2<f32>(0.0);
    if (spec.chapter == 0u) {
        local = hypotrochoid_sample(pose, u, tau).pen_a;
    } else if (spec.chapter == 1u) {
        local = epicycle_sample(pose, u, tau).j4;
    } else if (spec.chapter == 2u) {
        local = epitrochoid_sample(pose, u, tau).pen_a;
    } else {
        let gs = twin_pen_sample(pose, u, tau);
        local = select(gs.pen_a, gs.pen_b, pen != 0u);
    }
    return to_world(pose, local);
}

fn pen_spark(pos: vec2<f32>, col: vec3<f32>, env: f32) -> Shape {
    let spark_col = mix(col, vec3<f32>(1.0), 0.45);
    return shape_glow(
        shape_disc(pos, 0.0046, vec4<f32>(spark_col, 0.96 * env), 0.020),
        0.020,
        0.52,
    );
}

fn mech_shape(spec: ChapterSpec, r: u32, slot: u32) -> Shape {
    let pose = rose_pose(spec, r);
    let u_head = (spec.phase + 8.0) * pose.u_speed + pose.hr.y * TAU;
    let tau = spec.phase;
    let hue_base = spec.phase * 0.09 + pose.hue_off;
    let base_rgb = rose_palette(spec.pal_id, hue_base + 0.18);
    let ring_rgb = mix(base_rgb, vec3<f32>(0.82, 0.90, 0.98), 0.35);
    let arm_rgb = mix(rose_palette(spec.pal_id, hue_base + 0.48), vec3<f32>(0.88, 0.94, 1.0), 0.30);

    let ring_col = vec4<f32>(ring_rgb, 0.34 * spec.env);
    let gear_col = vec4<f32>(arm_rgb, 0.40 * spec.env);
    let arm_col = vec4<f32>(arm_rgb, 0.44 * spec.env);
    let w_ring = 0.0024;
    let w_arm = 0.0028;
    let glow_r = 0.008;
    let glow_s = 0.22;

    if (spec.chapter == 1u) {
        let es = epicycle_sample(pose, u_head, tau);
        let j0 = to_world(pose, es.j0);
        let j1 = to_world(pose, es.j1);
        let j2 = to_world(pose, es.j2);
        let j3 = to_world(pose, es.j3);
        let j4 = to_world(pose, es.j4);

        if (slot == 0u) { return shape_glow(shape_ring(j0, es.r0, w_ring, ring_col, glow_r), glow_r, glow_s); }
        if (slot == 1u) { return shape_glow(shape_ring(j1, es.r1, w_ring, ring_col, glow_r), glow_r, glow_s); }
        if (slot == 2u) { return shape_glow(shape_ring(j2, es.r2, w_ring, gear_col, glow_r), glow_r, glow_s); }
        if (slot == 3u) { return shape_glow(shape_ring(j3, es.r3, w_ring, gear_col, glow_r), glow_r, glow_s); }
        if (slot == 4u) { return shape_glow(shape_segment(j0, j1, w_arm, arm_col), glow_r, glow_s); }
        if (slot == 5u) { return shape_glow(shape_segment(j1, j2, w_arm, arm_col), glow_r, glow_s); }
        if (slot == 6u) { return shape_glow(shape_segment(j2, j3, w_arm, arm_col), glow_r, glow_s); }
        if (slot == 7u) { return shape_glow(shape_segment(j3, j4, w_arm, arm_col), glow_r, glow_s); }
        if (slot == 8u) { return shape_disc(j0, 0.0032, arm_col, 0.004); }
        if (slot == 9u) { return shape_disc(j1, 0.0032, arm_col, 0.004); }
        if (slot == 10u) { return shape_disc(j2, 0.0032, arm_col, 0.004); }
        if (slot == 11u) { return shape_disc(j3, 0.0032, arm_col, 0.004); }
        if (slot == 12u) {
            let nib_rgb = rose_palette(spec.pal_id, hue_base + 0.56);
            return pen_spark(j4, nib_rgb, spec.env);
        }
        return shape_none();
    }

    var gs = hypotrochoid_sample(pose, u_head, tau);
    if (spec.chapter == 2u) {
        gs = epitrochoid_sample(pose, u_head, tau);
    } else if (spec.chapter == 3u) {
        gs = twin_pen_sample(pose, u_head, tau);
    }

    let cw = to_world(pose, gs.wheel_center);
    let p_a = to_world(pose, gs.pen_a);
    let p_b = to_world(pose, gs.pen_b);

    if (slot == 0u) {
        return shape_glow(shape_ring(pose.center, gs.stator_r, w_ring, ring_col, glow_r), glow_r, glow_s);
    }
    if (slot == 1u) {
        return shape_glow(shape_ring(cw, gs.wheel_r, w_ring, gear_col, glow_r), glow_r, glow_s);
    }
    if (slot == 2u) {
        return shape_disc(cw, 0.0036, gear_col, 0.005);
    }
    if (slot == 3u) {
        return shape_glow(shape_segment(cw, p_a, w_arm, arm_col), glow_r, glow_s);
    }
    if (spec.chapter == 3u) {
        if (slot == 4u) {
            return shape_glow(shape_segment(cw, p_b, w_arm, arm_col), glow_r, glow_s);
        }
        if (slot == 5u) {
            let nib0 = rose_palette(spec.pal_id, hue_base + 0.52);
            return pen_spark(p_a, nib0, spec.env);
        }
        if (slot == 6u) {
            let nib1 = rose_palette(spec.pal_id, hue_base + 0.94);
            return pen_spark(p_b, nib1, spec.env);
        }
        return shape_none();
    }

    if (slot == 4u) {
        let spoke_dir = dir2(gs.theta_spin + 0.5 * PI) * (gs.wheel_r * 0.92);
        let sa = to_world(pose, gs.wheel_center - spoke_dir);
        let sb = to_world(pose, gs.wheel_center + spoke_dir);
        return shape_glow(shape_segment(sa, sb, w_ring * 0.9, ring_col), glow_r, glow_s);
    }
    if (slot == 5u) {
        let nib_rgb = rose_palette(spec.pal_id, hue_base + 0.56);
        return pen_spark(p_a, nib_rgb, spec.env);
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

    if (idx >= CURVE_SLOTS) {
        let m_idx = idx - CURVE_SLOTS;
        let r = m_idx / MECH_SLOTS_PER_ROSE;
        let slot = m_idx % MECH_SLOTS_PER_ROSE;
        if (r >= spec.n_roses) {
            return shape_none();
        }
        return mech_shape(spec, r, slot);
    }

    let total_curve = spec.n_roses * spec.segs_per_rose;
    if (idx >= total_curve) {
        return shape_none();
    }

    let r = idx / spec.segs_per_rose;
    let seg_idx = idx % spec.segs_per_rose;
    let pose = rose_pose(spec, r);

    var pen = 0u;
    var local_seg = seg_idx;
    var pen_segs = spec.segs_per_rose;
    if (spec.chapter == 3u) {
        let half = spec.segs_per_rose / 2u;
        if (seg_idx >= 2u * half) {
            return shape_none();
        }
        pen = select(0u, 1u, seg_idx >= half);
        local_seg = select(seg_idx, seg_idx - half, seg_idx >= half);
        pen_segs = half;
    }

    let h0 = f32(local_seg) / f32(pen_segs);
    let h1 = f32(local_seg + 1u) / f32(pen_segs);
    let h_mid = 0.5 * (h0 + h1);

    let p0 = eval_curve_world(spec, pose, pen, h0);
    let p1 = eval_curve_world(spec, pose, pen, h1);

    let pen_hue = select(0.0, 0.42, pen != 0u);
    let hue_base = spec.phase * 0.09 + pose.hue_off + pen_hue;
    var col0 = rose_palette(spec.pal_id, hue_base + h0 * 0.56);
    var col1 = rose_palette(spec.pal_id, hue_base + h1 * 0.56);
    col0 = mix(col0, vec3<f32>(1.0), 0.12 + 0.34 * smoothstep(0.88, 1.0, h0));
    col1 = mix(col1, vec3<f32>(1.0), 0.12 + 0.34 * smoothstep(0.88, 1.0, h1));

    let w_tail = 0.0028;
    let w_head = 0.0066;
    let w0 = mix(w_tail, w_head, pow(h0, 0.75));
    let w1 = mix(w_tail, w_head, pow(h1, 0.75));

    let a0 = (0.28 + 0.70 * pow(h0, 0.85)) * smoothstep(0.0, 0.08, h0) * spec.env;
    let a1 = (0.28 + 0.70 * pow(h1, 0.85)) * smoothstep(0.0, 0.08, h1) * spec.env;

    let glow_r = mix(0.008, 0.022, h_mid);
    let glow_s = mix(0.22, 0.46, h_mid);

    return shape_glow(
        shape_segment_taper(
            p0,
            p1,
            w0,
            w1,
            vec4<f32>(col0, a0),
            vec4<f32>(col1, a1),
            glow_r,
        ),
        glow_r,
        glow_s,
    );
}

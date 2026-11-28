// Silver Shoal: bioluminescent boid schools and darting swarms weaving, banking
// and scattering across a stationary full-canvas 3D ocean and sky on Tier P compute
// particles and advected Tier S feedback textures.
// After xscreensaver's GLSchool (David C. Lambert) and Swarm (Jeff Butterworth).
//
// Race-free Jacobi ping-pong particle buffer (`Particles { count: 640 }`):
//   Half 0 (`0..319`) and Half 1 (`320..639`) alternate as read/write halves
//   according to `u32(round(max(g.frame, 0.0))) & 1u`.
//
// Particle layout (`particles[idx]`):
//   p.xyz = 3D world position (canvas heights: x in 0..aspect(), y in 0..1, z depth)
//   p.w   = banking / predator-evasion iridescence flash energy (0..1)
//   v.xyz = 3D world velocity (canvas heights/sec)
//   v.w   = swim undulation phase (radians, wrapped modulo TAU)
//   c.rgb = base iridescent RGB color
//   c.w   = packed epoch `(gen % 16777215u) + 1u` stored exact in f32 (0 = uninitialized)

const MAX_AGENTS: u32 = 320u;
const EPOCH_SECS: f32 = 34.0;

struct RegimeSpec {
    sep_r: f32,
    align_r: f32,
    cohes_r: f32,
    w_sep: f32,
    w_align: f32,
    w_cohes: f32,
    w_goal: f32,
    turn_rate: f32,
    v_min: f32,
    v_max: f32,
};

fn rotate_3d(v: vec3<f32>, yaw: f32, pitch: f32, roll: f32) -> vec3<f32> {
    let xz = rot2(yaw) * v.xz;
    let v1 = vec3<f32>(xz.x, v.y, xz.y);
    let yz = rot2(pitch) * v1.yz;
    let v2 = vec3<f32>(v1.x, yz.x, yz.y);
    let xy = rot2(roll) * v2.xy;
    return vec3<f32>(xy.x, xy.y, v2.z);
}

fn safe_norm3(v: vec3<f32>, fallback: vec3<f32>) -> vec3<f32> {
    let l2 = dot(v, v);
    if (l2 > 1e-10) {
        return v * inverseSqrt(l2);
    }
    return fallback;
}

fn safe_norm2(v: vec2<f32>, fallback: vec2<f32>) -> vec2<f32> {
    let l2 = dot(v, v);
    if (l2 > 1e-10) {
        return v * inverseSqrt(l2);
    }
    return fallback;
}

fn clamp_len3(v: vec3<f32>, max_l: f32) -> vec3<f32> {
    let l2 = dot(v, v);
    if (l2 > max_l * max_l && l2 > 1e-12) {
        return v * (max_l * inverseSqrt(l2));
    }
    return v;
}

fn reflect_range(x: f32, lo: f32, hi: f32) -> f32 {
    let span = max(hi - lo, 1e-4);
    let u = (x - lo) / span;
    let m = u - 2.0 * floor(u * 0.5);
    let f = select(2.0 - m, m, m <= 1.0);
    return lo + f * span;
}

fn next_iso_wp(
    cur: vec2<f32>,
    prev_ang: f32,
    step_idx: u32,
    seed_v: vec2<f32>,
    x_lo: f32,
    x_hi: f32,
    y_lo: f32,
    y_hi: f32,
    d_min: f32,
    d_max: f32,
) -> vec3<f32> {
    let r = hash22(seed_v + vec2<f32>(f32(step_idx) * 13.7, f32(step_idx) * 29.3));
    let ang = prev_ang + (r.x - 0.5) * 2.5;
    let step_d = mix(d_min, d_max, r.y);
    let cand = cur + vec2<f32>(cos(ang), sin(ang)) * step_d;
    var nxt = vec2<f32>(reflect_range(cand.x, x_lo, x_hi), reflect_range(cand.y, y_lo, y_hi));
    if (length(nxt - cur) < d_min * 0.55) {
        let cx = 0.5 * (x_lo + x_hi);
        let cy = 0.5 * (y_lo + y_hi);
        let inward = safe_norm2(
            vec2<f32>(cx - cur.x, cy - cur.y) + vec2<f32>(cos(ang), sin(ang)) * 0.35,
            vec2<f32>(1.0, 0.0),
        );
        nxt = vec2<f32>(
            clamp(cur.x + inward.x * step_d, x_lo, x_hi),
            clamp(cur.y + inward.y * step_d, y_lo, y_hi),
        );
    }
    let dp = nxt - cur;
    let next_ang = atan2(dp.y, dp.x);
    return vec3<f32>(nxt, next_ang);
}

fn catmull_rom2(p0: vec2<f32>, p1: vec2<f32>, p2: vec2<f32>, p3: vec2<f32>, u: f32) -> vec2<f32> {
    let u2 = u * u;
    let u3 = u2 * u;
    return 0.5 * (
        (2.0 * p1)
        + (-p0 + p2) * u
        + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * u2
        + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * u3
    );
}

fn catmull_rom2_deriv(p0: vec2<f32>, p1: vec2<f32>, p2: vec2<f32>, p3: vec2<f32>, u: f32) -> vec2<f32> {
    let u2 = u * u;
    return 0.5 * (
        (-p0 + p2)
        + 2.0 * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * u
        + 3.0 * (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * u2
    );
}

fn iso_waypoint_pos(
    p1_init: vec2<f32>,
    ang_init: f32,
    seed_v: vec2<f32>,
    s: f32,
    speed: f32,
    x_lo: f32,
    x_hi: f32,
    y_lo: f32,
    y_hi: f32,
    d_min: f32,
    d_max: f32,
    max_hops: u32,
) -> vec2<f32> {
    var p1 = p1_init;
    let w1 = next_iso_wp(p1, ang_init, 1u, seed_v, x_lo, x_hi, y_lo, y_hi, d_min, d_max);
    var p2 = w1.xy;
    let w2 = next_iso_wp(p2, w1.z, 2u, seed_v, x_lo, x_hi, y_lo, y_hi, d_min, d_max);
    var p3 = w2.xy;
    var cur_ang = w2.z;
    var p0 = p1 - (p2 - p1);
    var t_acc = 0.0;

    for (var k = 0u; k < max_hops; k = k + 1u) {
        let seg_dur = max(length(p2 - p1) / speed, 0.35);
        if (s <= t_acc + seg_dur || k + 1u == max_hops) {
            let u = clamp((s - t_acc) / seg_dur, 0.0, 1.0);
            let pos = catmull_rom2(p0, p1, p2, p3, u);
            return vec2<f32>(
                clamp(pos.x, x_lo - 0.05, x_hi + 0.05),
                clamp(pos.y, y_lo - 0.04, y_hi + 0.04),
            );
        }
        t_acc = t_acc + seg_dur;
        p0 = p1;
        p1 = p2;
        p2 = p3;
        let w_nxt = next_iso_wp(p2, cur_ang, k + 3u, seed_v, x_lo, x_hi, y_lo, y_hi, d_min, d_max);
        p3 = w_nxt.xy;
        cur_ang = w_nxt.z;
    }
    return p1;
}

fn iso_waypoint_pos_dir(
    p1_init: vec2<f32>,
    ang_init: f32,
    seed_v: vec2<f32>,
    s: f32,
    speed: f32,
    x_lo: f32,
    x_hi: f32,
    y_lo: f32,
    y_hi: f32,
    d_min: f32,
    d_max: f32,
    max_hops: u32,
) -> vec4<f32> {
    var p1 = p1_init;
    let w1 = next_iso_wp(p1, ang_init, 1u, seed_v, x_lo, x_hi, y_lo, y_hi, d_min, d_max);
    var p2 = w1.xy;
    let w2 = next_iso_wp(p2, w1.z, 2u, seed_v, x_lo, x_hi, y_lo, y_hi, d_min, d_max);
    var p3 = w2.xy;
    var cur_ang = w2.z;
    var p0 = p1 - (p2 - p1);
    var t_acc = 0.0;

    for (var k = 0u; k < max_hops; k = k + 1u) {
        let seg_dur = max(length(p2 - p1) / speed, 0.35);
        if (s <= t_acc + seg_dur || k + 1u == max_hops) {
            let u = clamp((s - t_acc) / seg_dur, 0.0, 1.0);
            let pos = catmull_rom2(p0, p1, p2, p3, u);
            let deriv = catmull_rom2_deriv(p0, p1, p2, p3, u);
            let dir = safe_norm2(deriv, safe_norm2(p2 - p1, vec2<f32>(1.0, 0.0)));
            return vec4<f32>(
                clamp(pos.x, x_lo - 0.05, x_hi + 0.05),
                clamp(pos.y, y_lo - 0.04, y_hi + 0.04),
                dir.x,
                dir.y,
            );
        }
        t_acc = t_acc + seg_dur;
        p0 = p1;
        p1 = p2;
        p2 = p3;
        let w_nxt = next_iso_wp(p2, cur_ang, k + 3u, seed_v, x_lo, x_hi, y_lo, y_hi, d_min, d_max);
        p3 = w_nxt.xy;
        cur_ang = w_nxt.z;
    }
    return vec4<f32>(p1, 1.0, 0.0);
}

fn bezel_fade(p: vec2<f32>, a: f32) -> f32 {
    return smoothstep(0.02, 0.08, p.x)
        * (1.0 - smoothstep(a - 0.08, a - 0.02, p.x))
        * smoothstep(0.02, 0.08, p.y)
        * (1.0 - smoothstep(0.92, 0.98, p.y));
}

fn depth_persp(z: f32) -> f32 {
    return 1.0 / (1.0 + clamp(z, -0.45, 0.85) * 0.45);
}

fn regime_spec(arch: u32) -> RegimeSpec {
    if (arch == 0u) {
        // Pelagic Baitballs & Stalking Hunters
        return RegimeSpec(
            0.105, 0.200, 0.300,
            2.35, 1.05, 0.50, 0.78,
            4.8, 0.42, 0.96,
        );
    }
    if (arch == 1u) {
        // Panoramic Reef Ribbons
        return RegimeSpec(
            0.095, 0.180, 0.210,
            2.10, 1.15, 0.26, 1.55,
            4.8, 0.46, 0.92,
        );
    }
    if (arch == 2u) {
        // Open-Sky Wasp & Firefly Swarm
        return RegimeSpec(
            0.074, 0.125, 0.145,
            1.65, 0.22, 0.12, 2.35,
            5.8, 0.52, 1.32,
        );
    }
    // Roaming Abyssal Torus Mills
    return RegimeSpec(
        0.098, 0.155, 0.190,
        2.25, 0.95, 0.22, 1.50,
        4.6, 0.44, 0.94,
    );
}

// Four R/G/B-balanced bioluminescent palettes across body roles and leaders.
fn school_palette(pal: u32, role: u32, is_leader: bool) -> vec3<f32> {
    let p = pal % 4u;
    let r = role % 4u;

    if (p == 0u) {
        // Pelagic Silver & Coral
        if (is_leader) {
            return vec3<f32>(1.00, 0.76, 0.22);
        }
        if (r == 0u) {
            return vec3<f32>(0.22, 0.90, 1.00);
        }
        if (r == 1u) {
            return vec3<f32>(0.14, 0.98, 0.68);
        }
        if (r == 2u) {
            return vec3<f32>(1.00, 0.42, 0.26);
        }
        return vec3<f32>(0.42, 0.66, 1.00);
    }
    if (p == 1u) {
        // Abyssal Biolume
        if (is_leader) {
            return vec3<f32>(1.00, 0.26, 0.44);
        }
        if (r == 0u) {
            return vec3<f32>(0.18, 0.64, 1.00);
        }
        if (r == 1u) {
            return vec3<f32>(0.12, 0.98, 0.84);
        }
        if (r == 2u) {
            return vec3<f32>(0.74, 0.34, 1.00);
        }
        return vec3<f32>(0.34, 0.94, 0.46);
    }
    if (p == 2u) {
        // Koi & Jade Lantern
        if (is_leader) {
            return vec3<f32>(0.20, 0.84, 1.00);
        }
        if (r == 0u) {
            return vec3<f32>(1.00, 0.38, 0.16);
        }
        if (r == 1u) {
            return vec3<f32>(0.14, 0.96, 0.56);
        }
        if (r == 2u) {
            return vec3<f32>(1.00, 0.76, 0.22);
        }
        return vec3<f32>(0.98, 0.28, 0.64);
    }
    // Firefly Dusk
    if (is_leader) {
        return vec3<f32>(1.00, 0.28, 0.74);
    }
    if (r == 0u) {
        return vec3<f32>(1.00, 0.76, 0.18);
    }
    if (r == 1u) {
        return vec3<f32>(0.52, 0.98, 0.24);
    }
    if (r == 2u) {
        return vec3<f32>(0.20, 0.86, 1.00);
    }
    return vec3<f32>(0.70, 0.38, 1.00);
}

fn roam_locus(k: u32, n_foci: u32, gen: u32, phase: f32, a: f32) -> vec3<f32> {
    let fk = f32(k);
    let fg = f32(gen);
    let h = hash22(vec2<f32>(fk * 17.3 + fg * 31.7, g.seed * 59.0 + 3.1));
    let x0 = mix(0.32, a - 0.32, (fk + 0.5) / f32(n_foci));
    let y0 = 0.28 + 0.44 * h.x;
    let seed_v = vec2<f32>(fk * 41.3 + fg * 19.7 + 1.1, g.seed * 97.0 + fk * 7.3);
    let xy = iso_waypoint_pos(
        vec2<f32>(x0, y0),
        h.y * TAU,
        seed_v,
        phase,
        0.32,
        0.26,
        a - 0.26,
        0.24,
        0.76,
        0.70,
        1.40,
        28u,
    );
    let z = 0.14 * sin(phase * 0.46 + fk * 2.1 + fg * 1.7);
    return vec3<f32>(xy, z);
}

fn world_predator_target(arch: u32, pred_id: u32, n_foci: u32, gen: u32, phase: f32, a: f32) -> vec3<f32> {
    let center = roam_locus(pred_id, n_foci, gen, phase, a);
    let ph = hash11(f32(pred_id) * 31.1 + f32(gen) * 17.9 + g.seed * 71.0) * TAU;
    let cycle = fract((phase + ph) / 7.2);
    let lunge = exp(-pow((cycle - 0.5) * 6.5, 2.0));
    let w = phase * 0.74 + ph;
    let r = mix(0.36, 0.03, lunge);
    let z_amp = select(0.15, 0.17, arch == 3u);
    let p = center + vec3<f32>(
        r * cos(w),
        r * 0.85 * sin(w * 1.25 + 0.5),
        z_amp * sin(w * 1.8 - 0.4),
    );
    return vec3<f32>(
        clamp(p.x, 0.10, a - 0.10),
        clamp(p.y, 0.10, 0.90),
        clamp(p.z, -0.26, 0.26),
    );
}

fn world_ribbon_state(branch: u32, n_foci: u32, gen: u32, s_time: f32, a: f32) -> array<vec3<f32>, 2> {
    let fb = f32(branch);
    let fg = f32(gen);
    let h = hash22(vec2<f32>(fb * 23.7 + fg * 37.3, g.seed * 67.0 + 4.7));
    let x0 = mix(0.28, a - 0.28, (fb + 0.5) / f32(n_foci));
    let y0 = 0.22 + 0.56 * h.x;
    let seed_v = vec2<f32>(fb * 53.1 + fg * 29.3 + 2.3, g.seed * 89.0 + fb * 11.7);
    let spd_xy = 0.44;
    let pd = iso_waypoint_pos_dir(
        vec2<f32>(x0, y0),
        h.y * TAU,
        seed_v,
        s_time,
        spd_xy,
        0.16,
        a - 0.16,
        0.16,
        0.84,
        0.70,
        1.40,
        36u,
    );
    let z = 0.18 * sin(s_time * 0.70 + fb * 2.1 + fg * 1.3);
    let dz = 0.18 * 0.70 * cos(s_time * 0.70 + fb * 2.1 + fg * 1.3);
    let pos = vec3<f32>(pd.xy, z);
    let dir = safe_norm3(vec3<f32>(pd.zw * spd_xy, dz), vec3<f32>(1.0, 0.0, 0.0));
    return array<vec3<f32>, 2>(pos, dir);
}

fn world_wasp_target(wasp_id: u32, n_wasps: u32, gen: u32, phase: f32, a: f32) -> vec3<f32> {
    let fw = f32(wasp_id);
    let fg = f32(gen);
    let h = hash22(vec2<f32>(fw * 19.9 + fg * 27.1, g.seed * 53.0 + 6.1));
    let x0 = mix(0.22, a - 0.22, (fw + 0.5) / f32(n_wasps));
    let y0 = 0.20 + 0.60 * h.x;
    let seed_v = vec2<f32>(fw * 61.7 + fg * 31.1 + 3.9, g.seed * 83.0 + fw * 13.1);
    let xy = iso_waypoint_pos(
        vec2<f32>(x0, y0),
        h.y * TAU,
        seed_v,
        phase,
        0.76,
        0.14,
        a - 0.14,
        0.14,
        0.86,
        0.75,
        1.45,
        42u,
    );
    let z = 0.20 * sin(phase * 1.35 + fw * 1.9 + fg * 1.5);
    return vec3<f32>(xy, z);
}

fn spawn_agent(
    arch: u32,
    pal_id: u32,
    spec: RegimeSpec,
    agent_id: u32,
    n_active: u32,
    n_foci: u32,
    n_wasps: u32,
    gen: u32,
    phase: f32,
    a: f32,
) -> Particle {
    let fi = f32(agent_id);
    let fg = f32(gen);
    let h0 = hash22(vec2<f32>(fi * 1.93 + fg * 17.3, fg * 31.7 + g.seed * 67.0));
    let h1 = hash22(vec2<f32>(fi * 3.11 + fg * 23.9, fg * 41.7 + g.seed * 53.0));

    let is_pred = (arch == 0u || arch == 3u) && agent_id < n_foci;
    let is_wasp = (arch == 2u) && agent_id < n_wasps;
    let is_leader = is_pred || is_wasp;

    var pos = vec3<f32>(0.0);
    var vel = vec3<f32>(0.0);
    let u = (fi + 0.5) / max(f32(n_active), 1.0);
    let ang = fi * 2.3999632 + h0.x * 0.6;

    if (is_pred) {
        pos = world_predator_target(arch, agent_id, n_foci, gen, phase, a);
        let p_next = world_predator_target(arch, agent_id, n_foci, gen, phase + 0.08, a);
        vel = safe_norm3(p_next - pos, vec3<f32>(1.0, 0.0, 0.0)) * 0.72;
    } else if (is_wasp) {
        pos = world_wasp_target(agent_id, n_wasps, gen, phase, a);
        let p_next = world_wasp_target(agent_id, n_wasps, gen, phase + 0.06, a);
        vel = safe_norm3(p_next - pos, vec3<f32>(0.0, 1.0, 0.0)) * 1.05;
    } else if (arch == 3u) {
        // 1:1 circular 3D torus mills centered on roaming loci.
        let k = agent_id % n_foci;
        let center = roam_locus(k, n_foci, gen, phase, a);
        let tilt = 0.30 * sin(phase * 0.18 + f32(k));
        let ring_a = u * TAU + f32(k) * 0.9;
        let ring_r = 0.22 + 0.055 * (h0.x - 0.5);
        let local_p = vec3<f32>(ring_r * cos(ring_a), ring_r * sin(ring_a), 0.055 * (h0.y - 0.5));
        let local_v = normalize(vec3<f32>(-sin(ring_a), cos(ring_a), 0.12 * (h1.x - 0.5))) * 0.64;
        pos = center + rotate_3d(local_p, -tilt, -tilt * 0.6, 0.0);
        vel = rotate_3d(local_v, -tilt, -tilt * 0.6, 0.0);
    } else if (arch == 1u) {
        // Staggered along panoramic equal-speed 3D reef ribbon curves.
        let branch = agent_id % n_foci;
        let s_cur = max(phase + 9.0 - (1.0 - u) * 8.4, 0.1);
        let st_r = world_ribbon_state(branch, n_foci, gen, s_cur, a);
        let lat_off = vec3<f32>(h0.x - 0.5, h0.y - 0.5, h1.x - 0.5) * 0.12;
        pos = st_r[0] + lat_off;
        vel = st_r[1] * 0.64;
    } else if (arch == 2u) {
        // Airy 3D clouds around each roaming queen wasp.
        let wid = agent_id % n_wasps;
        let center_w = world_wasp_target(wid, n_wasps, gen, phase, a);
        let rr = 0.08 + pow(fract(u * f32(n_wasps) + h0.x * 0.2), 0.6) * 0.22;
        let phi = acos(clamp(1.0 - 2.0 * h0.y, -0.98, 0.98));
        pos = center_w + vec3<f32>(
            rr * sin(phi) * cos(ang),
            rr * sin(phi) * sin(ang),
            rr * cos(phi) * 0.70,
        );
        vel = safe_norm3(vec3<f32>(-sin(ang), cos(ang), h1.x - 0.5), vec3<f32>(1.0, 0.0, 0.0)) * 0.82;
    } else {
        // Pelagic 3D baitballs around roaming loci.
        let k = agent_id % n_foci;
        let center = roam_locus(k, n_foci, gen, phase, a);
        let rr = 0.09 + pow(fract(u * f32(n_foci) + h0.x * 0.2), 0.5) * 0.22;
        let phi = acos(clamp(1.0 - 2.0 * h0.y, -0.98, 0.98));
        let rel = vec3<f32>(
            rr * sin(phi) * cos(ang),
            rr * sin(phi) * sin(ang),
            rr * cos(phi) * 0.70,
        );
        pos = center + rel;
        let tang = safe_norm3(vec3<f32>(-rel.y, rel.x, 0.22 * (h1.x - 0.5)), vec3<f32>(1.0, 0.0, 0.0));
        vel = tang * mix(spec.v_min, spec.v_max * 0.78, h1.y);
    }

    pos = vec3<f32>(
        clamp(pos.x, 0.06, a - 0.06),
        clamp(pos.y, 0.07, 0.93),
        clamp(pos.z, -0.28, 0.28),
    );

    let role = agent_id % 4u;
    let col = school_palette(pal_id, role, is_leader);
    let swim_phase = fract(h0.x + h1.y) * TAU;
    let packed_gen = f32((gen % 16777215u) + 1u);

    var out: Particle;
    out.p = vec4<f32>(pos, select(0.15, 0.42, is_leader));
    out.v = vec4<f32>(vel, swim_phase);
    out.c = vec4<f32>(col, packed_gen);
    return out;
}

// Rasterize an undulating 3D fish silhouette into `splat_buf` with energy-conserving AA.
fn splat_fish(
    p_cur3: vec3<f32>,
    p_prev3: vec3<f32>,
    v3: vec3<f32>,
    col: vec3<f32>,
    swim_phase: f32,
    flash: f32,
    is_pred: bool,
    env: f32,
    a: f32,
) {
    if (env <= 0.003) {
        return;
    }
    let world_c = p_cur3.xy;
    let alpha_env = env * bezel_fade(world_c, a);
    if (alpha_env <= 0.003) {
        return;
    }

    let v_dir = safe_norm3(v3, vec3<f32>(1.0, 0.0, 0.0));
    let fwd = safe_norm2(v_dir.xy, vec2<f32>(1.0, 0.0));
    let right = vec2<f32>(-fwd.y, fwd.x);
    let persp = depth_persp(p_cur3.z);
    let fshort = clamp(length(v_dir.xy), 0.42, 1.0);

    // Sleek fusiform dimensions in canvas heights (1:1 isotropic).
    let base_len = select(0.062, 0.096, is_pred) * persp * mix(0.56, 1.0, fshort);
    let base_hw = select(0.0108, 0.0168, is_pred) * persp;
    let w_d = clamp(1.14 - p_cur3.z * 0.46, 0.48, 1.32);

    let dims = splat_dims();
    let h = f32(dims.y);
    let len_px = base_len * h;
    let hw_px = base_hw * h;
    let hw_eff = max(hw_px, 0.65);
    let energy = clamp(hw_px / hw_eff, 0.30, 1.0);

    // Slipstream wake bridge across rapid motion steps.
    let world_p = p_prev3.xy;
    let step_d = length(world_c - world_p);
    if (step_d > base_len * 0.45 && step_d < 0.28) {
        let wake_col = col * (0.24 * w_d * alpha_env);
        splat_segment(
            world_p,
            world_c,
            wake_col,
            0.14 * w_d * alpha_env,
            false,
        );
    }

    let center_uv = state_uv(world_c);
    let center_px = center_uv * vec2<f32>(dims) - 0.5;
    let max_rad = select(24, 32, is_pred);
    let rad_x = clamp(i32(ceil(abs(fwd.x) * len_px * 0.62 + abs(right.x) * hw_eff * 2.2 + 1.5)), 1, max_rad);
    let rad_y = clamp(i32(ceil(abs(fwd.y) * len_px * 0.62 + abs(right.y) * hw_eff * 2.2 + 1.5)), 1, max_rad);
    let base = vec2<i32>(round(center_px));

    let inv_len = 1.0 / max(len_px, 1.0);
    let tail_amp = select(0.26, 0.22, is_pred) * len_px * 0.26;
    let irid_col = mix(col, vec3<f32>(0.94, 0.99, 1.0), 0.62);

    for (var dy = -rad_y; dy <= rad_y; dy = dy + 1) {
        let cy = base.y + dy;
        if (cy < 0 || cy >= dims.y) {
            continue;
        }
        let rel_y = center_px.y - f32(cy);
        for (var dx = -rad_x; dx <= rad_x; dx = dx + 1) {
            let cx = base.x + dx;
            if (cx < 0 || cx >= dims.x) {
                continue;
            }
            let rel = vec2<f32>(f32(cx) - center_px.x, rel_y);

            // Project pixel into fish body coordinates: u along spine (+0.45 nose to -0.55 tail), v lateral.
            let u = dot(rel, fwd) * inv_len;
            if (u < -0.62 || u > 0.52) {
                continue;
            }
            let s = clamp(0.45 - u, 0.0, 1.0);
            let sway = sin(swim_phase - s * 4.5) * (tail_amp * s * s);
            let v_px = dot(rel, right) - sway;

            // Fusiform silhouette width profile + flared forked caudal fin at s > 0.74.
            var w_prof = 0.0;
            var is_fin = false;
            if (s < 0.74) {
                let k_nose = smoothstep(0.0, 0.22, s);
                let k_tail = pow(clamp(1.0 - max(s - 0.20, 0.0) / 0.58, 0.0, 1.0), 0.76);
                w_prof = hw_eff * (0.16 + 0.90 * k_nose * k_tail);
                if (is_pred && s > 0.22 && s < 0.44) {
                    let fin_u = (s - 0.22) / 0.22;
                    w_prof = max(w_prof, hw_eff * (0.85 + 1.05 * sin(fin_u * PI) * fin_u));
                }
            } else {
                let tf = (s - 0.74) / 0.26;
                let outer = hw_eff * mix(0.24, 1.05, tf);
                let notch = hw_eff * max(tf - 0.22, 0.0) * 0.64;
                if (abs(v_px) < notch) {
                    continue;
                }
                w_prof = outer;
                is_fin = true;
            }

            let d_edge = abs(v_px) - w_prof;
            if (d_edge > 0.90) {
                continue;
            }
            let cov = (1.0 - smoothstep(-0.60, 0.60, d_edge)) * energy * alpha_env;
            if (cov <= 0.002) {
                continue;
            }

            let lat_n = clamp(abs(v_px) / max(w_prof, 0.5), 0.0, 1.0);
            let nz = sqrt(max(1.0 - lat_n * lat_n, 0.0));
            let fres = pow(1.0 - nz, 1.85);
            let lateral_line = exp(-lat_n * lat_n * 7.5) * (1.0 - smoothstep(0.62, 0.92, s));
            let fin_tint = select(1.0, 0.74, is_fin);

            var shaded = col * (0.36 + 0.48 * nz + 0.74 * fres) * fin_tint
                + irid_col * ((0.24 + 0.66 * flash) * lateral_line + 0.34 * fres);
            let nose_glow = exp(-pow((s - 0.13) * 9.5, 2.0)) * nz;
            shaded = shaded + mix(col, vec3<f32>(1.0, 0.98, 0.92), 0.68) * (nose_glow * (0.44 + 0.34 * flash));
            shaded = clamp(shaded, vec3<f32>(0.0), vec3<f32>(1.50));

            let w_splat = cov * w_d;
            splat_pixel(vec2<i32>(cx, cy), vec4<f32>(shaded * w_splat, w_splat));
        }
    }
}

// Rasterize a sleek darting wasp/firefly streak into `splat_buf` for XSwarm (arch == 2u).
fn splat_swarm(
    p_cur3: vec3<f32>,
    p_prev3: vec3<f32>,
    v3: vec3<f32>,
    col: vec3<f32>,
    flash: f32,
    is_wasp: bool,
    env: f32,
    a: f32,
) {
    if (env <= 0.003) {
        return;
    }
    let world_c = p_cur3.xy;
    let alpha_env = env * bezel_fade(world_c, a);
    if (alpha_env <= 0.003) {
        return;
    }

    let spd = length(v3);
    let v_dir = safe_norm3(v3, vec3<f32>(1.0, 0.0, 0.0));
    let tail_len = clamp(spd * 0.075, 0.032, 0.105) * depth_persp(p_cur3.z);
    let tail_w = world_c - v_dir.xy * tail_len;
    let w_d = clamp(1.18 - p_cur3.z * 0.42, 0.52, 1.38);

    let dims = splat_dims();
    let h = f32(dims.y);

    if (is_wasp) {
        let wasp_col = mix(col, vec3<f32>(1.0, 0.97, 0.92), 0.50);
        let rad = 0.0115;
        let area_scale = max(rad * h, 0.85);
        let e = area_scale * area_scale * 0.58 * w_d * alpha_env;
        splat_disc(world_c, rad, wasp_col * e, e * 1.65, false);
        splat_segment(tail_w, world_c, col * (1.05 * w_d * alpha_env), 0.35 * w_d * alpha_env, false);
    } else {
        let head_col = mix(col, vec3<f32>(1.0, 0.98, 0.92), 0.36 + 0.36 * flash);
        let rad = 0.0066;
        let area_scale = max(rad * h, 0.72);
        let e = area_scale * area_scale * 0.48 * w_d * alpha_env;
        splat_disc(world_c, rad, head_col * e, e * 1.65, false);

        let world_p = p_prev3.xy;
        let seg_start = select(
            tail_w,
            world_p,
            length(world_c - world_p) > length(world_c - tail_w) && length(world_c - world_p) < 0.28,
        );
        splat_segment(seg_start, world_c, col * (0.98 * w_d * alpha_env), 0.30 * w_d * alpha_env, false);
    }
}

fn step_particle(idx: u32, t: f32) {
    let frame_u = u32(round(max(g.frame, 0.0)));
    let write_half = frame_u & 1u;
    let read_half = 1u - write_half;
    let read_base = read_half * MAX_AGENTS;
    let write_base = write_half * MAX_AGENTS;

    if (idx < write_base || idx >= write_base + MAX_AGENTS) {
        return;
    }

    let agent_id = idx - write_base;
    let a = aspect();
    let n_active = clamp(u32(round(90.0 * a)), 120u, MAX_AGENTS);
    if (agent_id >= n_active) {
        return;
    }

    let seed_off = (0.14 + 0.56 * hash11(g.seed * 41.0 + 3.7)) * EPOCH_SECS;
    let cycle_t = t + seed_off;
    let gen = u32(max(floor(cycle_t / EPOCH_SECS), 0.0));
    let phase = cycle_t - f32(gen) * EPOCH_SECS;
    let u_epoch = phase / EPOCH_SECS;
    let env = smoothstep(0.0, 0.06, u_epoch) * (1.0 - smoothstep(0.94, 1.0, u_epoch));

    let arch = (gen + u32(g.seed * 13.0)) % 4u;
    let pal_id = (gen * 3u + u32(g.seed * 17.0)) % 4u;
    let spec = regime_spec(arch);
    let n_foci = select(4u, 2u, a < 2.4);
    let n_wasps = select(4u, 2u, a < 2.4);

    let st = particles[read_base + agent_id];
    let packed_now = f32((gen % 16777215u) + 1u);
    let uninit = g.frame < 0.5
        || st.c.w <= 0.5
        || abs(st.c.w - packed_now) > 0.5
        || !all(st.p.xyz == st.p.xyz)
        || !all(st.v.xyz == st.v.xyz);

    if (uninit) {
        let sp = spawn_agent(arch, pal_id, spec, agent_id, n_active, n_foci, n_wasps, gen, phase, a);
        particles[write_base + agent_id] = sp;
        let is_pred = (arch == 0u || arch == 3u) && agent_id < n_foci;
        let is_wasp = (arch == 2u) && agent_id < n_wasps;
        if (arch == 2u) {
            splat_swarm(sp.p.xyz, sp.p.xyz, sp.v.xyz, sp.c.rgb, sp.p.w, is_wasp, env, a);
        } else {
            splat_fish(sp.p.xyz, sp.p.xyz, sp.v.xyz, sp.c.rgb, sp.v.w, sp.p.w, is_pred, env, a);
        }
        return;
    }

    let dt = clamp(g.dt, 1e-4, 0.14);
    let pos = st.p.xyz;
    let vel = st.v.xyz;
    var flash = st.p.w * exp(-dt * 3.2);
    var swim_phase = st.v.w;
    let col = st.c.rgb;

    let is_pred = (arch == 0u || arch == 3u) && agent_id < n_foci;
    let is_wasp = (arch == 2u) && agent_id < n_wasps;
    let n_leaders = select(0u, select(n_foci, n_wasps, arch == 2u), arch != 1u);

    var v_new = vel;
    var p_new = pos;
    var turn_rate = spec.turn_rate;
    var speed_min = spec.v_min;
    var speed_max = spec.v_max;

    if (is_pred) {
        let goal = world_predator_target(arch, agent_id, n_foci, gen, phase + 0.18, a);
        let desired = safe_norm3(goal - pos, safe_norm3(vel, vec3<f32>(1.0, 0.0, 0.0))) * 0.74;
        let k_blend = 1.0 - exp(-5.2 * dt);
        v_new = mix(vel, desired, k_blend);
        speed_min = 0.45;
        speed_max = 0.88;
        flash = max(flash, 0.25);
    } else if (is_wasp) {
        let goal = world_wasp_target(agent_id, n_wasps, gen, phase + 0.12, a);
        let desired = safe_norm3(goal - pos, safe_norm3(vel, vec3<f32>(0.0, 1.0, 0.0))) * 1.15;
        let k_blend = 1.0 - exp(-8.5 * dt);
        v_new = mix(vel, desired, k_blend);
        speed_min = 0.70;
        speed_max = 1.32;
        flash = max(flash, 0.45);
    } else {
        // Reynolds 3D boids neighbor scan + predator scatter / wasp chase across the full world volume.
        var sep = vec3<f32>(0.0);
        var align = vec3<f32>(0.0);
        var cohes = vec3<f32>(0.0);
        var n_align = 0.0;
        var n_cohes = 0.0;
        var flee_vec = vec3<f32>(0.0);
        var flee_strength = 0.0;
        var wasp_chase = vec3<f32>(0.0);
        var best_wasp_d2 = 1e6;

        let sep_r2 = spec.sep_r * spec.sep_r;
        let align_r2 = spec.align_r * spec.align_r;
        let cohes_r2 = spec.cohes_r * spec.cohes_r;
        let pref_wasp = (agent_id + u32(floor(phase * 0.14))) % n_wasps;

        for (var j = 0u; j < n_active; j = j + 1u) {
            if (j == agent_id) {
                continue;
            }
            let nb = particles[read_base + j];
            if (nb.c.w <= 0.5 || abs(nb.c.w - packed_now) > 0.5 || !all(nb.p.xyz == nb.p.xyz)) {
                continue;
            }
            let d = pos - nb.p.xyz;
            let nb_is_leader = j < n_leaders;

            if (nb_is_leader) {
                let dist2 = dot(d, d);
                if (arch == 2u) {
                    let eff_d2 = select(dist2, dist2 * 0.50, j == pref_wasp);
                    if (eff_d2 < best_wasp_d2) {
                        best_wasp_d2 = eff_d2;
                        wasp_chase = nb.p.xyz - pos;
                    }
                } else if (dist2 < 0.28 * 0.28 && dist2 > 1e-6) {
                    let dist = sqrt(dist2);
                    let w_flee = smoothstep(0.28, 0.03, dist);
                    flee_vec = flee_vec + (d / dist) * (w_flee * 4.2);
                    flee_strength = max(flee_strength, w_flee);
                }
                continue;
            }

            if (abs(d.x) >= spec.cohes_r || abs(d.y) >= spec.cohes_r || abs(d.z) >= spec.cohes_r) {
                continue;
            }
            let dist2 = dot(d, d);
            if (dist2 >= cohes_r2) {
                continue;
            }

            if (dist2 < sep_r2 && dist2 > 1e-7) {
                let inv_d = inverseSqrt(dist2);
                let dist = 1.0 / inv_d;
                let k = clamp(1.0 - dist / spec.sep_r, 0.0, 1.0);
                sep = sep + (d * inv_d) * (k * (0.7 + 0.6 * k));
            }
            if (dist2 < align_r2) {
                align = align + nb.v.xyz;
                n_align = n_align + 1.0;
            }
            cohes = cohes + nb.p.xyz;
            n_cohes = n_cohes + 1.0;
        }

        var steer = sep * spec.w_sep;
        if (n_align > 0.5) {
            steer = steer + safe_norm3(align / n_align, vel) * spec.w_align;
        }
        if (n_cohes > 0.5) {
            let center_dir = (cohes / n_cohes) - pos;
            steer = steer + clamp_len3(center_dir * 3.5, 1.0) * spec.w_cohes;
        }

        // Regime-specific world-space current or goal field.
        if (arch == 0u) {
            // Pelagic Baitballs: soft assignment to nearest roaming locus + dramatic predator burst scatter.
            let pref_k = agent_id % n_foci;
            var best_c = roam_locus(0u, n_foci, gen, phase, a);
            var best_score = 1e6;
            for (var k = 0u; k < n_foci; k = k + 1u) {
                let c = roam_locus(k, n_foci, gen, phase, a);
                let d_l = length(pos - c) * select(1.0, 0.72, k == pref_k);
                if (d_l < best_score) {
                    best_score = d_l;
                    best_c = c;
                }
            }
            let rel_c = pos - best_c;
            let r_ball = max(length(rel_c), 1e-4);
            let tang = vec3<f32>(-rel_c.y, rel_c.x, 0.18 * sin(phase * 0.7 + f32(agent_id)));
            let shell_pull = (0.21 - r_ball) * 2.2;
            steer = steer + (safe_norm3(rel_c, vec3<f32>(1.0, 0.0, 0.0)) * shell_pull + safe_norm3(tang, vec3<f32>(1.0, 0.0, 0.0)) * 0.90) * spec.w_goal;
            if (flee_strength > 0.01) {
                steer = steer + flee_vec * 2.6;
                turn_rate = mix(turn_rate, 11.5, flee_strength);
                speed_max = mix(speed_max, 1.30, flee_strength);
                flash = max(flash, flee_strength);
            }
        } else if (arch == 1u) {
            // Panoramic Reef Ribbons: stagger fish cleanly along isotropic Catmull-Rom streams across the whole width.
            let branch = agent_id % n_foci;
            let rank_u = f32(agent_id) / max(f32(n_active), 1.0);
            let lag = rank_u * 8.4;
            let s_cur = max(phase + 9.0 - lag, 0.1);
            let st_r = world_ribbon_state(branch, n_foci, gen, s_cur + 0.25, a);
            let p_tgt = st_r[0];
            let flow_dir = st_r[1];
            let to_spline = p_tgt - pos;
            steer = steer + (clamp_len3(to_spline * 4.5, 1.35) + flow_dir * 0.95) * spec.w_goal;
        } else if (arch == 2u) {
            // Open-Sky Wasp & Firefly Swarm: snap toward roaming queen wasps with orbital curl.
            let j_off = vec3<f32>(
                sin(phase * 2.6 + f32(agent_id) * 1.7),
                cos(phase * 2.3 + f32(agent_id) * 2.1),
                sin(phase * 2.0 - f32(agent_id) * 1.3),
            ) * 0.095;
            let swirl = safe_norm3(vec3<f32>(-wasp_chase.y, wasp_chase.x, wasp_chase.z * 0.3), vec3<f32>(0.0, 1.0, 0.0));
            steer = steer + (safe_norm3(wasp_chase + j_off, vel) * 0.85 + swirl * 0.35) * spec.w_goal;
            let near_w = smoothstep(0.16, 0.02, sqrt(max(best_wasp_d2, 0.0)));
            flash = max(flash, near_w * 0.80);
        } else {
            // Roaming Abyssal Torus Mills: 1:1 circular 3D torus swirl + predator parting surge.
            let pref_k = agent_id % n_foci;
            var best_k = 0u;
            var best_c = roam_locus(0u, n_foci, gen, phase, a);
            var best_score = 1e6;
            for (var k = 0u; k < n_foci; k = k + 1u) {
                let c = roam_locus(k, n_foci, gen, phase, a);
                let d_l = length(pos - c) * select(1.0, 0.72, k == pref_k);
                if (d_l < best_score) {
                    best_score = d_l;
                    best_c = c;
                    best_k = k;
                }
            }
            let tilt = 0.30 * sin(phase * 0.18 + f32(best_k));
            let local_p = rotate_3d(pos - best_c, tilt, tilt * 0.6, 0.0);
            let r_xy = max(length(local_p.xy), 1e-4);
            let ring_r = 0.22;
            let rad_dir = vec3<f32>(local_p.xy / r_xy, 0.0);
            let tang_dir = vec3<f32>(-rad_dir.y, rad_dir.x, 0.0);
            let torus_force_local = rad_dir * ((ring_r - r_xy) * 5.2)
                + tang_dir * 1.45
                + vec3<f32>(0.0, 0.0, -local_p.z * 4.5);
            let torus_force = rotate_3d(torus_force_local, -tilt, -tilt * 0.6, 0.0);
            steer = steer + torus_force * spec.w_goal;
            if (flee_strength > 0.01) {
                steer = steer + flee_vec * 2.2;
                turn_rate = mix(turn_rate, 10.0, flee_strength);
                speed_max = mix(speed_max, 1.24, flee_strength);
                flash = max(flash, flee_strength * 0.9);
            }
        }

        // Smooth outer bezel turn-back keeps swimmers cleanly inside the visible monitor.
        if (pos.x < 0.10) {
            steer.x = steer.x + (0.10 - pos.x) * 38.0;
        } else if (pos.x > a - 0.10) {
            steer.x = steer.x - (pos.x - (a - 0.10)) * 38.0;
        }
        if (pos.y < 0.10) {
            steer.y = steer.y + (0.10 - pos.y) * 38.0;
        } else if (pos.y > 0.90) {
            steer.y = steer.y - (pos.y - 0.90) * 38.0;
        }
        if (abs(pos.z) > 0.24) {
            steer.z = steer.z - sign(pos.z) * (abs(pos.z) - 0.24) * 38.0;
        }

        let target_spd = mix(speed_min, speed_max, clamp(0.45 + 0.55 * flee_strength, 0.0, 1.0));
        let desired_v = safe_norm3(steer, safe_norm3(vel, vec3<f32>(1.0, 0.0, 0.0))) * target_spd;

        if (arch == 2u) {
            let accel = (desired_v - vel) * 3.0;
            v_new = vel + accel * dt;
            v_new = v_new * exp(-0.28 * dt);
        } else {
            let k_blend = 1.0 - exp(-turn_rate * dt);
            let bank = length(desired_v - vel);
            flash = max(flash, clamp(bank * 0.58, 0.0, 0.68));
            v_new = mix(vel, desired_v, k_blend);
        }
    }

    let spd_new = length(v_new);
    if (spd_new < speed_min) {
        v_new = safe_norm3(v_new, vec3<f32>(1.0, 0.0, 0.0)) * speed_min;
    } else if (spd_new > speed_max) {
        v_new = v_new * (speed_max / spd_new);
    }

    p_new = pos + v_new * dt;
    // Soft safety bounce against the monitor bezels and outer depth walls.
    if (p_new.x < 0.03) {
        p_new.x = 0.03;
        v_new.x = abs(v_new.x) * 0.65;
    } else if (p_new.x > a - 0.03) {
        p_new.x = a - 0.03;
        v_new.x = -abs(v_new.x) * 0.65;
    }
    if (p_new.y < 0.03) {
        p_new.y = 0.03;
        v_new.y = abs(v_new.y) * 0.65;
    } else if (p_new.y > 0.97) {
        p_new.y = 0.97;
        v_new.y = -abs(v_new.y) * 0.65;
    }
    if (abs(p_new.z) > 0.36) {
        p_new.z = clamp(p_new.z, -0.36, 0.36);
        v_new.z = -v_new.z * 0.65;
    }

    let final_spd = length(v_new);
    swim_phase = (swim_phase + (6.8 + final_spd * 12.0) * dt) % TAU;

    if (!all(p_new == p_new) || !all(v_new == v_new)) {
        let sp = spawn_agent(arch, pal_id, spec, agent_id, n_active, n_foci, n_wasps, gen, phase, a);
        particles[write_base + agent_id] = sp;
        return;
    }

    var next_st: Particle;
    next_st.p = vec4<f32>(p_new, clamp(flash, 0.0, 1.0));
    next_st.v = vec4<f32>(v_new, swim_phase);
    next_st.c = vec4<f32>(col, packed_now);
    particles[write_base + agent_id] = next_st;

    if (arch == 2u) {
        splat_swarm(p_new, pos, v_new, col, next_st.p.w, is_wasp, env, a);
    } else {
        splat_fish(p_new, pos, v_new, col, swim_phase, next_st.p.w, is_pred, env, a);
    }
}

fn resolve_state(uv: vec2<f32>, _p: vec2<f32>, _t: f32, splat: vec4<f32>) -> vec4<f32> {
    let dims = splat_dims();
    var prev = state_sample(uv);
    if (dims.y >= 180) {
        let tex = state_texel();
        let blur = (
            state_sample(uv + vec2<f32>(tex.x, 0.0))
            + state_sample(uv - vec2<f32>(tex.x, 0.0))
            + state_sample(uv + vec2<f32>(0.0, tex.y))
            + state_sample(uv - vec2<f32>(0.0, tex.y))
        ) * 0.25;
        let diff = clamp(g.dt * 7.5, 0.0, 0.22);
        prev = mix(prev, blur, diff);
    }

    // Step vacated solid interiors down swiftly into silky liquid wakes while preserving faint wake trails.
    let drop_scale = clamp(g.dt / 0.01667, 0.25, 2.5);
    let wake_drop = mix(1.0, pow(0.32, drop_scale), clamp(prev.a, 0.0, 1.0));
    let wake = prev.rgb * (g.fade * wake_drop);

    let body_cov = clamp(splat.a, 0.0, 1.0);
    let body_rgb = splat.rgb / max(splat.a, 1.0);
    let out_rgb = wake * (1.0 - body_cov * 0.85) + body_rgb;
    return vec4<f32>(out_rgb, body_cov);
}

fn hack(p: vec2<f32>, _t: f32) -> vec3<f32> {
    let uv = state_uv(p);
    let s = state_sample(uv);
    let d = state_texel();

    let h_card = state_sample(uv + vec2<f32>(d.x * 1.4, 0.0))
        + state_sample(uv - vec2<f32>(d.x * 1.4, 0.0))
        + state_sample(uv + vec2<f32>(0.0, d.y * 1.4))
        + state_sample(uv - vec2<f32>(0.0, d.y * 1.4));
    let h_diag = state_sample(uv + vec2<f32>(d.x * 2.4, d.y * 2.4))
        + state_sample(uv + vec2<f32>(-d.x * 2.4, d.y * 2.4))
        + state_sample(uv + vec2<f32>(d.x * 2.4, -d.y * 2.4))
        + state_sample(uv + vec2<f32>(-d.x * 2.4, -d.y * 2.4));
    let halo = (h_card + h_diag) * 0.125;

    let raw_rgb = max(s.rgb + halo.rgb * 0.26, vec3<f32>(0.0));
    let peak_c = max(raw_rgb.r, max(raw_rgb.g, raw_rgb.b));
    if (peak_c <= 1e-4 && s.a <= 1e-4) {
        return vec3<f32>(0.0);
    }

    // Chromaticity-preserving exponential tone mapping keeps bioluminescent schools crisp and saturated.
    let mapped_lum = 1.0 - exp(-peak_c * 1.60);
    let out_col = raw_rgb * (mapped_lum / max(peak_c, 1e-4));
    return clamp(out_col, vec3<f32>(0.0), vec3<f32>(1.0));
}

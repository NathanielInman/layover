// Tidal Spiral: colliding 3D spiral galaxies pulling luminous tidal bridges,
// warped discs and orbital gravitational slingshot streams across the full
// open canvas on Tier P compute particles and stationary Tier S feedback
// textures.
// After xscreensaver's Galaxy (Uli Siegmund, Harald Backert, Hubert Feyrer,
// Jamie Zawinski) and Grav (Greg Bowering).
//
// Particle buffer layout (`particles[idx]`):
//   p.xyz = 3D position relative to its pair's barycenter (canvas heights)
//   p.w   = intrinsic star luminosity multiplier (negative flag encodes supergiant/H-II glow)
//   v.xyz = 3D velocity relative to its pair's barycenter (canvas heights/sec)
//   v.w   = baseline orbital speed (for pericenter / slingshot brightening)
//   c.rgb = spectral base RGB color
//   c.w   = packed integer `(gen % 16777215u) + 1u` stored exact in f32 (0 = uninit)

const EPOCH_SECS: f32 = 34.0;
const GAL_G: f32 = 0.0025;
const GRAV_G: f32 = 0.00145;
const W_TRAIL: f32 = 0.00088;
const W_STAR: f32 = 0.0032;
const GRAV_TRACERS_PER_PAIR: u32 = 180u;

struct Core {
    pos: vec3<f32>,
    vel: vec3<f32>,
    mass: f32,
    soft: f32,
    disc_r: f32,
    tilt_x: f32,
    tilt_y: f32,
    spin: f32,
    arms: f32,
    pal_alt: f32,
};

struct CoreSet {
    count: u32,
    c0: Core,
    c1: Core,
    c2: Core,
};

// Apply small out-of-plane tilts (`yaw`, `pitch`) then rotate freely in screen plane (`roll`),
// keeping galactic discs in an expressive 3/4 oblique view instead of knife-edge slivers.
fn rotate_3d(v: vec3<f32>, yaw: f32, pitch: f32, roll: f32) -> vec3<f32> {
    let xz = rot2(yaw) * v.xz;
    let v1 = vec3<f32>(xz.x, v.y, xz.y);
    let yz = rot2(pitch) * v1.yz;
    let v2 = vec3<f32>(v1.x, yz.x, yz.y);
    let xy = rot2(roll) * v2.xy;
    return vec3<f32>(xy.x, xy.y, v2.z);
}

fn disc_to_world(v: vec3<f32>, tilt_x: f32, tilt_y: f32) -> vec3<f32> {
    let yz = rot2(tilt_x) * v.yz;
    let v1 = vec3<f32>(v.x, yz.x, yz.y);
    let xz = rot2(tilt_y) * v1.xz;
    return vec3<f32>(xz.x, v1.y, xz.y);
}

fn safe_norm2(v: vec2<f32>, fallback: vec2<f32>) -> vec2<f32> {
    let l2 = dot(v, v);
    if (l2 > 1e-10) {
        return v * inverseSqrt(l2);
    }
    return fallback;
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

fn bezel_fade(p: vec2<f32>, a: f32) -> f32 {
    return smoothstep(0.02, 0.08, p.x)
        * (1.0 - smoothstep(a - 0.08, a - 0.02, p.x))
        * smoothstep(0.02, 0.08, p.y)
        * (1.0 - smoothstep(0.92, 0.98, p.y));
}

// Curated astronomical palettes: warm galactic bulge, saturated blue-cyan young
// arm stars, vivid H-II star-forming knots, and deep cobalt outer tidal halo.
fn star_palette(pal: u32, role: u32) -> vec3<f32> {
    let p = pal % 4u;
    if (p == 0u) {
        // Andromeda Sapphire & Amber
        if (role == 0u) {
            return vec3<f32>(1.00, 0.72, 0.28);
        }
        if (role == 1u) {
            return vec3<f32>(0.24, 0.72, 1.00);
        }
        if (role == 2u) {
            return vec3<f32>(1.00, 0.22, 0.56);
        }
        return vec3<f32>(0.18, 0.34, 0.94);
    }
    if (p == 1u) {
        // Lagoon Aquamarine & Champagne
        if (role == 0u) {
            return vec3<f32>(1.00, 0.82, 0.44);
        }
        if (role == 1u) {
            return vec3<f32>(0.12, 0.94, 0.74);
        }
        if (role == 2u) {
            return vec3<f32>(1.00, 0.38, 0.16);
        }
        return vec3<f32>(0.14, 0.52, 0.90);
    }
    if (p == 2u) {
        // Carina Rose & Periwinkle
        if (role == 0u) {
            return vec3<f32>(1.00, 0.66, 0.36);
        }
        if (role == 1u) {
            return vec3<f32>(0.50, 0.42, 1.00);
        }
        if (role == 2u) {
            return vec3<f32>(1.00, 0.20, 0.52);
        }
        return vec3<f32>(0.20, 0.80, 1.00);
    }
    // Veil Coral & Ice Cyan
    if (role == 0u) {
        return vec3<f32>(1.00, 0.52, 0.24);
    }
    if (role == 1u) {
        return vec3<f32>(0.26, 0.90, 1.00);
    }
    if (role == 2u) {
        return vec3<f32>(0.96, 0.36, 1.00);
    }
    return vec3<f32>(0.28, 0.38, 0.96);
}

fn system_camera_angles(pair_id: u32, gen: u32, t_epoch: f32) -> vec3<f32> {
    let fs = f32(pair_id);
    let fg = f32(gen);
    let h = hash22(vec2<f32>(fs * 17.7 + fg * 31.3, g.seed * 67.0 + 5.1));
    let yaw = 0.22 * sin(t_epoch * 0.045 + fs * 2.1 + h.y * TAU);
    let pitch = (0.42 + 0.34 * h.y) * select(-1.0, 1.0, (pair_id + gen) % 2u == 0u);
    let roll = h.x * TAU + t_epoch * (0.024 + 0.010 * f32(pair_id % 2u));
    return vec3<f32>(yaw, pitch, roll);
}

fn project_star(p3: vec3<f32>, pair_id: u32, gen: u32, t_epoch: f32) -> vec3<f32> {
    let cam = system_camera_angles(pair_id, gen, t_epoch);
    let pr = rotate_3d(p3, cam.x, cam.y, cam.z);
    let persp = 1.0 / (1.0 + clamp(pr.z, -0.70, 1.60) * 0.28);
    return vec3<f32>(pr.xy * persp, pr.z);
}

fn pair_center(pair_id: u32, n_pairs: u32, gen: u32, phase: f32, a: f32) -> vec2<f32> {
    let x_lo = 0.28;
    let x_hi = max(a - 0.28, 0.56);
    let y_lo = 0.24;
    let y_hi = 0.76;
    let fp = f32(pair_id);
    let fg = f32(gen);
    let h = hash22(vec2<f32>(fp * 23.1 + fg * 47.3, g.seed * 71.0 + 3.7));
    let seed_v = vec2<f32>(fp * 37.9 + fg * 19.3, g.seed * 89.0 + 5.1);
    let p1 = vec2<f32>(
        mix(x_lo, x_hi, fract((fp + 0.5) / f32(n_pairs) + (h.x - 0.5) * 0.22)),
        mix(y_lo, y_hi, h.y),
    );
    return iso_waypoint_pos(
        p1,
        h.x * TAU,
        seed_v,
        max(phase, 0.0),
        0.14,
        x_lo,
        x_hi,
        y_lo,
        y_hi,
        0.36,
        0.68,
        32u,
    );
}

fn eval_core_positions(
    arch: u32,
    pair_id: u32,
    gen: u32,
    phase: f32,
) -> array<vec3<f32>, 3> {
    let fs = f32(pair_id);
    let fg = f32(gen);
    let h0 = hash22(vec2<f32>(fs * 19.3 + fg * 43.1, g.seed * 79.0 + 2.3));
    let h1 = hash22(vec2<f32>(fs * 37.1 + fg * 11.7, g.seed * 53.0 + 8.9));
    let yaw = (h0.y - 0.5) * 0.45;
    let pitch = (h1.x - 0.5) * 0.55;
    let roll = h0.x * TAU;

    if (arch == 0u) {
        // Grand Tidal Collision: hyperbolic flyby peaking near phase = 13.0s.
        let m0 = 1.30;
        let m1 = 0.70;
        let u = (phase - 13.0) * 0.095;
        let r_h = sqrt(1.0 + u * u);
        let d_min = 0.27;
        let rel_local = vec3<f32>(d_min * (2.0 - r_h), d_min * 1.34 * u, 0.055 * sin(u * 1.2));
        let rel = rotate_3d(rel_local, yaw, pitch, roll);
        let inv_m = 1.0 / (m0 + m1);
        return array<vec3<f32>, 3>(-rel * (m1 * inv_m), rel * (m0 * inv_m), vec3<f32>(0.0));
    }

    if (arch == 1u) {
        // Binary Spiral Waltz: eccentric 3D Keplerian ellipse.
        let m0 = 1.25;
        let m1 = 0.62;
        let a_orb = 0.35;
        let ecc = 0.26;
        let ang = phase * 0.20 + h1.y * TAU;
        let r = a_orb * (1.0 - ecc * ecc) / (1.0 + ecc * cos(ang));
        let rel_local = vec3<f32>(r * cos(ang), r * sin(ang) * 0.86, r * sin(ang) * 0.22);
        let rel = rotate_3d(rel_local, yaw, pitch, roll);
        let inv_m = 1.0 / (m0 + m1);
        return array<vec3<f32>, 3>(-rel * (m1 * inv_m), rel * (m0 * inv_m), vec3<f32>(0.0));
    }

    if (arch == 2u) {
        // Grav Slingshot (after grav.c): heavy central sun with reflex motion + companion + outer shepherd.
        let ang = phase * 0.24 + h1.y * TAU;
        let c0 = vec3<f32>(-0.055 * cos(ang), -0.055 * sin(ang), 0.012 * sin(ang));
        let c1 = vec3<f32>(0.185 * cos(ang), 0.185 * sin(ang), 0.025 * sin(ang * 2.0));
        let c2 = vec3<f32>(-0.265 * cos(ang * 0.52 + 1.2), -0.235 * sin(ang * 0.52 + 1.2), 0.03 * cos(ang));
        return array<vec3<f32>, 3>(
            rotate_3d(c0, yaw * 0.4, pitch * 0.4, roll),
            rotate_3d(c1, yaw * 0.4, pitch * 0.4, roll),
            rotate_3d(c2, yaw * 0.4, pitch * 0.4, roll),
        );
    }

    // Cartwheel Plunge: compact intruder gliding obliquely past/through a grand face-angled disc.
    let m0 = 1.35;
    let m1 = 0.46;
    let u = (phase - 12.0) * 0.105;
    let rel_local = vec3<f32>(0.115, 0.27 * u, 0.16 * u);
    let rel = rotate_3d(rel_local, yaw, pitch, roll);
    let inv_m = 1.0 / (m0 + m1);
    return array<vec3<f32>, 3>(-rel * (m1 * inv_m), rel * (m0 * inv_m), vec3<f32>(0.0));
}

fn eval_cores(arch: u32, pair_id: u32, gen: u32, phase: f32) -> CoreSet {
    let fs = f32(pair_id);
    let fg = f32(gen);
    let h = hash22(vec2<f32>(fs * 23.9 + fg * 59.3, g.seed * 89.0 + 3.7));
    let h2 = hash22(vec2<f32>(fs * 41.3 + fg * 13.9, g.seed * 61.0 + 9.1));

    let eps = 0.02;
    let p_cur = eval_core_positions(arch, pair_id, gen, phase);
    let p_m = eval_core_positions(arch, pair_id, gen, phase - eps);
    let p_p = eval_core_positions(arch, pair_id, gen, phase + eps);
    let inv_2eps = 0.5 / eps;

    var cs: CoreSet;
    cs.count = select(2u, 3u, arch == 2u);

    let spin0 = select(-1.0, 1.0, h.x > 0.35);
    let spin1 = select(-1.0, 1.0, h.y > 0.5);
    let sec_pal = f32(1u + (pair_id % 2u));

    if (arch == 0u) {
        cs.c0 = Core(
            p_cur[0], (p_p[0] - p_m[0]) * inv_2eps,
            1.30, 0.084, 0.32,
            (h.x - 0.5) * 0.32, (h.y - 0.5) * 0.32, spin0, 2.0, 0.0,
        );
        cs.c1 = Core(
            p_cur[1], (p_p[1] - p_m[1]) * inv_2eps,
            0.70, 0.074, 0.22,
            (h2.x - 0.5) * 0.55, (h2.y - 0.5) * 0.55, spin1, 2.0, sec_pal,
        );
        cs.c2 = cs.c0;
    } else if (arch == 1u) {
        cs.c0 = Core(
            p_cur[0], (p_p[0] - p_m[0]) * inv_2eps,
            1.25, 0.084, 0.31,
            (h.x - 0.5) * 0.30, (h.y - 0.5) * 0.30, spin0, 3.0, 0.0,
        );
        cs.c1 = Core(
            p_cur[1], (p_p[1] - p_m[1]) * inv_2eps,
            0.62, 0.072, 0.20,
            (h2.x - 0.5) * 0.62, (h2.y - 0.5) * 0.62, -spin0, 2.0, sec_pal,
        );
        cs.c2 = cs.c0;
    } else if (arch == 2u) {
        cs.c0 = Core(
            p_cur[0], (p_p[0] - p_m[0]) * inv_2eps,
            1.55, 0.048, 0.22,
            0.0, 0.0, 1.0, 2.0, 0.0,
        );
        cs.c1 = Core(
            p_cur[1], (p_p[1] - p_m[1]) * inv_2eps,
            0.34, 0.042, 0.09,
            0.1, -0.1, 1.0, 2.0, sec_pal,
        );
        cs.c2 = Core(
            p_cur[2], (p_p[2] - p_m[2]) * inv_2eps,
            0.22, 0.042, 0.08,
            -0.1, 0.1, 1.0, 2.0, 2.0,
        );
    } else {
        cs.c0 = Core(
            p_cur[0], (p_p[0] - p_m[0]) * inv_2eps,
            1.35, 0.088, 0.33,
            (h.x - 0.5) * 0.25, (h.y - 0.5) * 0.25, spin0, 4.0, 0.0,
        );
        cs.c1 = Core(
            p_cur[1], (p_p[1] - p_m[1]) * inv_2eps,
            0.46, 0.084, 0.14,
            (h2.x - 0.5) * 0.52, (h2.y - 0.5) * 0.52, spin1, 2.0, sec_pal,
        );
        cs.c2 = cs.c0;
    }
    return cs;
}

fn core_at(cores: CoreSet, k: u32) -> Core {
    if (k == 0u) {
        return cores.c0;
    }
    if (k == 1u) {
        return cores.c1;
    }
    return cores.c2;
}

fn grav_accel(arch: u32, pos: vec3<f32>, cores: CoreSet) -> vec3<f32> {
    var acc = vec3<f32>(0.0);
    if (arch == 2u) {
        for (var k = 0u; k < cores.count; k = k + 1u) {
            let c = core_at(cores, k);
            let d = c.pos - pos;
            let r2 = dot(d, d) + c.soft * c.soft;
            acc = acc + d * (GRAV_G * c.mass / (r2 * sqrt(r2)));
        }
    } else {
        for (var k = 0u; k < cores.count; k = k + 1u) {
            let c = core_at(cores, k);
            let d = c.pos - pos;
            let r2 = dot(d, d) + c.soft * c.soft;
            acc = acc + d * (GAL_G * c.mass * pow(r2, -1.16));
        }
    }
    return acc;
}

fn spawn_star(
    arch: u32,
    pal_id: u32,
    cores: CoreSet,
    pair_id: u32,
    local_id: u32,
    gen: u32,
) -> Particle {
    let fl = f32(local_id);
    let fs = f32(pair_id);
    let fg = f32(gen);
    let s0 = vec2<f32>(fl * 1.13 + fs * 17.3, fg * 31.7 + g.seed * 73.0);
    let s1 = vec2<f32>(fl * 2.71 + fg * 19.1, fs * 43.9 + g.seed * 59.0);
    let r0 = hash22(s0);
    let r1 = hash22(s1);
    let r2 = hash22(s0 + vec2<f32>(11.7, 23.3));

    var local_p = vec3<f32>(0.0);
    var local_v = vec3<f32>(0.0);
    var col = star_palette(pal_id, 1u);
    var lum = 0.85;

    if (arch == 2u) {
        // Grav tracers: predominantly orbit the central sun cleanly with occasional companion trojans.
        let parent = core_at(cores, select(0u, 1u, r0.x > 0.82));
        let pal = (pal_id + u32(parent.pal_alt)) % 4u;
        let r_max = select(0.28, 0.085, r0.x > 0.82);
        let r = mix(0.068, r_max, pow(r0.y, 0.72));
        let ang = r1.x * TAU;
        let inc_x = parent.tilt_x + (r1.y - 0.5) * 0.24;
        let inc_y = parent.tilt_y + (r2.x - 0.5) * 0.24;
        let p_flat = vec3<f32>(cos(ang) * r, sin(ang) * r, (r2.y - 0.5) * 0.008);
        local_p = parent.pos + disc_to_world(p_flat, inc_x, inc_y);

        let v_circ = r * sqrt(GRAV_G * parent.mass / pow(r * r + parent.soft * parent.soft, 1.5));
        let ecc_f = mix(0.90, 1.09, r2.y);
        let dir = vec3<f32>(-sin(ang), cos(ang), 0.0) * parent.spin;
        local_v = parent.vel + disc_to_world(dir * (v_circ * ecc_f), inc_x, inc_y);

        let role = select(1u, select(2u, 0u, r0.y < 0.30), r2.x > 0.70);
        col = star_palette(pal, role);
        lum = mix(1.15, 2.40, r1.y * r1.y);

        var out: Particle;
        out.p = vec4<f32>(local_p, lum);
        out.v = vec4<f32>(local_v, max(length(local_v), 0.03));
        out.c = vec4<f32>(col, f32((gen % 16777215u) + 1u));
        return out;
    }

    // Assign star to parent galaxy proportional to core mass.
    var total_m = 0.0;
    for (var k = 0u; k < cores.count; k = k + 1u) {
        total_m = total_m + core_at(cores, k).mass;
    }
    var pick_m = r0.x * total_m;
    var parent_idx = 0u;
    for (var k = 0u; k < cores.count; k = k + 1u) {
        let mk = core_at(cores, k).mass;
        if (pick_m <= mk || k + 1u == cores.count) {
            parent_idx = k;
            break;
        }
        pick_m = pick_m - mk;
    }
    let parent = core_at(cores, parent_idx);
    let pal = (pal_id + u32(parent.pal_alt)) % 4u;

    // Spiral galaxy population: 16% Gaussian golden bulge, 70% Gaussian-feathered arms, 14% halo.
    let pop = r0.y;
    var r = 0.0;
    var theta = 0.0;
    var z_thick = 0.0;
    var ecc_f = 1.0;

    if (pop < 0.16) {
        let u = pop / 0.16;
        r = mix(0.008, 0.21 * parent.disc_r, pow(u, 1.25));
        theta = r1.x * TAU;
        z_thick = (r1.y - 0.5) * 0.022 * (1.0 - 0.5 * u);
        ecc_f = mix(0.92, 1.05, r2.x);
        col = mix(star_palette(pal, 0u), vec3<f32>(1.0, 0.90, 0.70), 0.32 * r2.y);
        lum = mix(0.65, 1.65, 1.0 - u * 0.75);
    } else if (pop < 0.86) {
        let u = (pop - 0.16) / 0.70;
        r = mix(0.11 * parent.disc_r, 1.04 * parent.disc_r, pow(u, 0.80));
        let arm = floor(r1.x * parent.arms);
        let wind = 1.78 * log(1.0 + r / 0.055) * parent.spin;
        let gauss = sqrt(-2.0 * log(max(r1.y, 0.001))) * cos(TAU * r2.x);
        let ridge = gauss * (0.092 + 0.105 * u);
        theta = arm * (TAU / max(parent.arms, 1.0)) + wind + ridge;
        z_thick = (r2.y - 0.5) * 0.009;
        ecc_f = mix(0.96, 1.04, r2.x);

        let is_hii = r2.y > 0.86;
        let is_beacon = r1.y > 0.88;
        col = select(star_palette(pal, 1u), star_palette(pal, 2u), is_hii);
        let dust = mix(0.28, 0.95, pow(r1.x, 2.0));
        let base_lum = select(dust, 2.25, is_beacon || is_hii);
        lum = select(base_lum, -base_lum, (local_id % 13u) == 0u && (is_beacon || is_hii));
    } else {
        let u = (pop - 0.86) / 0.14;
        r = mix(0.55 * parent.disc_r, 1.15 * parent.disc_r, sqrt(u));
        theta = r1.x * TAU;
        z_thick = (r1.y - 0.5) * 0.014;
        ecc_f = mix(0.93, 1.05, r2.x);
        col = mix(star_palette(pal, 1u), star_palette(pal, 3u), 0.45 + 0.45 * u);
        lum = mix(0.26, 0.70, 1.0 - u * 0.6);
    }

    let p_flat = vec3<f32>(cos(theta) * r, sin(theta) * r, z_thick);
    local_p = disc_to_world(p_flat, parent.tilt_x, parent.tilt_y);

    let v_circ = r * sqrt(GAL_G * parent.mass * pow(r * r + parent.soft * parent.soft, -1.16));
    let v_flat = vec3<f32>(-sin(theta), cos(theta), 0.0) * (parent.spin * v_circ * ecc_f);
    let disp = (vec3<f32>(r2.x, r2.y, r1.y) - 0.5) * 0.007;
    local_v = disc_to_world(v_flat, parent.tilt_x, parent.tilt_y) + disp;

    var out: Particle;
    out.p = vec4<f32>(parent.pos + local_p, lum);
    out.v = vec4<f32>(parent.vel + local_v, max(length(local_v), 0.03));
    out.c = vec4<f32>(col, f32((gen % 16777215u) + 1u));
    return out;
}

fn splat_star_step(
    cm_prev: vec2<f32>,
    cm_cur: vec2<f32>,
    p_prev3: vec3<f32>,
    p_cur3: vec3<f32>,
    col: vec3<f32>,
    lum_raw: f32,
    speed: f32,
    v_base: f32,
    env: f32,
    pair_id: u32,
    gen: u32,
    t_epoch: f32,
    a: f32,
    n_sub: i32,
    norm_count: f32,
    dt_rgb: f32,
    dt_core: f32,
    is_grav: bool,
    draw_head: bool,
) {
    let is_beacon = lum_raw < 0.0;
    let lum = abs(lum_raw);
    let pr0 = project_star(p_prev3, pair_id, gen, t_epoch);
    let pr1 = project_star(p_cur3, pair_id, gen, t_epoch);
    let wp0 = cm_prev + pr0.xy;
    let wp1 = cm_cur + pr1.xy;
    if (wp1.x < 0.0 || wp1.x > a || wp1.y < 0.0 || wp1.y > 1.0) {
        return;
    }
    let edge = bezel_fade(wp1, a);
    if (edge <= 0.002) {
        return;
    }

    let r_fade = 1.0 - smoothstep(0.65, 1.20, length(p_cur3));
    let depth_fade = clamp(0.84 - pr1.z * 0.24, 0.40, 1.15);
    let boost = clamp(speed / max(v_base, 0.03), 0.80, 1.85);
    let eff_lum = lum * r_fade * depth_fade * boost * env * norm_count * edge;
    if (eff_lum <= 0.005) {
        return;
    }

    let h = f32(splat_dims().y);

    if (is_grav) {
        let px_len = length((wp1 - wp0) * h);
        let seg_rgb = max(px_len, dt_rgb / f32(n_sub)) * (W_TRAIL * h) * eff_lum;
        let seg_core = max(px_len, dt_core / f32(n_sub)) * (W_TRAIL * h) * eff_lum;
        let delta_world = length(wp1 - wp0);
        if (delta_world > 1e-5 && delta_world <= 0.25) {
            splat_segment(wp0, wp1, col * seg_rgb, seg_core * 0.16, false);
        } else {
            splat_point(wp1, col * seg_rgb, seg_core * 0.16);
        }
        if (draw_head) {
            let head_rgb = (W_STAR * h) * (W_STAR * h) * dt_rgb * 22.0 * eff_lum;
            let head_core = (W_STAR * h) * (W_STAR * h) * dt_core * 22.0 * eff_lum;
            splat_point(wp1, col * (head_rgb * 0.65), head_core * 1.45);
        }
        return;
    }

    let inv_sub = 1.0 / f32(n_sub);
    let star_area = (W_STAR * h) * (W_STAR * h) * inv_sub * 12.4 * eff_lum;
    let rgb_e = star_area * dt_rgb;
    let core_e = star_area * dt_core;
    if (is_beacon && draw_head) {
        splat_disc(wp1, 0.0026, col * (rgb_e * 1.25), core_e * 1.15, false);
    } else {
        splat_point(wp1, col * (rgb_e * 0.90), core_e * 0.72);
    }
}

fn step_particle(idx: u32, t: f32) {
    let a = aspect();
    let is_narrow = a < 2.4;
    let total = particle_count();
    let n_active = select(total, min(6144u, total), is_narrow);
    if (idx >= n_active) {
        return;
    }

    let n_pairs = select(2u, 1u, is_narrow);
    let pair_id = idx % n_pairs;
    let local_id = idx / n_pairs;
    let local_count = max(n_active / n_pairs, 1u);
    let norm_count = 4096.0 / f32(local_count);

    let gen = u32(max(floor(t / EPOCH_SECS), 0.0));
    let phase = t - f32(gen) * EPOCH_SECS;
    let u_epoch = phase / EPOCH_SECS;
    let env = smoothstep(0.0, 0.075, u_epoch) * (1.0 - smoothstep(0.91, 1.0, u_epoch));

    let arch = (gen + u32(g.seed * 17.0)) % 4u;
    let pal_id = (gen * 3u + u32(g.seed * 23.0)) % 4u;
    let is_grav = arch == 2u;

    let rgb_fade = select(exp(-g.dt / 0.055), g.fade, is_grav);
    let core_fade = exp(-g.dt * 14.0);
    let dt_rgb = max(1.0 - rgb_fade, 0.01);
    let dt_core = max(1.0 - core_fade, 0.01);

    let cm_cur = pair_center(pair_id, n_pairs, gen, phase, a);
    let cores = eval_cores(arch, pair_id, gen, phase);

    // Reserve first `cores.count` slots per pair as luminous galactic nuclei / Grav suns.
    if (local_id < cores.count) {
        let c = core_at(cores, local_id);
        let pr = project_star(c.pos, pair_id, gen, phase);
        let wp = cm_cur + pr.xy;
        if (wp.x >= 0.0 && wp.x <= a && wp.y >= 0.0 && wp.y <= 1.0) {
            let edge = bezel_fade(wp, a);
            if (edge > 0.002) {
                let core_col = star_palette((pal_id + u32(c.pal_alt)) % 4u, 0u);
                let rad = select(0.006, select(0.012, 0.008, local_id > 0u), is_grav);
                let base_strength = select(0.75, 4.20, is_grav) * env * norm_count * edge;
                let h = f32(splat_dims().y);
                let disc_area = (rad * h) * (rad * h) * base_strength;
                splat_disc(wp, rad, core_col * (disc_area * dt_rgb), disc_area * dt_core * 1.8, false);
            }
        }
        particles[idx].c.w = f32((gen % 16777215u) + 1u);
        return;
    }

    if (is_grav && local_id >= GRAV_TRACERS_PER_PAIR) {
        particles[idx].c.w = f32((gen % 16777215u) + 1u);
        return;
    }

    let eff_norm = select(norm_count, norm_count * 2.1, is_grav);

    var st = particles[idx];
    let packed = u32(round(max(st.c.w, 0.0)));
    let prev_gen = select(0u, packed - 1u, packed >= 1u);
    let uninit = g.frame < 0.5 || packed == 0u || prev_gen != gen || !all(st.p.xyz == st.p.xyz);

    if (uninit) {
        let prewarm = select(0.0, min(phase, 5.0), g.frame < 0.5 && phase > 0.25);
        let t_start = max(phase - prewarm, 0.0);
        let seed_cores = eval_cores(arch, pair_id, gen, t_start);
        var spawned = spawn_star(arch, pal_id, seed_cores, pair_id, local_id, gen);
        var pos = spawned.p.xyz;
        var vel = spawned.v.xyz;

        if (prewarm > 0.05) {
            let n_warm = 12;
            let w_dt = prewarm / f32(n_warm);
            for (var s = 0; s < n_warm; s = s + 1) {
                let t_mid = t_start + (f32(s) + 0.5) * w_dt;
                let w_cores = eval_cores(arch, pair_id, gen, t_mid);
                let a0 = grav_accel(arch, pos, w_cores);
                vel = vel + 0.5 * a0 * w_dt;
                pos = pos + vel * w_dt;
                let a1 = grav_accel(arch, pos, w_cores);
                vel = vel + 0.5 * a1 * w_dt;
                let spd = length(vel);
                if (spd > 0.65) {
                    vel = vel * (0.65 / spd);
                }
            }
        }

        splat_star_step(
            cm_cur,
            cm_cur,
            pos,
            pos,
            spawned.c.rgb,
            spawned.p.w,
            length(vel),
            spawned.v.w,
            env,
            pair_id,
            gen,
            phase,
            a,
            1,
            eff_norm,
            dt_rgb,
            dt_core,
            is_grav,
            true,
        );
        particles[idx].p = vec4<f32>(pos, spawned.p.w);
        particles[idx].v = vec4<f32>(vel, spawned.v.w);
        particles[idx].c = spawned.c;
        return;
    }

    var pos = st.p.xyz;
    var vel = st.v.xyz;
    let lum = st.p.w;
    let v_base = st.v.w;
    let col = st.c.rgb;

    let n_sub = clamp(i32(ceil(g.dt / 0.045)), 1, 6);
    let h_dt = g.dt / f32(n_sub);

    for (var s = 0; s < n_sub; s = s + 1) {
        let p_prev = pos;
        let t_sub0 = max(phase - g.dt + f32(s) * h_dt, 0.0);
        let t_sub1 = clamp(phase - g.dt + f32(s + 1) * h_dt, 0.0, EPOCH_SECS);
        let t_mid = 0.5 * (t_sub0 + t_sub1);
        let sub_cores = eval_cores(arch, pair_id, gen, t_mid);

        let a0 = grav_accel(arch, pos, sub_cores);
        vel = vel + 0.5 * a0 * h_dt;
        pos = pos + vel * h_dt;
        let a1 = grav_accel(arch, pos, sub_cores);
        vel = vel + 0.5 * a1 * h_dt;

        let spd = length(vel);
        if (spd > 0.65) {
            vel = vel * (0.65 / spd);
        }
        let rad = length(pos);
        if (rad > 1.25) {
            pos = pos * (1.25 / rad);
            vel = vel * 0.65;
        }

        let cm_sub0 = select(cm_cur, pair_center(pair_id, n_pairs, gen, t_sub0, a), is_grav);
        let cm_sub1 = select(cm_cur, pair_center(pair_id, n_pairs, gen, t_sub1, a), is_grav);

        splat_star_step(
            cm_sub0,
            cm_sub1,
            p_prev,
            pos,
            col,
            lum,
            spd,
            v_base,
            env,
            pair_id,
            gen,
            phase,
            a,
            n_sub,
            eff_norm,
            dt_rgb,
            dt_core,
            is_grav,
            s + 1 == n_sub,
        );
    }

    particles[idx].p = vec4<f32>(pos, lum);
    particles[idx].v = vec4<f32>(vel, v_base);
}

fn resolve_state(uv: vec2<f32>, _p: vec2<f32>, t: f32, splat: vec4<f32>) -> vec4<f32> {
    let gen = u32(max(floor(t / EPOCH_SECS), 0.0));
    let arch = (gen + u32(g.seed * 17.0)) % 4u;
    let prev = state_sample(uv);
    let rgb_fade = select(exp(-g.dt / 0.055), g.fade, arch == 2u);
    let core_fade = exp(-g.dt * 14.0);
    return vec4<f32>(prev.rgb * rgb_fade, prev.a * core_fade) + splat;
}

fn hack(p: vec2<f32>, _t: f32) -> vec3<f32> {
    let uv = state_uv(p);
    let s = state_sample(uv);
    let d = state_texel();

    // Tight 8-tap optical star bloom.
    let h_card = state_sample(uv + vec2<f32>(d.x * 1.3, 0.0))
        + state_sample(uv - vec2<f32>(d.x * 1.3, 0.0))
        + state_sample(uv + vec2<f32>(0.0, d.y * 1.3))
        + state_sample(uv - vec2<f32>(0.0, d.y * 1.3));
    let h_diag = state_sample(uv + vec2<f32>(d.x * 2.1, d.y * 2.1))
        + state_sample(uv + vec2<f32>(-d.x * 2.1, d.y * 2.1))
        + state_sample(uv + vec2<f32>(d.x * 2.1, -d.y * 2.1))
        + state_sample(uv + vec2<f32>(-d.x * 2.1, -d.y * 2.1));
    let halo = (h_card + h_diag) * 0.125;

    // Subtle soft nebula veil along dense spiral arms and core bulges.
    let neb = (
        state_sample(uv + vec2<f32>(d.x * 3.8, d.y * 3.8))
        + state_sample(uv + vec2<f32>(-d.x * 3.8, d.y * 3.8))
        + state_sample(uv + vec2<f32>(d.x * 3.8, -d.y * 3.8))
        + state_sample(uv + vec2<f32>(-d.x * 3.8, -d.y * 3.8))
    ) * 0.25;

    let raw_rgb = max(s.rgb + halo.rgb * 0.26 + neb.rgb * 0.11, vec3<f32>(0.0));
    let peak_c = max(raw_rgb.r, max(raw_rgb.g, raw_rgb.b));
    if (peak_c <= 1e-4 && s.a <= 1e-4) {
        return vec3<f32>(0.0);
    }

    let mapped_lum = 1.0 - exp(-peak_c * 1.48);
    var out_col = raw_rgb * (mapped_lum / max(peak_c, 1e-4));
    let hot = clamp(s.a * 0.55 + halo.a * 0.10, 0.0, 1.5);
    let incand = smoothstep(0.42, 1.30, hot) * 0.52 * smoothstep(0.03, 0.32, mapped_lum);
    out_col = mix(out_col, vec3<f32>(1.0, 0.97, 0.92), incand);
    return clamp(out_col, vec3<f32>(0.0), vec3<f32>(1.0));
}

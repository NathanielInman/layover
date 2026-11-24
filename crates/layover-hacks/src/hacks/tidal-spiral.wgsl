// Tidal Spiral: colliding 3D spiral galaxies pulling luminous tidal bridges,
// warped discs and orbital gravitational slingshot streams across the dark
// on Tier P compute particles and advected Tier S feedback textures.
// After xscreensaver's Galaxy (Uli Siegmund, Harald Backert, Hubert Feyrer,
// Jamie Zawinski) and Grav (Greg Bowering).
//
// Particle buffer layout (`particles[idx]`):
//   p.xyz = 3D position relative to its system's center of mass (canvas heights)
//   p.w   = intrinsic star luminosity multiplier (negative flag encodes supergiant/H-II glow)
//   v.xyz = 3D velocity relative to its system's center of mass (canvas heights/sec)
//   v.w   = baseline orbital speed (for pericenter / slingshot brightening)
//   c.rgb = spectral base RGB color
//   c.w   = packed integer `(gen % 16777215u) + 1u` stored exact in f32 (0 = uninit)

const DRIFT_VX: f32 = 0.112;
const EPOCH_SECS: f32 = 36.0;
const GAL_G: f32 = 0.0025;
const GRAV_G: f32 = 0.00145;
const W_TRAIL: f32 = 0.00072;
const W_STAR: f32 = 0.0027;
const GRAV_TRACERS: u32 = 140u;

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

fn system_camera_angles(sys_id: u32, gen: u32, t_epoch: f32) -> vec3<f32> {
    let fs = f32(sys_id);
    let fg = f32(gen);
    let h = hash22(vec2<f32>(fs * 17.7 + fg * 31.3, g.seed * 67.0 + 5.1));
    let yaw = 0.22 * sin(t_epoch * 0.045 + fs * 2.1 + h.y * TAU);
    let pitch = (0.42 + 0.34 * h.y) * select(-1.0, 1.0, (sys_id + gen) % 2u == 0u);
    let roll = h.x * TAU + t_epoch * (0.024 + 0.010 * f32(sys_id % 2u));
    return vec3<f32>(yaw, pitch, roll);
}

fn project_star(p3: vec3<f32>, sys_id: u32, gen: u32, t_epoch: f32) -> vec3<f32> {
    let cam = system_camera_angles(sys_id, gen, t_epoch);
    let pr = rotate_3d(p3, cam.x, cam.y, cam.z);
    let persp = 1.0 / (1.0 + clamp(pr.z, -0.70, 1.60) * 0.28);
    return vec3<f32>(pr.xy * persp, pr.z);
}

fn eval_core_positions(
    arch: u32,
    sys_id: u32,
    gen: u32,
    phase: f32,
) -> array<vec3<f32>, 3> {
    let fs = f32(sys_id);
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
        // Grav Slingshot (after grav.c): heavy central sun + orbiting companion + outer binary shepherd.
        let ang = phase * 0.24 + h1.y * TAU;
        let c0 = vec3<f32>(-0.022 * cos(ang), -0.022 * sin(ang), 0.0);
        let c1 = vec3<f32>(0.175 * cos(ang), 0.175 * sin(ang), 0.025 * sin(ang * 2.0));
        let c2 = vec3<f32>(-0.255 * cos(ang * 0.52 + 1.2), -0.225 * sin(ang * 0.52 + 1.2), 0.03 * cos(ang));
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

fn eval_cores(arch: u32, sys_id: u32, gen: u32, phase: f32) -> CoreSet {
    let fs = f32(sys_id);
    let fg = f32(gen);
    let h = hash22(vec2<f32>(fs * 23.9 + fg * 59.3, g.seed * 89.0 + 3.7));
    let h2 = hash22(vec2<f32>(fs * 41.3 + fg * 13.9, g.seed * 61.0 + 9.1));

    let eps = 0.02;
    let p_cur = eval_core_positions(arch, sys_id, gen, phase);
    let p_m = eval_core_positions(arch, sys_id, gen, phase - eps);
    let p_p = eval_core_positions(arch, sys_id, gen, phase + eps);
    let inv_2eps = 0.5 / eps;

    var cs: CoreSet;
    cs.count = select(2u, 3u, arch == 2u);

    let spin0 = select(-1.0, 1.0, h.x > 0.35);
    let spin1 = select(-1.0, 1.0, h.y > 0.5);

    if (arch == 0u) {
        cs.c0 = Core(
            p_cur[0], (p_p[0] - p_m[0]) * inv_2eps,
            1.30, 0.084, 0.32,
            (h.x - 0.5) * 0.32, (h.y - 0.5) * 0.32, spin0, 2.0, 0.0,
        );
        cs.c1 = Core(
            p_cur[1], (p_p[1] - p_m[1]) * inv_2eps,
            0.70, 0.074, 0.22,
            (h2.x - 0.5) * 0.55, (h2.y - 0.5) * 0.55, spin1, 2.0, 1.0,
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
            (h2.x - 0.5) * 0.62, (h2.y - 0.5) * 0.62, -spin0, 2.0, 1.0,
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
            0.1, -0.1, 1.0, 2.0, 1.0,
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
            (h2.x - 0.5) * 0.52, (h2.y - 0.5) * 0.52, spin1, 2.0, 1.0,
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

fn system_center(sys_id: u32, n_sys: u32, gen: u32, t: f32) -> vec2<f32> {
    let a = aspect();
    let fs = f32(sys_id);
    let fg = f32(gen);
    let jx = (hash11(fs * 17.3 + fg * 29.7 + g.seed * 53.0) - 0.5) * 0.34;
    let x0 = fract((fs + 0.5 + jx) / f32(n_sys) + g.seed * 0.37) * a;
    let y0 = 0.22 + 0.56 * fract(0.17 + fs * 0.37 + fg * 0.618034 + g.seed * 0.53);
    return vec2<f32>(fract((x0 + DRIFT_VX * t) / a) * a, y0);
}

fn spawn_star(
    arch: u32,
    pal_id: u32,
    cores: CoreSet,
    sys_id: u32,
    local_id: u32,
    gen: u32,
) -> Particle {
    let fl = f32(local_id);
    let fs = f32(sys_id);
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
    sys_cm: vec2<f32>,
    p_prev3: vec3<f32>,
    p_cur3: vec3<f32>,
    col: vec3<f32>,
    lum_raw: f32,
    speed: f32,
    v_base: f32,
    env: f32,
    sys_id: u32,
    gen: u32,
    t_epoch: f32,
    n_sub: i32,
    norm_count: f32,
    is_grav: bool,
    draw_head: bool,
) {
    let is_beacon = lum_raw < 0.0;
    let lum = abs(lum_raw);
    let pr0 = project_star(p_prev3, sys_id, gen, t_epoch);
    let pr1 = project_star(p_cur3, sys_id, gen, t_epoch);
    let q0 = pr0.xy;
    let q1 = pr1.xy;
    let wy = sys_cm.y + q1.y;
    let y_clip = smoothstep(0.02, 0.07, wy) * (1.0 - smoothstep(0.93, 0.98, wy));
    let r_fade = 1.0 - smoothstep(0.45, 0.76, length(p_cur3));
    let depth_fade = clamp(0.84 - pr1.z * 0.24, 0.40, 1.15);
    let boost = clamp(speed / max(v_base, 0.03), 0.80, 1.85);
    let eff_lum = lum * r_fade * depth_fade * boost * env * norm_count * y_clip;
    if (eff_lum <= 0.005) {
        return;
    }

    let h = f32(splat_dims().y);
    let dt_fade = max(1.0 - g.fade, 0.01);

    if (is_grav) {
        let px_len = length((q1 - q0) * h);
        let seg_e = max(px_len, dt_fade / f32(n_sub)) * (W_TRAIL * h) * eff_lum;
        let delta_world = length(q1 - q0);
        if (delta_world > 1e-5 && delta_world <= 0.25) {
            splat_segment(sys_cm + q0, sys_cm + q1, col * seg_e, seg_e * 0.16, true);
        } else {
            splat_point_wrap(sys_cm + q1, col * seg_e, seg_e * 0.16);
        }
        if (draw_head) {
            let head_e = (W_STAR * h) * (W_STAR * h) * dt_fade * 22.0 * eff_lum;
            splat_point_wrap(sys_cm + q1, col * (head_e * 0.65), head_e * 1.45);
        }
        return;
    }

    let pt_e = (W_STAR * h) * (W_STAR * h) * (dt_fade / f32(n_sub)) * 12.4 * eff_lum;
    if (is_beacon && draw_head) {
        splat_disc(sys_cm + q1, 0.0026, col * (pt_e * 1.25), pt_e * 1.15, true);
    } else {
        splat_point_wrap(sys_cm + q1, col * (pt_e * 0.90), pt_e * 0.72);
    }
}

fn step_particle(idx: u32, t: f32) {
    let a = aspect();
    let n_sys = select(3u, 2u, a < 2.4);
    let sys_id = idx % n_sys;
    let local_id = idx / n_sys;
    let local_count = max(particle_count() / n_sys, 1u);
    let norm_count = 4096.0 / f32(local_count);

    let fs = f32(sys_id);
    let sys_off = (fs / f32(n_sys) + 0.11 * hash11(fs * 19.3 + g.seed * 41.0)) * EPOCH_SECS;
    let cycle_t = t + sys_off;
    let gen = u32(max(floor(cycle_t / EPOCH_SECS), 0.0));
    let phase = cycle_t - f32(gen) * EPOCH_SECS;
    let u_epoch = phase / EPOCH_SECS;
    let env = smoothstep(0.0, 0.075, u_epoch) * (1.0 - smoothstep(0.91, 1.0, u_epoch));

    let arch = (gen + sys_id * 3u + u32(g.seed * 17.0)) % 4u;
    let pal_id = (gen * 3u + sys_id * 2u + u32(g.seed * 23.0)) % 4u;
    let sys_cm = system_center(sys_id, n_sys, gen, t);
    let cores = eval_cores(arch, sys_id, gen, phase);

    // Reserve first `cores.count` slots per system as luminous galactic nuclei / Grav suns.
    if (local_id < cores.count) {
        let c = core_at(cores, local_id);
        let pr = project_star(c.pos, sys_id, gen, phase);
        let wy = sys_cm.y + pr.y;
        let y_clip = smoothstep(0.02, 0.07, wy) * (1.0 - smoothstep(0.93, 0.98, wy));
        let core_col = star_palette((pal_id + u32(c.pal_alt)) % 4u, 0u);
        let rad = select(0.006, select(0.011, 0.0075, local_id > 0u), arch == 2u);
        let dt_fade = max(1.0 - g.fade, 0.01);
        let strength = select(0.75, 3.60, arch == 2u) * env * norm_count * dt_fade * y_clip;
        let h = f32(splat_dims().y);
        let disc_e = (rad * h) * (rad * h) * strength;
        splat_disc(sys_cm + pr.xy, rad, core_col * disc_e, disc_e * 1.8, true);
        particles[idx].c.w = f32((gen % 16777215u) + 1u);
        return;
    }

    if (arch == 2u && local_id >= GRAV_TRACERS) {
        particles[idx].c.w = f32((gen % 16777215u) + 1u);
        return;
    }

    let is_grav = arch == 2u;
    let eff_norm = select(norm_count, norm_count * 2.1, is_grav);

    var st = particles[idx];
    let packed = u32(round(max(st.c.w, 0.0)));
    let prev_gen = select(0u, packed - 1u, packed >= 1u);
    let uninit = g.frame < 0.5 || packed == 0u || prev_gen != gen || !all(st.p.xyz == st.p.xyz);

    if (uninit) {
        let prewarm = select(0.0, min(phase, 5.0), g.frame < 0.5 && phase > 0.25);
        let t_start = max(phase - prewarm, 0.0);
        let seed_cores = eval_cores(arch, sys_id, gen, t_start);
        var spawned = spawn_star(arch, pal_id, seed_cores, sys_id, local_id, gen);
        var pos = spawned.p.xyz;
        var vel = spawned.v.xyz;

        if (prewarm > 0.05) {
            let n_warm = 12;
            let w_dt = prewarm / f32(n_warm);
            for (var s = 0; s < n_warm; s = s + 1) {
                let t_mid = t_start + (f32(s) + 0.5) * w_dt;
                let w_cores = eval_cores(arch, sys_id, gen, t_mid);
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
            sys_cm,
            pos,
            pos,
            spawned.c.rgb,
            spawned.p.w,
            length(vel),
            spawned.v.w,
            env,
            sys_id,
            gen,
            phase,
            1,
            eff_norm,
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
        let t_mid = max(phase - g.dt + (f32(s) + 0.5) * h_dt, 0.0);
        let sub_cores = eval_cores(arch, sys_id, gen, t_mid);

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
        if (rad > 0.76) {
            pos = pos * (0.76 / rad);
            vel = vel * 0.65;
        }

        splat_star_step(
            sys_cm,
            p_prev,
            pos,
            col,
            lum,
            spd,
            v_base,
            env,
            sys_id,
            gen,
            phase,
            n_sub,
            eff_norm,
            is_grav,
            s + 1 == n_sub,
        );
    }

    particles[idx].p = vec4<f32>(pos, lum);
    particles[idx].v = vec4<f32>(vel, v_base);
}

fn resolve_state(uv: vec2<f32>, _p: vec2<f32>, _t: f32, splat: vec4<f32>) -> vec4<f32> {
    let duv = vec2<f32>(DRIFT_VX * g.dt / aspect(), 0.0);
    let prev = state_sample(uv - duv);
    let core_fade = exp(-g.dt * 14.0);
    return vec4<f32>(prev.rgb * g.fade, prev.a * core_fade) + splat;
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

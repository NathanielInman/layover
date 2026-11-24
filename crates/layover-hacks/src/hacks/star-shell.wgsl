// Star Shell: 3D ballistic fireworks climbing and blooming across the dark
// into chrysanthemum spheres, weeping willows, double-shell pistils, tilted
// Saturn rings, crossette multi-break strobes and spiral palm fronds.
// After xscreensaver's Fireworkx (Rony B. Chandran, 2004) and Pyro (Jamie Zawinski, 1992).
//
// Particle buffer layout (`particles[idx]`, 256 particles per shell slot):
//   p.xyz = local 3D displacement (lx, ly, lz) from burst center (or 2D canvas pos in rocket stage)
//   p.w   = particle age in seconds within the current stage
//   v.xyz = 3D velocity (vx, vy, vz) in canvas heights/sec
//   v.w   = particle lifetime in seconds
//   c.rgb = metal-salt base RGB color
//   c.w   = packed integer `((gen % 65535u) + 1u) * 4u + stage` stored exact in f32
//           (0 = uninitialized; stage 0 = dormant, 1 = rocket, 2 = burst, 3 = crossette break)

const PARTICLES_PER_SHELL: u32 = 256u;
const WIND_VX: f32 = 0.018;
const W_TRAIL: f32 = 0.0022;
const CROSSETTE_SPLIT_AGE: f32 = 0.72;

struct StarSpec {
    v0: vec3<f32>,
    life: f32,
    col: vec3<f32>,
    drag: f32,
    grav: f32,
};

fn fibonacci_dir(i: u32, n: u32, jitter_seed: vec2<f32>) -> vec3<f32> {
    let fi = f32(i) + 0.5;
    let fn_total = f32(n);
    let y = 1.0 - 2.0 * fi / fn_total;
    let r = sqrt(max(1.0 - y * y, 0.0));
    let phi = fi * 2.39996323;
    let base = vec3<f32>(cos(phi) * r, y, sin(phi) * r);
    let j = hash22(jitter_seed + vec2<f32>(fi * 1.37, fi * 2.91)) - 0.5;
    let perturbed = base + vec3<f32>(j.x, j.y, (j.x - j.y) * 0.7) * 0.14;
    return normalize(perturbed);
}

fn sphere_vec_from_hash(s: vec2<f32>) -> vec3<f32> {
    let h = hash22(s);
    let u = h.x * 2.0 - 1.0;
    let phi = h.y * TAU;
    let r = sqrt(max(1.0 - u * u, 0.0));
    return vec3<f32>(r * cos(phi), u, r * sin(phi));
}

fn rotate_3d(v: vec3<f32>, yaw: f32, pitch: f32, roll: f32) -> vec3<f32> {
    let xz = rot2(yaw) * v.xz;
    let v1 = vec3<f32>(xz.x, v.y, xz.y);
    let yz = rot2(pitch) * v1.yz;
    let v2 = vec3<f32>(v1.x, yz.x, yz.y);
    let xy = rot2(roll) * v2.xy;
    return vec3<f32>(xy.x, xy.y, v2.z);
}

fn shell_palette(pal: u32, secondary: bool) -> vec3<f32> {
    let p = pal % 8u;
    if (p == 0u) {
        return select(vec3<f32>(1.00, 0.14, 0.20), vec3<f32>(1.00, 0.84, 0.40), secondary);
    }
    if (p == 1u) {
        return select(vec3<f32>(0.16, 0.48, 1.00), vec3<f32>(0.34, 0.96, 1.00), secondary);
    }
    if (p == 2u) {
        return select(vec3<f32>(1.00, 0.72, 0.16), vec3<f32>(1.00, 0.90, 0.58), secondary);
    }
    if (p == 3u) {
        return select(vec3<f32>(0.12, 0.94, 0.46), vec3<f32>(0.76, 1.00, 0.34), secondary);
    }
    if (p == 4u) {
        return select(vec3<f32>(0.68, 0.26, 1.00), vec3<f32>(1.00, 0.34, 0.72), secondary);
    }
    if (p == 5u) {
        return select(vec3<f32>(1.00, 0.36, 0.12), vec3<f32>(0.14, 0.92, 0.84), secondary);
    }
    if (p == 6u) {
        return select(vec3<f32>(0.70, 0.84, 1.00), vec3<f32>(0.22, 0.56, 1.00), secondary);
    }
    return select(vec3<f32>(0.98, 0.24, 0.76), vec3<f32>(1.00, 0.80, 0.22), secondary);
}

fn project_3d(burst: vec2<f32>, l: vec3<f32>) -> vec2<f32> {
    return burst + l.xy / (1.0 + max(l.z, -0.55) * 0.42);
}

fn rocket_pos(launch: vec2<f32>, burst: vec2<f32>, u: f32, wiggle_seed: f32) -> vec2<f32> {
    let s = 1.0 - (1.0 - u) * (1.0 - u);
    let mid_x = mix(launch.x, burst.x, u);
    let mid_y = mix(launch.y, burst.y, s);
    let wiggle = 0.006 * sin(u * PI) * sin(u * 14.0 + wiggle_seed);
    return vec2<f32>(mid_x + wiggle, mid_y);
}

// Analytical ballistic step under linear air drag, gravity and night breeze.
fn integrate_ballistic(
    pos: vec3<f32>,
    vel: vec3<f32>,
    drag: f32,
    grav: f32,
    dt: f32,
) -> array<vec3<f32>, 2> {
    let e = exp(-drag * dt);
    let k_inv = 1.0 / max(drag, 0.05);
    let v_term = vec3<f32>(WIND_VX * 0.5, -grav, 0.0) * k_inv;
    let new_pos = pos + v_term * dt + (vel - v_term) * ((1.0 - e) * k_inv);
    let new_vel = v_term + (vel - v_term) * e;
    return array<vec3<f32>, 2>(new_pos, new_vel);
}

fn star_params(
    arch: u32,
    pal: u32,
    shell_id: u32,
    local_id: u32,
    gen: u32,
    depth_scale: f32,
) -> StarSpec {
    let fs = f32(shell_id);
    let fg = f32(gen);
    let fl = f32(local_id);
    let jseed = vec2<f32>(fs * 17.3 + fg * 31.1, g.seed * 97.0 + fl * 0.37);
    let r = hash22(jseed);

    var spec: StarSpec;
    spec.v0 = vec3<f32>(0.0);
    spec.drag = 1.50;
    spec.grav = 0.22;
    spec.life = 2.1;
    spec.col = shell_palette(pal, false);

    if (arch == 0u) {
        // Classic Chrysanthemum: brisk symmetric 3D sphere of luminous spark arcs.
        let dir = fibonacci_dir(local_id, PARTICLES_PER_SHELL, jseed);
        let spd = mix(0.45, 0.58, r.x) * depth_scale;
        spec.v0 = dir * spd;
        spec.drag = 1.50;
        spec.grav = 0.21;
        spec.life = mix(1.90, 2.50, r.y);
    } else if (arch == 1u) {
        // Pistil Double-Shell Peony: outer crown + contrasting inner core sphere.
        if (local_id < 168u) {
            let dir = fibonacci_dir(local_id, 168u, jseed);
            let spd = mix(0.48, 0.60, r.x) * depth_scale;
            spec.v0 = dir * spd;
            spec.drag = 1.46;
            spec.grav = 0.22;
            spec.life = mix(2.00, 2.55, r.y);
            spec.col = shell_palette(pal, false);
        } else {
            let dir = fibonacci_dir(local_id - 168u, 88u, jseed + vec2<f32>(4.1, 7.3));
            let spd = mix(0.24, 0.32, r.x) * depth_scale;
            spec.v0 = dir * spd;
            spec.drag = 1.62;
            spec.grav = 0.19;
            spec.life = mix(1.65, 2.15, r.y);
            spec.col = shell_palette(pal, true);
        }
    } else if (arch == 2u) {
        // Weeping Willow / Kamuro: dense warm gold and silver-champagne cascades.
        let dir = fibonacci_dir(local_id, PARTICLES_PER_SHELL, jseed);
        let spd = mix(0.35, 0.48, r.x) * depth_scale;
        spec.v0 = dir * spd;
        spec.drag = 0.96;
        spec.grav = 0.30;
        spec.life = mix(2.55, 3.25, r.y);
        let willow_pal = select(2u, 6u, (gen + shell_id) % 3u == 0u);
        spec.col = shell_palette(willow_pal, r.x > 0.52);
    } else if (arch == 3u) {
        // Tilted 3D Saturn Ring: tilted equatorial ring + compact inner peony core.
        let tilt_a = (hash11(fs * 29.3 + fg * 11.7 + g.seed * 41.0) - 0.5) * 1.9;
        let tilt_b = (hash11(fs * 13.1 + fg * 23.9 + g.seed * 59.0) - 0.5) * 1.4;
        let yaw = hash11(fs * 7.7 + fg * 43.3) * TAU;
        if (local_id < 144u) {
            let ang = (f32(local_id) + (r.x - 0.5) * 0.35) * (TAU / 144.0);
            let ring_v = vec3<f32>(cos(ang), (r.y - 0.5) * 0.06, sin(ang));
            let dir = normalize(rotate_3d(ring_v, yaw, tilt_a, tilt_b));
            let spd = mix(0.50, 0.58, r.x) * depth_scale;
            spec.v0 = dir * spd;
            spec.drag = 1.42;
            spec.grav = 0.18;
            spec.life = mix(2.05, 2.60, r.y);
            spec.col = shell_palette(pal, false);
        } else {
            let dir = fibonacci_dir(local_id - 144u, 112u, jseed + vec2<f32>(9.3, 2.7));
            let spd = mix(0.20, 0.27, r.x) * depth_scale;
            spec.v0 = dir * spd;
            spec.drag = 1.58;
            spec.grav = 0.20;
            spec.life = mix(1.75, 2.25, r.y);
            spec.col = shell_palette(pal, true);
        }
    } else if (arch == 4u) {
        // Crossette Multi-Break Strobe: 16 heavy comets splitting into 16 strobing starlets each.
        let comet = local_id / 16u;
        let cseed = vec2<f32>(fs * 23.1 + fg * 19.7, f32(comet) * 7.3 + g.seed * 53.0);
        let cr = hash22(cseed);
        let dir = fibonacci_dir(comet, 16u, cseed);
        let spd = mix(0.48, 0.58, cr.x) * depth_scale;
        spec.v0 = dir * spd;
        spec.drag = 1.08;
        spec.grav = 0.19;
        spec.life = mix(2.25, 2.75, r.y);
        spec.col = shell_palette(pal, false);
    } else {
        // Spiral Palm / Tourbillon: 9 feathery plumes arching outward with rotational swirl.
        let frond = local_id % 9u;
        let rank = local_id / 9u;
        let fseed = vec2<f32>(fs * 31.7 + fg * 13.3, f32(frond) * 11.9 + g.seed * 61.0);
        let fr = hash22(fseed);
        let yaw = hash11(fs * 5.3 + fg * 37.1) * TAU;
        let dir = rotate_3d(fibonacci_dir(frond, 9u, fseed), yaw, fr.x * 0.6 - 0.3, fr.y * 0.6 - 0.3);
        let t_rank = (f32(rank) + r.x * 0.50) / 28.5;
        let spd = mix(0.26, 0.62, t_rank) * depth_scale;
        let rand_s = sphere_vec_from_hash(jseed);
        let jitter_perp = (rand_s - dir * dot(rand_s, dir)) * 0.085;
        spec.v0 = dir * spd + jitter_perp * depth_scale;
        spec.drag = 1.24;
        spec.grav = 0.24;
        spec.life = mix(2.05, 2.65, r.y);
        spec.col = shell_palette(pal, t_rank > 0.60);
    }

    return spec;
}

fn crossette_kick(
    shell_id: u32,
    local_id: u32,
    gen: u32,
    depth_scale: f32,
) -> vec3<f32> {
    let sub = local_id % 16u;
    let comet = local_id / 16u;
    let s = vec2<f32>(f32(shell_id) * 41.3 + f32(comet) * 13.7, f32(gen) * 17.9 + f32(sub) * 5.1 + g.seed * 83.0);
    let r = hash22(s);
    let dir = fibonacci_dir(sub, 16u, s);
    let spd = mix(0.22, 0.32, r.x) * depth_scale;
    return dir * spd;
}

fn pack_state(gen: u32, stage: u32) -> f32 {
    return f32(((gen % 65535u) + 1u) * 4u + (stage & 3u));
}

fn splat_star(
    p0: vec2<f32>,
    p1: vec2<f32>,
    col: vec3<f32>,
    age: f32,
    life: f32,
    arch: u32,
    stage: u32,
    local_id: u32,
    t: f32,
    allow_segment: bool,
) {
    // In Crossette stage 2, 16 particles ride together per comet: only sub 0 draws the comet tail.
    if (arch == 4u && stage == 2u && (local_id % 16u) != 0u) {
        return;
    }

    let u = clamp(age / max(life, 0.1), 0.0, 1.0);
    if (u >= 1.0) {
        return;
    }

    var env = smoothstep(0.0, 0.035, u) * pow(1.0 - smoothstep(0.42, 1.0, u), 1.40);
    let fl = f32(local_id);
    if (arch == 4u && stage == 2u) {
        env = env * 1.85;
    } else if (arch == 4u && stage == 3u) {
        let strobe = step(0.32, fract(t * 10.5 + fl * 0.618034));
        env = env * mix(0.18, 1.40, strobe);
    } else if (arch == 5u) {
        env = env * 0.72;
    } else if (arch == 2u) {
        let shimmer = 0.62 + 0.38 * sin(t * 14.0 + fl * 2.13);
        env = env * mix(1.0, shimmer, smoothstep(0.42, 0.85, u));
    } else {
        let glitter = 0.74 + 0.26 * sin(t * 11.0 + fl * 1.71);
        env = env * mix(1.0, glitter, smoothstep(0.58, 0.94, u));
    }
    if (env <= 0.005) {
        return;
    }

    let h = f32(splat_dims().y);
    let px_len = length((p1 - p0) * h);
    let trail_w = select(W_TRAIL, W_TRAIL * 1.15, arch == 2u || (arch == 4u && stage == 2u));
    let seg_e = max(px_len, 1.0 - g.fade) * (trail_w * h) * env * 1.45;
    let rgb_seg = col * seg_e;

    // Pure smooth trail in rgb, plus fast-cooling hot tip sparkle in alpha (zero beading).
    if (allow_segment && length(p1 - p0) <= 0.35) {
        splat_segment(p0, p1, rgb_seg, seg_e * 0.15, false);
    } else {
        splat_point(p1, rgb_seg, seg_e * 0.15);
    }

    let tip_a = (trail_w * h) * (trail_w * h) * 3.8 * env;
    splat_point(p1, col * (tip_a * 0.25), tip_a);
}

fn step_particle(idx: u32, t: f32) {
    let a = aspect();
    let n_shells = clamp(u32(round(a * 3.4)), 5u, 12u);
    let shell_id = idx / PARTICLES_PER_SHELL;
    if (shell_id >= n_shells) {
        return;
    }
    let local_id = idx % PARTICLES_PER_SHELL;
    let fs = f32(shell_id);

    // Staggered shell cycles so 4-5 shells bloom cleanly across 32:9 with dark night sky around them.
    let slot_hash = hash11(fs * 13.7 + g.seed * 31.0);
    let slot_hash2 = hash11(fs * 29.1 + g.seed * 47.0);
    let period = mix(5.8, 7.8, slot_hash);
    let slot_off = fract(fs / f32(n_shells) + 0.17 * slot_hash2) * period;

    let cycle_t = t + slot_off;
    let gen = u32(max(floor(cycle_t / period), 0.0));
    let fg = f32(gen);
    let phase = cycle_t - fg * period;

    let h0 = hash22(vec2<f32>(fs * 11.3 + fg * 19.1, g.seed * 73.0 + 3.7));
    let h1 = hash22(vec2<f32>(fs * 23.7 + fg * 37.9, g.seed * 59.0 + 9.1));
    let h2 = hash22(vec2<f32>(fs * 41.1 + fg * 53.3, g.seed * 89.0 + 1.3));

    let t_launch = 0.35 + 0.35 * h0.x;
    let ascent_dur = 0.80 + 0.38 * h0.y;
    let t_burst = t_launch + ascent_dur;

    // Stratified burst positions with golden-ratio progression keep wear uniform across 32:9 and 16:9.
    let bx_norm = fract((fs + 0.18 + 0.64 * h1.x) / f32(n_shells) + fg * 0.381966);
    let burst_x = mix(0.06 * a, 0.94 * a, bx_norm);
    let by_norm = fract(h1.y * 0.35 + fg * 0.618034 + fs * 0.27);
    let burst_y = mix(0.36, 0.88, by_norm);
    let burst_xy = vec2<f32>(burst_x, burst_y);

    let launch_x = clamp(burst_x + (h2.x - 0.5) * 0.20, 0.05 * a, 0.95 * a);
    let launch_y = 0.02 + 0.18 * h2.y;
    let launch_xy = vec2<f32>(launch_x, launch_y);
    let depth_scale = mix(0.68, 1.14, h2.y);

    let arch = (gen + shell_id * 5u + u32(g.seed * 19.0)) % 6u;
    let pal = (gen * 3u + shell_id * 5u + u32(g.seed * 23.0)) % 8u;

    var st = particles[idx];
    let packed = u32(round(max(st.c.w, 0.0)));
    let uninit = g.frame < 0.5 || packed == 0u;
    let prev_gen = select(0u, (packed / 4u) - 1u, packed >= 4u);
    let prev_stage = packed & 3u;

    // Dormant pause before launch.
    if (phase < t_launch) {
        particles[idx].c.w = pack_state(gen, 0u);
        return;
    }

    // Rocket ascent stage: delicate golden mortar tracer + nozzle sparks.
    if (phase < t_burst) {
        let u_cur = clamp((phase - t_launch) / ascent_dur, 0.0, 1.0);
        let u_prev = clamp((phase - g.dt - t_launch) / ascent_dur, 0.0, 1.0);
        let p_cur = rocket_pos(launch_xy, burst_xy, u_cur, fs * 7.1 + fg);
        let p_prev = rocket_pos(launch_xy, burst_xy, u_prev, fs * 7.1 + fg);
        let h = f32(splat_dims().y);
        let rocket_col = vec3<f32>(1.00, 0.68, 0.26);

        if (local_id == 0u) {
            let px_len = length((p_cur - p_prev) * h);
            let seg_e = max(px_len, 1.0 - g.fade) * (W_TRAIL * 0.55 * h);
            if (!uninit && prev_gen == gen && prev_stage == 1u && length(p_cur - p_prev) <= 0.35) {
                splat_segment(p_prev, p_cur, rocket_col * seg_e, seg_e * 0.4, false);
            } else {
                splat_point(p_cur, rocket_col * seg_e, seg_e * 0.4);
            }
            let head_e = (W_TRAIL * h) * (W_TRAIL * h) * 1.8;
            splat_point(p_cur, rocket_col * (head_e * 0.35), head_e);
        } else if (local_id < 8u) {
            let u_wake = u_cur - 0.012 * f32(local_id);
            if (u_wake > 0.02) {
                let jitter = (hash22(vec2<f32>(f32(local_id) * 3.1, t * 24.0 + fs)) - 0.5) * 0.012;
                let pw = rocket_pos(launch_xy, burst_xy, u_wake, fs * 7.1 + fg) + jitter;
                let fade_w = 1.0 - f32(local_id) / 8.0;
                let spark_e = (W_TRAIL * h) * (W_TRAIL * h) * 0.8 * fade_w;
                splat_point(pw, vec3<f32>(1.0, 0.50, 0.16) * (spark_e * 0.5), spark_e);
            }
        }
        particles[idx].p = vec4<f32>(p_cur, 0.0, phase - t_launch);
        particles[idx].c = vec4<f32>(rocket_col, pack_state(gen, 1u));
        return;
    }

    // Burst stages (stage 2 primary, stage 3 crossette secondary).
    let tau = phase - t_burst;
    let sp = star_params(arch, pal, shell_id, local_id, gen, depth_scale);

    if (tau > sp.life + 0.1) {
        particles[idx].c.w = pack_state(gen, 0u);
        return;
    }

    // Uninitialized / frame 0 pre-warm so the canvas starts alive with mid-bloom shells.
    if (uninit) {
        var pos = vec3<f32>(0.0);
        var vel = sp.v0;
        var col = sp.col;
        var stage = 2u;
        if (arch == 4u && tau >= CROSSETTE_SPLIT_AGE) {
            let s1 = integrate_ballistic(pos, vel, sp.drag, sp.grav, CROSSETTE_SPLIT_AGE);
            pos = s1[0];
            vel = s1[1] + crossette_kick(shell_id, local_id, gen, depth_scale);
            let s2 = integrate_ballistic(pos, vel, 2.25, sp.grav * 1.1, tau - CROSSETTE_SPLIT_AGE);
            pos = s2[0];
            vel = s2[1];
            col = shell_palette(pal, true);
            stage = 3u;
        } else {
            let s1 = integrate_ballistic(pos, vel, sp.drag, sp.grav, tau);
            pos = s1[0];
            vel = s1[1];
        }
        let p2 = project_3d(burst_xy, pos);
        splat_star(p2, p2, col, tau, sp.life, arch, stage, local_id, t, false);
        particles[idx].p = vec4<f32>(pos, tau);
        particles[idx].v = vec4<f32>(vel, sp.life);
        particles[idx].c = vec4<f32>(col, pack_state(gen, stage));
        return;
    }

    // Fresh shell detonation.
    if (prev_gen != gen || prev_stage < 2u) {
        let dt_step = clamp(tau, 0.004, g.dt);
        let step1 = integrate_ballistic(vec3<f32>(0.0), sp.v0, sp.drag, sp.grav, dt_step);
        let pos1 = step1[0];
        let vel1 = step1[1];
        if (local_id == 0u) {
            let h = f32(splat_dims().y);
            let flash_e = (0.012 * depth_scale * h) * (0.012 * depth_scale * h) * 0.45;
            splat_disc(burst_xy, 0.012 * depth_scale, sp.col * (flash_e * 0.5), flash_e * 2.5, false);
        }
        let p1 = project_3d(burst_xy, pos1);
        splat_star(burst_xy, p1, sp.col, dt_step, sp.life, arch, 2u, local_id, t, true);
        particles[idx].p = vec4<f32>(pos1, dt_step);
        particles[idx].v = vec4<f32>(vel1, sp.life);
        particles[idx].c = vec4<f32>(sp.col, pack_state(gen, 2u));
        return;
    }

    // Active star flight.
    var pos = st.p.xyz;
    var vel = st.v.xyz;
    let age = st.p.w;
    var col = st.c.rgb;
    let stage = prev_stage;
    if (age >= st.v.w) {
        return;
    }

    let drag = select(sp.drag, 2.25, stage == 3u);
    let grav_eff = select(sp.grav, sp.grav * 1.1, stage == 3u);

    // Gentle tangential curl for Spiral Palm fronds so arms sweep into graceful curves.
    if (arch == 5u && stage == 2u) {
        let spin_dir = select(-1.0, 1.0, (shell_id + gen) % 2u == 0u);
        let swirl = rot2(spin_dir * g.dt * 0.65) * vel.xy;
        vel = vec3<f32>(swirl.x, swirl.y, vel.z);
    }

    let next_age = age + g.dt;
    if (arch == 4u && stage == 2u && next_age >= CROSSETTE_SPLIT_AGE) {
        let dt_pre = max(CROSSETTE_SPLIT_AGE - age, 0.0);
        let pre = integrate_ballistic(pos, vel, sp.drag, sp.grav, dt_pre);
        let split_p = project_3d(burst_xy, pre[0]);
        if (dt_pre > 0.001) {
            let p_start = project_3d(burst_xy, pos);
            splat_star(p_start, split_p, col, CROSSETTE_SPLIT_AGE, sp.life, arch, 2u, local_id, t, true);
        }
        if ((local_id % 16u) == 0u) {
            let h = f32(splat_dims().y);
            let crack_e = (W_TRAIL * h) * (W_TRAIL * h) * 2.5;
            splat_point(split_p, col * (crack_e * 0.3), crack_e);
        }

        let dt_post = max(next_age - CROSSETTE_SPLIT_AGE, 0.002);
        let kicked_v = pre[1] + crossette_kick(shell_id, local_id, gen, depth_scale);
        let post = integrate_ballistic(pre[0], kicked_v, 2.25, sp.grav * 1.1, dt_post);
        col = shell_palette(pal, true);
        let p_end = project_3d(burst_xy, post[0]);
        splat_star(split_p, p_end, col, next_age, sp.life, arch, 3u, local_id, t, true);
        particles[idx].p = vec4<f32>(post[0], next_age);
        particles[idx].v = vec4<f32>(post[1], sp.life);
        particles[idx].c = vec4<f32>(col, pack_state(gen, 3u));
        return;
    }

    let stepped = integrate_ballistic(pos, vel, drag, grav_eff, g.dt);
    let p_start = project_3d(burst_xy, pos);
    let p_end = project_3d(burst_xy, stepped[0]);
    splat_star(p_start, p_end, col, next_age, sp.life, arch, stage, local_id, t, true);
    particles[idx].p = vec4<f32>(stepped[0], next_age);
    particles[idx].v = vec4<f32>(stepped[1], sp.life);
    particles[idx].c = vec4<f32>(col, pack_state(gen, stage));
}

fn resolve_state(uv: vec2<f32>, _p: vec2<f32>, _t: f32, splat: vec4<f32>) -> vec4<f32> {
    let prev_uv = uv - vec2<f32>(WIND_VX * g.dt / aspect(), 0.0);
    var prev = vec4<f32>(0.0);
    if (prev_uv.x >= 0.0 && prev_uv.x <= 1.0 && prev_uv.y >= 0.0 && prev_uv.y <= 1.0) {
        prev = state_sample(prev_uv);
    }
    let core_fade = exp(-g.dt * 11.0);
    return vec4<f32>(prev.rgb * g.fade, prev.a * core_fade) + splat;
}

fn hack(p: vec2<f32>, _t: f32) -> vec3<f32> {
    let uv = state_uv(p);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return vec3<f32>(0.0);
    }

    let s = state_sample(uv);
    let d = state_texel();

    // Tight 8-tap optical bloom around bright spark trails and heads.
    let h_card = state_sample(uv + vec2<f32>(d.x * 1.4, 0.0))
        + state_sample(uv - vec2<f32>(d.x * 1.4, 0.0))
        + state_sample(uv + vec2<f32>(0.0, d.y * 1.4))
        + state_sample(uv - vec2<f32>(0.0, d.y * 1.4));
    let h_diag = state_sample(uv + vec2<f32>(d.x * 2.4, d.y * 2.4))
        + state_sample(uv + vec2<f32>(-d.x * 2.4, d.y * 2.4))
        + state_sample(uv + vec2<f32>(d.x * 2.4, -d.y * 2.4))
        + state_sample(uv + vec2<f32>(-d.x * 2.4, -d.y * 2.4));
    let halo = (h_card + h_diag) * 0.125;

    let raw_rgb = max(s.rgb + halo.rgb * 0.22, vec3<f32>(0.0));
    let peak_c = max(raw_rgb.r, max(raw_rgb.g, raw_rgb.b));
    if (peak_c <= 1e-4 && s.a <= 1e-4) {
        return vec3<f32>(0.0);
    }

    // Chromaticity-preserving tone mapping keeps jewel metal-salt colors vivid at any overlap.
    let mapped_lum = 1.0 - exp(-peak_c * 1.35);
    var out_col = raw_rgb * (mapped_lum / max(peak_c, 1e-4));
    let hot = clamp(s.a * 0.65 + halo.a * 0.10, 0.0, 1.5);
    let incand = smoothstep(0.20, 1.10, hot) * 0.34 * smoothstep(0.03, 0.40, mapped_lum);
    out_col = mix(out_col, vec3<f32>(1.0, 0.98, 0.92), incand);
    return clamp(out_col, vec3<f32>(0.0), vec3<f32>(1.0));
}

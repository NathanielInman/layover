// Wisp Swarm: translucent X-ray critter wakes and wind-casting scent seekers
// weaving glowing trails across a single unified, stationary full-canvas field
// on Tier P compute particles and Tier S feedback textures.
// After xscreensaver's XRaySwarm (Chris Leger) and Anemotaxis (Eugene Balkovsky).
//
// O(1) race-free compute particle layout (`Particles { count: 512 }`, each thread
// updates only `particles[idx]` directly in full-canvas coordinates `0..aspect() x 0..1`):
//   p.xy = 2D canvas position (canvas heights)
//   p.z  = pseudo-3D depth z (XRaySwarm) | age in seconds (Anemotaxis plume/wind)
//          | surge/cast timer in seconds (>0 surge left, <=0 negative cast age) (seeker)
//   p.w  = depth velocity vz (XRaySwarm) | lifetime in seconds (plume/wind)
//          | crosswind zigzag cast phase in radians (seeker)
//   v.xy = 2D velocity (canvas heights/sec)
//   v.z  = per-critter rank 0..1 (XRaySwarm) | eddy seed (plume)
//          | scent-contact flash energy 0..1 (seeker)
//   v.w  = role tag (XRaySwarm: 0..4 sub-swarm; Anemotaxis: 0 beacon, 1 plume, 2 wind, 3 seeker)
//   c.rgb = base palette RGB color
//   c.w   = packed epoch `(gen % 16777215u) + 1u` stored exact in f32 (0 = uninitialized)

const EPOCH_SECS: f32 = 36.0;

fn safe_norm2(v: vec2<f32>, fallback: vec2<f32>) -> vec2<f32> {
    let l2 = dot(v, v);
    if (l2 > 1e-10) {
        return v * inverseSqrt(l2);
    }
    return fallback;
}

fn safe_norm3(v: vec3<f32>, fallback: vec3<f32>) -> vec3<f32> {
    let l2 = dot(v, v);
    if (l2 > 1e-10) {
        return v * inverseSqrt(l2);
    }
    return fallback;
}

fn clamp_len2(v: vec2<f32>, min_l: f32, max_l: f32) -> vec2<f32> {
    let l2 = dot(v, v);
    if (l2 <= 1e-12) {
        return vec2<f32>(min_l, 0.0);
    }
    let l = sqrt(l2);
    if (l < min_l) {
        return v * (min_l / l);
    }
    if (l > max_l) {
        return v * (max_l / l);
    }
    return v;
}

// Smooth-cornered triangle wave in [0, 1] with steady interior velocity for even panel wear.
fn smooth_tri(u: f32) -> f32 {
    let f = fract(u) * 2.0 - 1.0;
    let s = sqrt(f * f + 0.025) - sqrt(0.025);
    return clamp(s / (sqrt(1.025) - sqrt(0.025)), 0.0, 1.0);
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

// Four RGB-balanced palettes pairing translucent radiograph hues with warm surge accents.
fn wisp_palette(pal: u32, slot: u32) -> vec3<f32> {
    let p = pal % 4u;
    let s = slot % 5u;
    if (p == 0u) {
        // Radiograph Cyan & Violet
        if (s == 0u) { return vec3<f32>(0.20, 0.88, 1.00); }
        if (s == 1u) { return vec3<f32>(0.56, 0.40, 1.00); }
        if (s == 2u) { return vec3<f32>(0.16, 0.96, 0.66); }
        if (s == 3u) { return vec3<f32>(1.00, 0.52, 0.22); }
        return vec3<f32>(0.36, 0.72, 1.00);
    }
    if (p == 1u) {
        // Nocturne Moth & Pheromone
        if (s == 0u) { return vec3<f32>(0.16, 0.94, 0.80); }
        if (s == 1u) { return vec3<f32>(0.70, 0.34, 1.00); }
        if (s == 2u) { return vec3<f32>(0.36, 0.96, 0.36); }
        if (s == 3u) { return vec3<f32>(1.00, 0.66, 0.18); }
        return vec3<f32>(0.96, 0.34, 0.68);
    }
    if (p == 2u) {
        // Oscilloscope Prism
        if (s == 0u) { return vec3<f32>(1.00, 0.28, 0.64); }
        if (s == 1u) { return vec3<f32>(0.18, 0.76, 1.00); }
        if (s == 2u) { return vec3<f32>(0.24, 0.98, 0.56); }
        if (s == 3u) { return vec3<f32>(1.00, 0.72, 0.20); }
        return vec3<f32>(0.62, 0.42, 1.00);
    }
    // Thermal Plume & Copper
    if (s == 0u) { return vec3<f32>(1.00, 0.40, 0.20); }
    if (s == 1u) { return vec3<f32>(0.24, 0.58, 1.00); }
    if (s == 2u) { return vec3<f32>(0.18, 0.96, 0.82); }
    if (s == 3u) { return vec3<f32>(0.98, 0.30, 0.76); }
    return vec3<f32>(0.54, 0.96, 0.32);
}

// Resolution- and dt-invariant glowing trail segment splat in full-canvas world coordinates.
fn splat_trail_seg(
    p0: vec2<f32>,
    p1: vec2<f32>,
    w_world: f32,
    col: vec3<f32>,
    scent: f32,
    bright: f32,
    env: f32,
    a: f32,
) {
    if (env <= 0.003 || bright <= 0.002) {
        return;
    }
    let mid = 0.5 * (p0 + p1);
    let edge = smoothstep(0.02, 0.08, mid.x)
        * (1.0 - smoothstep(a - 0.08, a - 0.02, mid.x))
        * smoothstep(0.02, 0.08, mid.y)
        * (1.0 - smoothstep(0.92, 0.98, mid.y));
    let eff = env * edge;
    if (eff <= 0.003) {
        return;
    }

    let step_d = length(p1 - p0);
    if (step_d > 0.42 || step_d < 1e-6) {
        return;
    }

    let h = f32(splat_dims().y);
    let L_px = step_d * h;
    let w_px = max(w_world * h, 0.82);
    let area_px = L_px * w_px;
    let rgb_e = col * (bright * eff * area_px);
    let scent_e = scent * eff * area_px;

    if (h < 180.0) {
        splat_segment(p0, p1, rgb_e, scent_e, false);
        return;
    }

    let r_world = w_world * 0.5;
    let r_px = r_world * h;
    let n_pts = clamp(i32(ceil(L_px / max(r_px * 0.65, 0.9))), 1, 16);
    let inv_n = 1.0 / f32(n_pts);
    let rgb_pt = rgb_e * inv_n;
    let scent_pt = scent_e * inv_n;
    for (var k = 0; k < n_pts; k = k + 1) {
        let u = (f32(k) + 0.5) * inv_n;
        let pt = mix(p0, p1, u);
        splat_disc(pt, r_world, rgb_pt, scent_pt, false);
    }
}

// Resolution- and dt-invariant glowing puff / spark splat in full-canvas world coordinates.
fn splat_puff(
    world_p: vec2<f32>,
    r_world: f32,
    col: vec3<f32>,
    scent: f32,
    bright: f32,
    env: f32,
    a: f32,
) {
    if (env <= 0.003 || (bright <= 0.002 && scent <= 0.002)) {
        return;
    }
    let edge = smoothstep(0.02, 0.08, world_p.x)
        * (1.0 - smoothstep(a - 0.08, a - 0.02, world_p.x))
        * smoothstep(0.02, 0.09, world_p.y)
        * (1.0 - smoothstep(0.91, 0.98, world_p.y));
    let eff = env * edge;
    if (eff <= 0.003) {
        return;
    }

    let h = f32(splat_dims().y);
    let dt_fade = max(1.0 - g.fade, 0.008);
    let area_scale = max(r_world * h, 0.78);
    let e = area_scale * area_scale * dt_fade * eff;
    splat_disc(world_p, r_world, col * (bright * e), scent * e, false);
}

// --- Full-Canvas XRaySwarm target curves (arch == 0 and arch == 2) ---

fn xray_roam_target(arch: u32, swarm_id: u32, gen: u32, phase: f32, a: f32) -> vec3<f32> {
    let fs = f32(swarm_id);
    let fg = f32(gen);
    let h = hash22(vec2<f32>(fs * 17.3 + fg * 31.7, g.seed * 61.0 + 3.1));
    let seed_v = vec2<f32>(fs * 31.7 + fg * 19.3, g.seed * 97.0 + f32(arch) * 7.1);
    let s = max(phase + 1.5, 0.0);
    let n_swarms = select(5u, 3u, a < 2.4);

    if (arch == 0u) {
        // Equal-speed isotropic Catmull-Rom roaming across the open 32:9 canvas.
        let x_lo = 0.16;
        let x_hi = max(a - 0.16, 0.32);
        let y_lo = 0.13;
        let y_hi = 0.87;
        let p1 = vec2<f32>(
            mix(x_lo, x_hi, fract((fs + 0.5) / f32(n_swarms) + (h.x - 0.5) * 0.14)),
            mix(y_lo, y_hi, h.y),
        );
        let xy = iso_waypoint_pos(
            p1, h.x * TAU, seed_v, s, 0.46,
            x_lo, x_hi, y_lo, y_hi,
            0.44, 0.78, 64u,
        );
        let z = 0.22 * sin(s * (0.72 + 0.12 * fs) + h.x * TAU);
        return vec3<f32>(xy, z);
    }

    // arch == 2u: Broad 1:1 circular orbital ribbons gliding evenly across the room.
    let dir = select(-1.0, 1.0, (swarm_id % 2u) == 0u);
    let x_lo = 0.34;
    let x_hi = max(a - 0.34, 0.40);
    let y_lo = 0.32;
    let y_hi = 0.68;
    let p1 = vec2<f32>(
        mix(x_lo, x_hi, fract((fs + 0.5) / f32(n_swarms) + (h.y - 0.5) * 0.14)),
        mix(y_lo, y_hi, h.x),
    );
    let c = iso_waypoint_pos(
        p1, h.y * TAU, seed_v, s, 0.24,
        x_lo, x_hi, y_lo, y_hi,
        0.34, 0.62, 48u,
    );
    let w = s * (1.10 + 0.14 * fs) * dir + h.x * TAU;
    let r_orb = 0.22;
    let pos = c + vec2<f32>(cos(w), sin(w)) * r_orb;
    let z = 0.22 * cos(w * 1.15 - fs * 0.9);
    return vec3<f32>(clamp(pos.x, 0.06, a - 0.06), clamp(pos.y, 0.08, 0.92), z);
}

// --- Full-Canvas Anemotaxis beacons and wind fields (arch == 1 and arch == 3) ---

fn anemo_wind_sign(gen: u32) -> f32 {
    // Alternates dominant wind direction across epochs (-1 = right-to-left, +1 = left-to-right).
    return select(1.0, -1.0, ((gen + u32(g.seed * 7.0)) % 2u) == 0u);
}

fn anemo_beacon(arch: u32, beacon_id: u32, gen: u32, phase: f32, a: f32) -> vec2<f32> {
    let fg = f32(gen);
    let h = hash22(vec2<f32>(fg * 29.3 + f32(beacon_id) * 19.7, g.seed * 71.0 + 1.9));

    if (arch == 1u) {
        // Wide-roaming upwind scent emitter sweeping continuously with 1:1 circular orbit at turns.
        let sgn = anemo_wind_sign(gen);
        let x_min = select(0.10 * a, 0.66 * a, sgn < 0.0);
        let x_max = select(0.34 * a, 0.90 * a, sgn < 0.0);
        let fx = 0.16 / (2.0 * max(x_max - x_min, 0.30));
        let fy = 0.16 / (2.0 * 0.66);
        let ux = smooth_tri(phase * fx + h.x);
        let uy = smooth_tri(phase * fy + h.y);
        let orb_x = 0.055 * cos(phase * 0.95 + h.x * TAU);
        let orb_y = 0.055 * sin(phase * 0.95 + h.x * TAU);
        return vec2<f32>(
            clamp(mix(x_min, x_max, ux) + orb_x, 0.06, a - 0.06),
            clamp(mix(0.17, 0.83, uy) + orb_y, 0.11, 0.89),
        );
    }

    // arch == 3u: Two open-canvas beacons gliding smoothly across opposite halves of the monitor.
    let fb = f32(beacon_id);
    let x_lo = select(0.55 * a, 0.09 * a, beacon_id == 0u);
    let x_hi = select(0.91 * a, 0.45 * a, beacon_id == 0u);
    let fx = 0.16 / (2.0 * max(x_hi - x_lo, 0.30));
    let fy = 0.16 / (2.0 * 0.66);
    let ux = smooth_tri(phase * fx + h.x * 0.5 + fb * 0.5);
    let uy = smooth_tri(phase * fy + h.y + fb * 0.35);
    return vec2<f32>(
        clamp(mix(x_lo, x_hi, ux) + 0.055 * cos(phase * 0.82 + fb * PI), 0.06, a - 0.06),
        clamp(mix(0.17, 0.83, uy) + 0.055 * sin(phase * 0.82 + fb * PI), 0.11, 0.89),
    );
}

fn anemo_wind(arch: u32, p: vec2<f32>, gen: u32, phase: f32, a: f32) -> vec2<f32> {
    let fg = f32(gen);
    let ph = hash11(fg * 23.9 + g.seed * 47.0) * TAU;
    let is_narrow = a < 2.4;
    let sx = select(1.0, 0.76, is_narrow);

    if (arch == 1u) {
        // Unified turbulent cross-screen wind sweeping across the whole canvas.
        let sgn = anemo_wind_sign(gen);
        let gust_y = 0.22 * sin(p.x * 2.8 - phase * 1.45 * sgn + ph)
            + 0.11 * cos(p.y * 5.2 + phase * 1.2 - ph * 0.4);
        let base_x = sgn * (0.72 * sx + 0.12 * cos(p.y * 4.0 + phase * 1.1 + ph));
        return vec2<f32>(base_x, gust_y);
    }

    // arch == 3u: Screen-wide S-bend double-eddy airflow connecting the full canvas.
    let nx = p.x * 2.2;
    let ny = (p.y - 0.5) * PI;
    let vx = (0.38 * cos(ny) + 0.25 * sin(nx * 1.0 + phase * 0.48 + ph)) * sx;
    let vy = 0.30 * sin(nx * 1.5 - phase * 0.65 + ph) + 0.15 * cos(nx * 2.5 + ny + phase * 0.85);
    let c = vec2<f32>(a * 0.5, 0.5);
    let rel = p - c;
    let swirl = vec2<f32>(-rel.y * 0.36, rel.x * (0.15 / max(a * 0.5, 0.5)));
    return vec2<f32>(vx, vy) + swirl;
}

fn spawn_particle(
    arch: u32,
    pal_id: u32,
    local_id: u32,
    n_active: u32,
    gen: u32,
    phase: f32,
    a: f32,
) -> Particle {
    let fl = f32(local_id);
    let fg = f32(gen);
    let h0 = hash22(vec2<f32>(fl * 2.13 + fg * 17.7, fg * 31.3 + g.seed * 67.0));
    let h1 = hash22(vec2<f32>(fl * 3.71 + fg * 23.1, fl * 1.39 + g.seed * 53.0));
    let packed_gen = f32((gen % 16777215u) + 1u);
    let is_narrow = a < 2.4;

    var out: Particle;
    if (arch == 0u || arch == 2u) {
        // Full-canvas XRaySwarm regimes.
        let n_swarms = select(5u, 3u, is_narrow);
        let swarm_id = local_id % n_swarms;
        let sub_id = local_id / n_swarms;
        let sub_count = max(n_active / n_swarms, 1u);
        let rank_u = (f32(sub_id) + 0.5) / f32(sub_count);
        let tgt = xray_roam_target(arch, swarm_id, gen, phase - rank_u * 0.44, a);

        let a_ring = rank_u * TAU * 2.0 + h0.x * 0.3;
        let r_ring = 0.025 + 0.075 * rank_u;
        let p_xy = vec2<f32>(
            clamp(tgt.x + cos(a_ring) * r_ring, 0.04, a - 0.04),
            clamp(tgt.y + sin(a_ring) * r_ring * 0.8, 0.06, 0.94),
        );
        let p_z = tgt.z + 0.06 * (h1.y - 0.5);

        let ahead = xray_roam_target(arch, swarm_id, gen, phase - rank_u * 0.44 + 0.14, a);
        let v3 = safe_norm3(ahead - tgt, vec3<f32>(1.0, 0.0, 0.0)) * (0.70 + 0.35 * h1.x);
        let col = wisp_palette(pal_id, swarm_id);

        out.p = vec4<f32>(p_xy, p_z, v3.z);
        out.v = vec4<f32>(v3.xy, rank_u, f32(swarm_id));
        out.c = vec4<f32>(col, packed_gen);
        return out;
    }

    // Full-canvas Anemotaxis regimes (arch == 1u and arch == 3u).
    let n_beacons = select(12u, 10u, is_narrow);
    let n_plume = select(248u, 150u, is_narrow);
    let n_wind = select(52u, 30u, is_narrow);

    if (local_id < n_beacons) {
        let beacon_id = select(0u, local_id % 2u, arch == 3u);
        let b_pos = anemo_beacon(arch, beacon_id, gen, phase, a);
        let ang = fl * (TAU / f32(n_beacons)) + h0.x * TAU;
        let off = vec2<f32>(cos(ang), sin(ang)) * 0.017;
        out.p = vec4<f32>(b_pos + off, f32(beacon_id), 0.0);
        out.v = vec4<f32>(-sin(ang) * 0.22, cos(ang) * 0.22, h1.x, 0.0);
        out.c = vec4<f32>(wisp_palette(pal_id, 3u), packed_gen);
        return out;
    }

    if (local_id < n_beacons + n_plume) {
        let idx_p = local_id - n_beacons;
        let beacon_id = select(0u, idx_p % 2u, arch == 3u);
        let life = select(3.6 + 1.6 * h0.y, 4.0 + 1.8 * h0.y, arch == 1u);
        let age = (f32(idx_p) / f32(n_plume)) * life;
        let b_emit = anemo_beacon(arch, beacon_id, gen, max(phase - age, 0.0), a);
        let w_emit = anemo_wind(arch, b_emit, gen, max(phase - age * 0.5, 0.0), a);
        let swirl = vec2<f32>((h1.x - 0.5) * 0.09, (h1.y - 0.5) * 0.14);
        let pos = vec2<f32>(
            clamp(b_emit.x + (w_emit.x + swirl.x) * age, 0.03 * a, 0.97 * a),
            clamp(b_emit.y + (w_emit.y + swirl.y) * age, 0.06, 0.94),
        );
        let col = wisp_palette(pal_id, select(1u, beacon_id, arch == 3u));
        out.p = vec4<f32>(pos, age, life);
        out.v = vec4<f32>(w_emit + swirl, h0.x, 1.0);
        out.c = vec4<f32>(col, packed_gen);
        return out;
    }

    if (local_id < n_beacons + n_plume + n_wind) {
        let pos = vec2<f32>(mix(0.04 * a, 0.96 * a, h0.x), mix(0.06, 0.94, h0.y));
        let vel = anemo_wind(arch, pos, gen, phase, a);
        let life = 2.0 + 1.6 * h1.x;
        let age = h1.y * life;
        out.p = vec4<f32>(pos, age, life);
        out.v = vec4<f32>(vel, h0.x, 2.0);
        out.c = vec4<f32>(wisp_palette(pal_id, 2u), packed_gen);
        return out;
    }

    // Olfactory Seeker Moths spanning the downwind search zone (or full screen in eddy mode).
    let seek_base = n_beacons + n_plume + n_wind;
    let idx_s = local_id - seek_base;
    let n_seek = max(n_active - seek_base, 1u);
    let u_s = (f32(idx_s) + 0.5) / f32(n_seek);
    let sgn = anemo_wind_sign(gen);
    let sx_u = fract(u_s * 1.618034 + h0.x * 0.35);
    let pos_x = select(
        mix(0.08 * a, 0.92 * a, sx_u),
        select(mix(0.28 * a, 0.93 * a, sx_u), mix(0.07 * a, 0.72 * a, sx_u), sgn < 0.0),
        arch == 1u,
    );
    let pos = vec2<f32>(pos_x, mix(0.08, 0.92, h0.y));
    let w_loc = anemo_wind(arch, pos, gen, phase, a);
    let w_hat = safe_norm2(w_loc, vec2<f32>(-1.0, 0.0));
    let c_hat = vec2<f32>(-w_hat.y, w_hat.x);
    let cast_phase = h1.x * TAU;
    let vel = c_hat * (0.56 * sin(cast_phase)) + w_hat * 0.14;
    out.p = vec4<f32>(pos, -h1.y * 1.5, cast_phase);
    out.v = vec4<f32>(vel, 0.0, 3.0);
    out.c = vec4<f32>(wisp_palette(pal_id, 2u), packed_gen);
    return out;
}

fn step_particle(idx: u32, t: f32) {
    let a = aspect();
    let is_narrow = a < 2.4;
    let total = particle_count();
    let n_active = select(total, min(320u, total), is_narrow);
    if (idx >= n_active) {
        return;
    }

    let gen = u32(max(floor(t / EPOCH_SECS), 0.0));
    let phase = t - f32(gen) * EPOCH_SECS;
    let u_epoch = phase / EPOCH_SECS;
    let env = smoothstep(0.0, 0.04, u_epoch) * (1.0 - smoothstep(0.94, 1.0, u_epoch));

    let arch = (gen + u32(g.seed * 13.0)) % 4u;
    let pal_id = (gen * 3u + u32(g.seed * 17.0)) % 4u;

    let st = particles[idx];
    let packed_now = f32((gen % 16777215u) + 1u);
    let uninit = g.frame < 0.5
        || st.c.w <= 0.5
        || abs(st.c.w - packed_now) > 0.5
        || !all(st.p == st.p)
        || !all(st.v == st.v);

    if (uninit) {
        particles[idx] = spawn_particle(arch, pal_id, idx, n_active, gen, phase, a);
        return;
    }

    let dt = clamp(g.dt, 1e-4, 0.14);

    if (arch == 0u || arch == 2u) {
        // --- Full-Canvas XRaySwarm: coherent sweeping translucent critter ribbons ---
        let n_swarms = select(5u, 3u, is_narrow);
        let swarm_id = u32(round(st.v.w)) % n_swarms;
        let rank_u = st.v.z;
        let fl = f32(idx);
        let j_crit = hash22(vec2<f32>(fl * 4.17 + f32(gen) * 19.3, g.seed * 31.0 + 7.1));

        let pos3 = vec3<f32>(st.p.xy, st.p.z);
        let vel3 = vec3<f32>(st.v.xy, st.p.w);

        // Coherent ordered phase lag + gentle ribbon spread forms glowing X-ray sheets without hairballs.
        let lag = rank_u * 0.44 + (j_crit.x - 0.5) * 0.07;
        let tgt = xray_roam_target(arch, swarm_id, gen, phase - lag, a);
        let tgt_ahead = xray_roam_target(arch, swarm_id, gen, phase - lag + 0.12, a);
        let flow = safe_norm3(tgt_ahead - tgt, vec3<f32>(1.0, 0.0, 0.0));
        let side = safe_norm3(cross(flow, vec3<f32>(0.0, 0.0, 1.0)), vec3<f32>(0.0, 1.0, 0.0));
        let binorm = cross(flow, side);

        let fan_ang = rank_u * TAU * 1.5 + phase * 0.68 + f32(swarm_id) * 1.2 + j_crit.y * 0.55;
        let fan_w = select(0.056, 0.068, arch == 2u) * (0.45 + 0.55 * sin(phase * 0.55 + rank_u * PI));
        let ribbon_tgt = tgt + side * (cos(fan_ang) * fan_w) + binorm * (sin(fan_ang) * fan_w * 0.72);

        let to_tgt = ribbon_tgt - pos3;
        let k_spring = mix(3.6, 5.4, j_crit.x);
        let curl = vec3<f32>(
            sin(pos3.y * 6.5 + phase * 1.4 + rank_u * 3.0),
            cos(pos3.x * 4.5 - phase * 1.2 - rank_u * 2.5),
            sin((pos3.x + pos3.y) * 5.0 + phase * 1.1),
        ) * 0.16;
        let acc = to_tgt * k_spring + curl;

        let drag_k = mix(1.30, 1.70, j_crit.y);
        var v_new = vel3 * exp(-drag_k * dt) + acc * dt;
        let spd = length(v_new);
        let v_min = 0.28;
        let v_max = select(1.05, 1.12, arch == 2u);
        if (spd < v_min) {
            v_new = safe_norm3(v_new, flow) * v_min;
        } else if (spd > v_max) {
            v_new = v_new * (v_max / spd);
        }

        var p_new = pos3 + v_new * dt;
        if (p_new.x < 0.04 || p_new.x > a - 0.04) {
            p_new.x = clamp(p_new.x, 0.04, a - 0.04);
            v_new.x = -v_new.x * 0.72;
        }
        if (p_new.y < 0.04 || p_new.y > 0.96) {
            p_new.y = clamp(p_new.y, 0.04, 0.96);
            v_new.y = -v_new.y * 0.72;
        }
        if (abs(p_new.z) > 0.34) {
            p_new.z = clamp(p_new.z, -0.34, 0.34);
            v_new.z = -v_new.z * 0.72;
        }

        if (!all(p_new == p_new) || !all(v_new == v_new)) {
            particles[idx] = spawn_particle(arch, pal_id, idx, n_active, gen, phase, a);
            return;
        }

        var next_st: Particle;
        next_st.p = vec4<f32>(p_new.xy, p_new.z, v_new.z);
        next_st.v = vec4<f32>(v_new.xy, rank_u, st.v.w);
        next_st.c = st.c;
        particles[idx] = next_st;

        let depth_l = clamp(1.06 - p_new.z * 0.55, 0.46, 1.32);
        let vel_sheen = smoothstep(0.32, 0.92, length(v_new));
        let strand_col = mix(st.c.rgb, vec3<f32>(0.94, 0.98, 1.00), 0.14 + 0.34 * vel_sheen);
        let width_w = mix(0.0038, 0.0056, vel_sheen);
        let bright = (0.24 + 0.22 * vel_sheen) * depth_l;
        splat_trail_seg(pos3.xy, p_new.xy, width_w, strand_col, 0.0, bright, env, a);

        if ((idx % 4u) == 0u) {
            let head_col = mix(st.c.rgb, vec3<f32>(1.0, 0.99, 0.96), 0.60);
            splat_puff(p_new.xy, 0.0046, head_col, 0.0, 0.26 * depth_l, env, a);
        }
        return;
    }

    // --- Full-Canvas Anemotaxis regimes (arch == 1u and arch == 3u) ---
    let role = u32(round(st.v.w));
    let n_beacons = select(12u, 10u, is_narrow);

    if (role == 0u) {
        let beacon_id = u32(round(st.p.z)) % 2u;
        let b_pos = anemo_beacon(arch, beacon_id, gen, phase, a);
        let ang = phase * 4.4 + f32(idx) * (TAU / f32(n_beacons));
        let p_new = b_pos + vec2<f32>(cos(ang), sin(ang)) * 0.017;
        let p_old = st.p.xy;

        var next_st = st;
        next_st.p = vec4<f32>(p_new, st.p.z, 0.0);
        next_st.v = vec4<f32>((p_new - p_old) / dt, st.v.z, 0.0);
        particles[idx] = next_st;

        let b_col = mix(st.c.rgb, vec3<f32>(1.00, 0.98, 0.90), 0.55);
        splat_puff(p_new, 0.015, b_col, 0.95, 0.68, env, a);
        return;
    }

    if (role == 1u) {
        let idx_p = idx - n_beacons;
        let beacon_id = select(0u, idx_p % 2u, arch == 3u);
        var age = st.p.z + dt;
        let life = max(st.p.w, 1.2);
        var pos = st.p.xy;
        var vel = st.v.xy;
        let eddy_seed = st.v.z;

        let off_screen = pos.x < 0.015 * a || pos.x > 0.985 * a || pos.y < 0.03 || pos.y > 0.97;
        if (age >= life || off_screen) {
            age = age % life;
            pos = anemo_beacon(arch, beacon_id, gen, phase, a);
            let h_re = hash22(vec2<f32>(f32(idx) * 3.1 + floor(phase * 4.0), g.seed * 73.0));
            pos = pos + (h_re - 0.5) * 0.016;
            vel = anemo_wind(arch, pos, gen, phase, a);
        } else {
            let w_loc = anemo_wind(arch, pos, gen, phase, a);
            let turb = vec2<f32>(
                sin(pos.y * 12.0 + phase * 2.4 + eddy_seed * TAU) * 0.08,
                cos(pos.x * 7.5 - phase * 2.0 + eddy_seed * 9.0) * 0.14,
            );
            vel = mix(vel, w_loc + turb, 1.0 - exp(-4.8 * dt));
            pos = pos + vel * dt;
        }

        var next_st = st;
        next_st.p = vec4<f32>(pos, age, life);
        next_st.v = vec4<f32>(vel, eddy_seed, 1.0);
        particles[idx] = next_st;

        let u_age = clamp(age / life, 0.0, 1.0);
        let puff_env = smoothstep(0.0, 0.05, u_age) * pow(1.0 - u_age, 0.60);
        let puff_r = mix(0.018, 0.044, u_age);
        let puff_bright = 0.46 * puff_env;
        let puff_scent = 0.65 * (1.0 - u_age * 0.50);
        splat_puff(pos, puff_r, st.c.rgb, puff_scent, puff_bright, env, a);
        return;
    }

    if (role == 2u) {
        var age = st.p.z + dt;
        let life = max(st.p.w, 1.2);
        var pos = st.p.xy;
        let p_prev = pos;
        var vel = anemo_wind(arch, pos, gen, phase, a);

        let off_screen = pos.x < 0.02 * a || pos.x > 0.98 * a || pos.y < 0.04 || pos.y > 0.96;
        if (age >= life || off_screen) {
            let h_m = hash22(vec2<f32>(f32(idx) * 5.7 + floor(phase * 3.0), g.seed * 61.0));
            let sgn = anemo_wind_sign(gen);
            pos = select(
                vec2<f32>(mix(0.06 * a, 0.94 * a, h_m.x), mix(0.07, 0.93, h_m.y)),
                vec2<f32>(select(0.06 * a, 0.94 * a, sgn < 0.0), mix(0.07, 0.93, h_m.y)),
                arch == 1u && h_m.x < 0.5,
            );
            vel = anemo_wind(arch, pos, gen, phase, a);
            age = 0.0;
            particles[idx] = Particle(vec4<f32>(pos, age, life), vec4<f32>(vel, st.v.z, 2.0), st.c);
            return;
        }
        pos = pos + vel * dt;
        particles[idx] = Particle(vec4<f32>(pos, age, life), vec4<f32>(vel, st.v.z, 2.0), st.c);

        let u_age = clamp(age / life, 0.0, 1.0);
        let mote_env = env * sin(u_age * PI);
        splat_trail_seg(p_prev, pos, 0.0024, st.c.rgb, 0.0, 0.14, mote_env, a);
        return;
    }

    // --- role == 3u: Olfactory Seeker Moth roaming the full open canvas ---
    var pos = st.p.xy;
    let p_prev = pos;
    var vel = st.v.xy;
    var mode_t = st.p.z;
    var cast_phase = st.p.w;
    var flash = st.v.z * exp(-dt * 3.2);

    let w_loc = anemo_wind(arch, pos, gen, phase, a);
    let w_hat = safe_norm2(w_loc, vec2<f32>(-1.0, 0.0));
    let c_hat = vec2<f32>(-w_hat.y, w_hat.x);

    let ant_span = 0.036;
    let s_c = state_sample(state_uv(vec2<f32>(clamp(pos.x, 0.01 * a, 0.99 * a), clamp(pos.y, 0.02, 0.98)))).a;
    let p_l = pos + c_hat * ant_span;
    let p_r = pos - c_hat * ant_span;
    let s_l = state_sample(state_uv(vec2<f32>(clamp(p_l.x, 0.01 * a, 0.99 * a), clamp(p_l.y, 0.02, 0.98)))).a;
    let s_r = state_sample(state_uv(vec2<f32>(clamp(p_r.x, 0.01 * a, 0.99 * a), clamp(p_r.y, 0.02, 0.98)))).a;
    let scent_max = max(s_c, max(s_l, s_r));

    if (scent_max > 0.035) {
        mode_t = 0.22;
        flash = max(flash, clamp(scent_max * 1.45, 0.52, 1.0));
    }

    let b0 = anemo_beacon(arch, 0u, gen, phase, a);
    let b1 = anemo_beacon(arch, 1u, gen, phase, a);
    let d0 = length(pos - b0);
    let d1 = select(1e5, length(pos - b1), arch == 3u);
    let near_b = select(b0, b1, d1 < d0);
    let d_near = min(d0, d1);

    var target_v = vel;
    if (mode_t > 0.0) {
        mode_t = max(mode_t - dt, 0.0);
        let grad = clamp((s_l - s_r) * 14.0, -0.75, 0.75);
        var surge_dir = safe_norm2(-w_hat + c_hat * grad, -w_hat);
        if (d_near < 0.30) {
            let to_b = safe_norm2(near_b - pos, surge_dir);
            surge_dir = safe_norm2(mix(surge_dir, to_b, smoothstep(0.30, 0.06, d_near)), to_b);
        }
        target_v = surge_dir * 0.92;
    } else {
        // Gentle downwind search drift keeps casting seekers spread evenly across the full canvas!
        let cast_age = -mode_t;
        mode_t = mode_t - dt;
        let cast_freq = 7.0 + 1.6 * hash11(f32(idx) * 7.1 + g.seed * 19.0);
        cast_phase = (cast_phase + cast_freq * dt) % TAU;
        let zig = tanh(sin(cast_phase) * 2.8);
        let cross_amp = mix(0.46, 0.74, clamp(cast_age / 2.6, 0.0, 1.0));
        let along_v = w_hat * mix(0.14, 0.28, clamp(cast_age / 3.0, 0.0, 1.0));
        target_v = c_hat * (zig * cross_amp) + along_v;
    }

    let k_turn = select(7.5, 11.5, mode_t > 0.0);
    vel = mix(vel, target_v, 1.0 - exp(-k_turn * dt));
    vel = clamp_len2(vel, 0.38, 1.12);
    pos = pos + vel * dt;

    let sgn = anemo_wind_sign(gen);
    let passed_upwind = (arch == 1u) && ((pos.x - b0.x) * sgn < 0.015 * a);
    let d0_after = length(pos - b0);
    let d1_after = select(1e5, length(pos - b1), arch == 3u);
    let captured = min(d0_after, d1_after) < 0.056;
    let exited_downwind = pos.x < 0.02 * a || pos.x > 0.98 * a;

    // Bounce cleanly off top/bottom monitor edges.
    if (pos.y < 0.04 || pos.y > 0.96) {
        pos.y = clamp(pos.y, 0.04, 0.96);
        vel.y = -vel.y;
    }

    if (captured) {
        let cap_col = mix(wisp_palette(pal_id, 3u), vec3<f32>(1.0, 0.98, 0.92), 0.55);
        splat_puff(pos, 0.018, cap_col, 0.0, 0.58, env, a);
    }

    if (captured || passed_upwind || exited_downwind) {
        let h_re = hash22(vec2<f32>(f32(idx) * 7.3 + phase * 11.7, g.seed * 89.0));
        let new_pos = select(
            vec2<f32>(mix(0.08 * a, 0.92 * a, h_re.x), mix(0.08, 0.92, h_re.y)),
            vec2<f32>(
                select(mix(0.28 * a, 0.93 * a, h_re.x), mix(0.07 * a, 0.72 * a, h_re.x), sgn < 0.0),
                mix(0.08, 0.92, h_re.y),
            ),
            arch == 1u,
        );
        let nw = safe_norm2(anemo_wind(arch, new_pos, gen, phase, a), vec2<f32>(-1.0, 0.0));
        let nc = vec2<f32>(-nw.y, nw.x);
        let n_phase = h_re.y * TAU;
        particles[idx] = Particle(
            vec4<f32>(new_pos, -0.2, n_phase),
            vec4<f32>(nc * (0.54 * sin(n_phase)) + nw * 0.14, 0.0, 3.0),
            st.c,
        );
        return;
    }

    var next_st: Particle;
    next_st.p = vec4<f32>(pos, mode_t, cast_phase);
    next_st.v = vec4<f32>(vel, clamp(flash, 0.0, 1.0), 3.0);
    next_st.c = st.c;
    particles[idx] = next_st;

    let cast_col = wisp_palette(pal_id, 2u);
    let surge_col = mix(wisp_palette(pal_id, 3u), vec3<f32>(1.00, 0.97, 0.90), 0.34);
    let trail_col = mix(cast_col, surge_col, flash);
    let width_w = mix(0.0040, 0.0070, flash);
    let bright = mix(0.29, 0.80, flash);
    splat_trail_seg(p_prev, pos, width_w, trail_col, 0.0, bright, env, a);
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
        // Keep visual filaments crisp while letting the invisible pheromone scent field (.a) diffuse smoothly.
        let diff_rgb = clamp(g.dt * 2.4, 0.0, 0.07);
        let diff_scent = clamp(g.dt * 9.0, 0.0, 0.26);
        prev = vec4<f32>(
            mix(prev.rgb, blur.rgb, diff_rgb),
            mix(prev.a, blur.a, diff_scent),
        );
    }

    // Visual trails decay rapidly via g.fade (~0.56s); scent field (.a) lingers ~4x longer for seekers.
    let scent_fade = pow(clamp(g.fade, 0.0, 1.0), 0.25);
    let next_rgb = clamp(prev.rgb * g.fade + splat.rgb, vec3<f32>(0.0), vec3<f32>(6.0));
    let next_a = clamp(prev.a * scent_fade + splat.a, 0.0, 2.5);
    return vec4<f32>(next_rgb, next_a);
}

fn hack(p: vec2<f32>, _t: f32) -> vec3<f32> {
    let uv = state_uv(p);
    let s = state_sample(uv).rgb;
    let d = state_texel();

    let h_card = state_sample(uv + vec2<f32>(d.x * 1.4, 0.0)).rgb
        + state_sample(uv - vec2<f32>(d.x * 1.4, 0.0)).rgb
        + state_sample(uv + vec2<f32>(0.0, d.y * 1.4)).rgb
        + state_sample(uv - vec2<f32>(0.0, d.y * 1.4)).rgb;
    let h_diag = state_sample(uv + vec2<f32>(d.x * 2.5, d.y * 2.5)).rgb
        + state_sample(uv + vec2<f32>(-d.x * 2.5, d.y * 2.5)).rgb
        + state_sample(uv + vec2<f32>(d.x * 2.5, -d.y * 2.5)).rgb
        + state_sample(uv + vec2<f32>(-d.x * 2.5, -d.y * 2.5)).rgb;
    let halo = (h_card + h_diag) * 0.125;

    let raw_rgb = max(s + halo * 0.20, vec3<f32>(0.0));
    let peak_c = max(raw_rgb.r, max(raw_rgb.g, raw_rgb.b));
    if (peak_c <= 1e-4) {
        return vec3<f32>(0.0);
    }

    // Chromaticity-preserving exponential tone mapping + subtle X-ray double-exposure core lift.
    let mapped_lum = 1.0 - exp(-peak_c * 1.40);
    let base_col = raw_rgb * (mapped_lum / max(peak_c, 1e-4));
    let xray_core = smoothstep(0.75, 2.50, peak_c) * 0.22;
    let out_col = mix(base_col, vec3<f32>(0.92, 0.97, 1.00), xray_core);
    return clamp(out_col, vec3<f32>(0.0), vec3<f32>(1.0));
}

// Flame Veil: sweeping Electric Sheep fractal flames and delicate IFS lace
// floating across a unified stationary full-canvas field on Tier P compute
// particles and Tier S feedback textures.
// After xscreensaver's Flame (Scott Draves, 1992; Patrick Naughton, 1991) and
// IFS (Pascal Massimino, 1997).
//
// Particle buffer layout (`particles[idx]`):
//   p.xy = local attractor coordinates
//   p.z  = structural color coordinate in [0.0, 1.0]
//   p.w  = 24-bit integer RNG state stored exactly in f32

const STAGE_SECS: f32 = 28.0;
const PALETTE_SECS: f32 = 22.0;

// Four curated 4-stop Electric Sheep palettes (no rainbow mud inside a single frame).
fn palette_ramp(idx: u32, x: f32) -> vec3<f32> {
    let t = clamp(x, 0.0, 1.0);
    var c0 = vec3<f32>(0.08, 0.10, 0.38);
    var c1 = vec3<f32>(0.14, 0.36, 0.88);
    var c2 = vec3<f32>(0.14, 0.82, 0.96);
    var c3 = vec3<f32>(0.72, 0.94, 1.00);
    if (idx == 1u) {
        // Solar Corona: deep crimson -> vermilion -> molten gold -> warm champagne
        c0 = vec3<f32>(0.42, 0.06, 0.12);
        c1 = vec3<f32>(0.88, 0.24, 0.12);
        c2 = vec3<f32>(0.98, 0.68, 0.18);
        c3 = vec3<f32>(1.00, 0.92, 0.72);
    } else if (idx == 2u) {
        // Orchid Aurora: dark plum -> royal amethyst -> magenta rose -> pearl-peach
        c0 = vec3<f32>(0.24, 0.06, 0.38);
        c1 = vec3<f32>(0.56, 0.22, 0.88);
        c2 = vec3<f32>(0.94, 0.34, 0.66);
        c3 = vec3<f32>(1.00, 0.82, 0.86);
    } else if (idx == 3u) {
        // Bioluminescent Lagoon: abyssal teal -> emerald jade -> aquamarine -> frost mint
        c0 = vec3<f32>(0.04, 0.24, 0.30);
        c1 = vec3<f32>(0.08, 0.68, 0.56);
        c2 = vec3<f32>(0.24, 0.92, 0.74);
        c3 = vec3<f32>(0.78, 1.00, 0.92);
    }
    let s = t * 3.0;
    if (s < 1.0) {
        return mix(c0, c1, smoothstep(0.0, 1.0, s));
    }
    if (s < 2.0) {
        return mix(c1, c2, smoothstep(0.0, 1.0, s - 1.0));
    }
    return mix(c2, c3, smoothstep(0.0, 1.0, s - 2.0));
}

fn flame_palette(c_idx: f32, t: f32) -> vec3<f32> {
    let p_stage = t / PALETTE_SECS + g.seed * 4.0;
    let p0 = u32(floor(p_stage)) % 4u;
    let p1 = (p0 + 1u) % 4u;
    let blend = smoothstep(0.80, 1.0, fract(p_stage));
    let a = palette_ramp(p0, c_idx);
    if (blend <= 0.001) {
        return a;
    }
    return mix(a, palette_ramp(p1, c_idx), blend);
}

fn affine2(q: vec2<f32>, angle: f32, sx: f32, sy: f32, shear: f32, tr: vec2<f32>) -> vec2<f32> {
    let c = cos(angle);
    let s = sin(angle);
    let x = q.x * sx + q.y * shear;
    let y = q.y * sy;
    return vec2<f32>(c * x - s * y, s * x + c * y) + tr;
}

fn rot_pt(q: vec2<f32>, angle: f32) -> vec2<f32> {
    let c = cos(angle);
    let s = sin(angle);
    return vec2<f32>(c * q.x - s * q.y, s * q.x + c * q.y);
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

// --- Signature Electric Sheep & Apophysis variations ---

fn var_spherical(a: vec2<f32>, reg: f32) -> vec2<f32> {
    return a / (dot(a, a) + reg);
}

fn var_julian(a: vec2<f32>, power: f32, dist: f32, rng: ptr<function, u32>) -> vec2<f32> {
    let r = max(length(a), 1e-4);
    let th = atan2(a.y, a.x);
    let k = floor(rng_f32(rng) * power);
    let ang = (th + TAU * k) / power;
    let rp = pow(r, dist / power);
    return rp * vec2<f32>(cos(ang), sin(ang));
}

fn var_splits(a: vec2<f32>, split: vec2<f32>) -> vec2<f32> {
    let sx = select(-split.x, split.x, a.x >= 0.0);
    let sy = select(-split.y, split.y, a.y >= 0.0);
    return a + vec2<f32>(sx, sy);
}

fn var_elliptic(a: vec2<f32>) -> vec2<f32> {
    let tmp = dot(a, a) + 1.0;
    let x2 = 2.0 * a.x;
    let xmax = 0.5 * (sqrt(max(tmp + x2, 0.0)) + sqrt(max(tmp - x2, 0.0)));
    let b = max(xmax, 1.0);
    let rx = asin(clamp(a.x / b, -1.0, 1.0)) * (2.0 / PI);
    let ry = log(b + sqrt(max(b * b - 1.0, 0.0))) * (2.0 / PI) * select(-1.0, 1.0, a.y >= 0.0);
    return vec2<f32>(rx, ry);
}

fn iter_flame(
    q_in: vec2<f32>,
    c_in: ptr<function, f32>,
    arch: u32,
    t: f32,
    wide: f32,
    rng: ptr<function, u32>,
) -> vec2<f32> {
    let u = rng_f32(rng);
    let w = t * 0.45 + g.seed * 6.0;

    if (arch == 0u) {
        // Grand Julian Lace: 1:1 isotropic Electric Sheep Linear + Julian + Spherical chain.
        if (u < 0.48) {
            let a = affine2(
                q_in,
                0.26 + 0.16 * sin(w * 0.7),
                0.84,
                0.82,
                0.04 * cos(w * 0.5),
                vec2<f32>(0.34 * cos(w * 0.4) + 0.42 * wide, 0.18 * sin(w * 0.5)),
            );
            *c_in = 0.5 * (*c_in + 0.88);
            return a;
        }
        if (u < 0.76) {
            let a = affine2(
                q_in,
                -0.42 + 0.18 * cos(w * 0.6),
                0.72,
                0.70,
                0.0,
                vec2<f32>(0.68 + 0.48 * wide + 0.08 * sin(w * 0.35), 0.16 * sin(w * 0.45)),
            );
            *c_in = 0.5 * (*c_in + 0.42);
            return var_julian(a, 3.0, 0.85, rng);
        }
        if (u < 0.86) {
            let a = affine2(
                q_in,
                1.25 + 0.16 * sin(w * 0.5),
                0.58,
                0.58,
                0.0,
                vec2<f32>(-0.52 - 0.44 * wide + 0.08 * sin(w * 0.4), 0.22 * cos(w * 0.45)),
            );
            *c_in = 0.5 * (*c_in + 0.12);
            return var_spherical(a, 0.08);
        }
        let sym_folds = select(3.0, 2.0, wide > 0.35);
        let k = 1.0 + floor(rng_f32(rng) * (sym_folds - 0.01));
        return rot_pt(q_in, k * (TAU / sym_folds));
    }

    if (arch == 1u) {
        // Splits + Elliptic Cathedral: confocal hyperbolic arches and luminous eyes.
        if (u < 0.50) {
            let a = affine2(
                q_in,
                0.08 * sin(w * 0.7),
                0.86,
                0.84,
                0.04 * cos(w * 0.5),
                vec2<f32>(0.10 * cos(w * 0.45), 0.08 * sin(w * 0.38)),
            );
            let split = vec2<f32>(0.44 + 0.40 * wide + 0.14 * sin(w * 0.6), 0.08 + 0.05 * cos(w * 0.5));
            *c_in = 0.5 * (*c_in + 0.84);
            return var_splits(a, split);
        }
        if (u < 0.92) {
            let a = affine2(
                q_in,
                1.5707963 + 0.16 * sin(w * 0.5),
                0.90,
                0.90,
                0.0,
                vec2<f32>(0.10 * cos(w * 0.4), 0.06 * sin(w * 0.5)),
            );
            *c_in = 0.5 * (*c_in + 0.24);
            return var_elliptic(a);
        }
        let a = affine2(
            q_in,
            -0.35 + 0.15 * cos(w * 0.5),
            0.52,
            0.52,
            0.0,
            vec2<f32>(0.35 + 0.35 * wide + 0.07 * sin(w * 0.4), 0.06 * cos(w * 0.5)),
        );
        *c_in = 0.5 * (*c_in + 0.58);
        return var_spherical(a, 0.10);
    }

    if (arch == 2u) {
        // Double Mobius Spiral: sweeping twin 1:1 logarithmic vortices with spherical inversion.
        if (u < 0.72) {
            let a = affine2(
                q_in,
                0.24 + 0.09 * sin(w * 0.5),
                0.88,
                0.86,
                0.03 * cos(w * 0.4),
                vec2<f32>(0.14 + 0.14 * wide + 0.06 * cos(w * 0.48), 0.04 + 0.06 * sin(w * 0.42)),
            );
            *c_in = 0.5 * (*c_in + 0.86);
            return a;
        }
        if (u < 0.92) {
            let a = affine2(
                q_in,
                -1.20 + 0.18 * cos(w * 0.4),
                0.52,
                0.52,
                0.0,
                vec2<f32>(0.62 + 0.44 * wide + 0.08 * cos(w * 0.4), 0.14 * sin(w * 0.5)),
            );
            *c_in = 0.5 * (*c_in + 0.18);
            return var_spherical(a, 0.06);
        }
        return -q_in;
    }

    // Feathery IFS Silk Plume (after Pascal Massimino's ifs.c): low-dimension contractive lace.
    if (u < 0.62) {
        let a = affine2(
            q_in,
            0.19 + 0.12 * sin(w * 0.55),
            0.80,
            0.78,
            0.04 * cos(w * 0.4),
            vec2<f32>(0.24 + 0.22 * wide + 0.06 * cos(w * 0.5), 0.04 + 0.06 * sin(w * 0.42)),
        );
        *c_in = 0.5 * (*c_in + 0.86);
        return a;
    }
    if (u < 0.77) {
        let a = affine2(
            q_in,
            1.05 + 0.22 * cos(w * 0.5),
            0.34,
            0.32,
            0.0,
            vec2<f32>(-0.36 - 0.16 * wide + 0.05 * sin(w * 0.45), 0.34 + 0.04 * cos(w * 0.4)),
        );
        *c_in = 0.5 * (*c_in + 0.36);
        return a;
    }
    if (u < 0.92) {
        let a = affine2(
            q_in,
            -1.10 + 0.20 * sin(w * 0.45),
            0.33,
            -0.31,
            0.0,
            vec2<f32>(-0.28 - 0.14 * wide + 0.05 * cos(w * 0.42), -0.32 + 0.04 * sin(w * 0.38)),
        );
        *c_in = 0.5 * (*c_in + 0.14);
        return a;
    }
    return -q_in;
}

fn stage_center(stage_id: u32, phase: f32, a: f32) -> vec2<f32> {
    let fs = f32(stage_id);
    let h = hash22(vec2<f32>(fs * 19.3 + g.seed * 53.0, fs * 7.1 + 3.7));
    let seed_v = vec2<f32>(fs * 31.7 + g.seed * 67.0, fs * 11.3 + 5.9);
    let x_lo = clamp(0.18 * a, 0.28, 0.62);
    let x_hi = a - x_lo;
    let y_lo = 0.26;
    let y_hi = 0.74;
    let p1_init = vec2<f32>(mix(x_lo, x_hi, h.x), mix(y_lo, y_hi, h.y));
    let speed = 0.20;
    let d_min = 0.26;
    let d_max = 0.44;

    var p1 = p1_init;
    let w1 = next_iso_wp(p1, h.x * TAU, 1u, seed_v, x_lo, x_hi, y_lo, y_hi, d_min, d_max);
    var p2 = w1.xy;
    let w2 = next_iso_wp(p2, w1.z, 2u, seed_v, x_lo, x_hi, y_lo, y_hi, d_min, d_max);
    var p3 = w2.xy;
    var cur_ang = w2.z;
    var p0 = p1 - (p2 - p1);
    var t_acc = 0.0;

    for (var k = 0u; k < 32u; k = k + 1u) {
        let seg_dur = max(length(p2 - p1) / speed, 0.35);
        if (phase <= t_acc + seg_dur || k == 31u) {
            let u = clamp((phase - t_acc) / seg_dur, 0.0, 1.0);
            let pos = catmull_rom2(p0, p1, p2, p3, u);
            return vec2<f32>(clamp(pos.x, x_lo - 0.04, x_hi + 0.04), clamp(pos.y, y_lo - 0.03, y_hi + 0.03));
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

fn stage_scale(stage_id: u32, arch: u32, t: f32) -> vec2<f32> {
    let s_base = select(0.46, 0.55, arch == 3u);
    let s = s_base * (1.0 + 0.07 * sin(t * 0.17 + f32(stage_id)));
    return vec2<f32>(s, s);
}

fn stage_tilt(stage_id: u32, arch: u32, t: f32) -> f32 {
    let spin_dir = select(-1.0, 1.0, (stage_id % 2u) == 0u);
    if (arch == 0u) {
        return t * 0.18 * spin_dir + f32(stage_id) * 1.1 + g.seed * TAU;
    }
    return 0.32 * sin(t * 0.18 * spin_dir + f32(stage_id) * 1.1 + g.seed * TAU);
}

fn step_particle(idx: u32, t: f32) {
    let a = aspect();
    let wide = clamp((a - 1.78) / 1.78, 0.0, 1.0);
    let dims = splat_dims();
    let texels = f32(dims.x * dims.y);

    let stage_raw = t / STAGE_SECS + g.seed * 2.0;
    let stage_id = u32(max(floor(stage_raw), 0.0));
    let phase = (stage_raw - f32(stage_id)) * STAGE_SECS;
    let arch = (stage_id + u32(g.seed * 7.0)) % 4u;
    let fstage = fract(stage_raw);
    let breath = smoothstep(0.0, 0.05, fstage) * (1.0 - smoothstep(0.95, 1.0, fstage));

    var state = particles[idx];
    var q = state.p.xy;
    var c_idx = state.p.z;
    var rng = rng_step(
        u32(state.p.w)
            ^ (idx * 747796405u + u32(g.frame) * 1664525u + u32(g.seed * 65536.0) + 1u),
    );

    if (g.frame < 0.5 || !all(q == q) || dot(q, q) > 25.0) {
        q = vec2<f32>(rng_f32(&rng) * 2.0 - 1.0, rng_f32(&rng) * 2.0 - 1.0);
        c_idx = rng_f32(&rng);
        for (var warm = 0; warm < 20; warm = warm + 1) {
            q = iter_flame(q, &c_idx, arch, t, wide, &rng);
        }
    }

    let center = stage_center(stage_id, phase, a);
    let scale = stage_scale(stage_id, arch, t);
    let tilt = stage_tilt(stage_id, arch, t);

    let iters = clamp(i32(round(texels / 21600.0)), 4, 48);
    let w_splat = max(1.0 - g.fade, 0.002)
        * texels
        / (f32(particle_count()) * f32(iters))
        * breath;

    if (w_splat <= 1e-6) {
        particles[idx].p = vec4<f32>(q, c_idx, f32(rng & 0x00ffffffu));
        return;
    }

    for (var k = 0; k < iters; k = k + 1) {
        q = iter_flame(q, &c_idx, arch, t, wide, &rng);
        if (!all(q == q) || dot(q, q) > 25.0) {
            q = vec2<f32>(rng_f32(&rng) * 2.0 - 1.0, rng_f32(&rng) * 2.0 - 1.0);
            continue;
        }
        if (k < 4 && g.frame < 0.5) {
            continue;
        }
        let r2 = dot(q, q);
        let q_framed = q / (1.0 + 0.032 * r2);
        let qr = rot_pt(q_framed, tilt);
        let p_world = center + qr * scale;
        if (p_world.x < 0.0 || p_world.x > a || p_world.y < 0.0 || p_world.y > 1.0) {
            continue;
        }
        let edge = smoothstep(0.02, 0.08, p_world.x)
            * (1.0 - smoothstep(a - 0.08, a - 0.02, p_world.x))
            * smoothstep(0.02, 0.08, p_world.y)
            * (1.0 - smoothstep(0.92, 0.98, p_world.y));
        if (edge <= 0.002) {
            continue;
        }
        let col = flame_palette(clamp(c_idx, 0.0, 1.0), t);
        let w_pt = w_splat * edge;
        splat_point(p_world, col * w_pt, w_pt);
    }

    particles[idx].p = vec4<f32>(q, c_idx, f32(rng & 0x00ffffffu));
}

fn resolve_state(uv: vec2<f32>, p: vec2<f32>, t: f32, splat: vec4<f32>) -> vec4<f32> {
    let a = aspect();
    let t_prev = max(t - g.dt, 0.0);
    let raw_now = t / STAGE_SECS + g.seed * 2.0;
    let raw_prev = t_prev / STAGE_SECS + g.seed * 2.0;
    let stage_now = u32(max(floor(raw_now), 0.0));
    let stage_prev = u32(max(floor(raw_prev), 0.0));
    if (g.frame < 0.5 || stage_now != stage_prev) {
        return state_sample(uv) * g.fade + splat;
    }
    let phase_now = (raw_now - f32(stage_now)) * STAGE_SECS;
    let phase_prev = (raw_prev - f32(stage_now)) * STAGE_SECS;
    let arch = (stage_now + u32(g.seed * 7.0)) % 4u;
    let c_now = stage_center(stage_now, phase_now, a);
    let c_prev = stage_center(stage_now, phase_prev, a);
    let s_now = stage_scale(stage_now, arch, t);
    let s_prev = stage_scale(stage_now, arch, t_prev);
    let tilt_now = stage_tilt(stage_now, arch, t);
    let tilt_prev = stage_tilt(stage_now, arch, t_prev);

    let qr_now = (p - c_now) / s_now;
    let qr_prev = rot_pt(qr_now, tilt_prev - tilt_now);
    let p_prev = c_prev + qr_prev * s_prev;
    let uv_prev = state_uv(p_prev);

    var prev = vec4<f32>(0.0);
    if (uv_prev.x > 0.002 && uv_prev.x < 0.998 && uv_prev.y > 0.002 && uv_prev.y < 0.998) {
        prev = state_sample(uv_prev) * g.fade;
    }
    return prev + splat;
}

fn hack(p: vec2<f32>, _t: f32) -> vec3<f32> {
    let uv = state_uv(p);
    let s = state_sample(uv);
    let d = state_texel();

    // Tight caustic bloom halo active only around bright filament intersections.
    let h_card = state_sample(uv + vec2<f32>(d.x * 1.5, 0.0))
        + state_sample(uv - vec2<f32>(d.x * 1.5, 0.0))
        + state_sample(uv + vec2<f32>(0.0, d.y * 1.5))
        + state_sample(uv - vec2<f32>(0.0, d.y * 1.5));
    let h_diag = state_sample(uv + vec2<f32>(d.x * 2.5, d.y * 2.5))
        + state_sample(uv + vec2<f32>(-d.x * 2.5, d.y * 2.5))
        + state_sample(uv + vec2<f32>(d.x * 2.5, -d.y * 2.5))
        + state_sample(uv + vec2<f32>(-d.x * 2.5, -d.y * 2.5));
    let halo = (h_card + h_diag) * 0.125;

    let caustic_halo = halo.a * 0.24 * smoothstep(1.4, 10.0, halo.a);
    let density = max(s.a + caustic_halo, 0.0);
    if (density <= 1e-4) {
        return vec3<f32>(0.0);
    }

    // High-contrast Draves log-density curve tuned for unified full-canvas density.
    let alpha = log(1.0 + 2.85 * density) / log(1.0 + 2.85 * 14.5);
    let lum = pow(clamp(alpha, 0.0, 1.0), 1.14);

    var base_col = s.rgb / max(s.a, 1e-4);
    let halo_col = halo.rgb / max(halo.a, 1e-4);
    let col_weight = clamp(s.a / max(s.a + halo.a * 0.25, 1e-4), 0.0, 1.0);
    base_col = mix(halo_col, base_col, col_weight);

    let sat_col = pow(max(base_col, vec3<f32>(0.0)), vec3<f32>(1.12));
    let peak_glow = smoothstep(0.56, 1.0, lum) * 0.48;
    let incand = mix(sat_col, vec3<f32>(1.0), 0.55);
    let out_col = sat_col * lum + incand * peak_glow;
    return clamp(out_col, vec3<f32>(0.0), vec3<f32>(1.0));
}

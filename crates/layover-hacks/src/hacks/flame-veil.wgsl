// Flame Veil: sweeping Electric Sheep fractal flames and delicate IFS lace
// drifting across the dark on Tier P compute particles and advected Tier S
// feedback textures.
// After xscreensaver's Flame (Scott Draves, 1992; Patrick Naughton, 1991) and
// IFS (Pascal Massimino, 1997).
//
// Particle buffer layout (`particles[idx]`):
//   p.xy = local attractor coordinates
//   p.z  = structural color coordinate in [0.0, 1.0]
//   p.w  = 24-bit integer RNG state stored exactly in f32

const DRIFT_VX: f32 = 0.115;
const DRIFT_VY: f32 = 0.028;
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
    ensemble: u32,
    t: f32,
    rng: ptr<function, u32>,
) -> vec2<f32> {
    let fe = f32(ensemble);
    let u = rng_f32(rng);
    let w = t * 0.24 + fe * 1.9 + g.seed * 6.0;

    if (arch == 0u) {
        // Grand Julian Lace: Electric Sheep Linear + Julian + Spherical with 3-fold symmetry.
        if (u < 0.48) {
            let a = affine2(
                q_in,
                0.26 + 0.14 * sin(w * 0.7),
                0.84,
                0.82,
                0.04 * cos(w * 0.5),
                vec2<f32>(0.34 * cos(w * 0.4), 0.16 * sin(w * 0.5)),
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
                vec2<f32>(0.68, 0.14 * sin(w * 0.4)),
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
                vec2<f32>(-0.52, 0.22 * cos(w * 0.4)),
            );
            *c_in = 0.5 * (*c_in + 0.12);
            return var_spherical(a, 0.08);
        }
        // Color-preserving 3-fold rotational symmetry inside the IFS loop.
        let k = 1.0 + floor(rng_f32(rng) * 2.0);
        return rot_pt(q_in, k * (TAU / 3.0));
    }

    if (arch == 1u) {
        // Splits + Elliptic Cathedral: confocal hyperbolic arches and luminous eyes.
        if (u < 0.50) {
            let a = affine2(
                q_in,
                0.06 * sin(w * 0.7),
                0.86,
                0.84,
                0.03 * cos(w * 0.5),
                vec2<f32>(0.0, 0.04 * sin(w * 0.4)),
            );
            let split = vec2<f32>(0.44 + 0.14 * sin(w * 0.6), 0.08 + 0.05 * cos(w * 0.5));
            *c_in = 0.5 * (*c_in + 0.84);
            return var_splits(a, split);
        }
        if (u < 0.92) {
            let a = affine2(
                q_in,
                1.5707963 + 0.14 * sin(w * 0.5),
                0.90,
                0.90,
                0.0,
                vec2<f32>(0.06 * cos(w * 0.4), 0.0),
            );
            *c_in = 0.5 * (*c_in + 0.24);
            return var_elliptic(a);
        }
        let a = affine2(q_in, -0.35 + 0.15 * cos(w * 0.5), 0.52, 0.52, 0.0, vec2<f32>(0.35, 0.0));
        *c_in = 0.5 * (*c_in + 0.58);
        return var_spherical(a, 0.10);
    }

    if (arch == 2u) {
        // Double Mobius Spiral: sweeping twin logarithmic vortices with spherical inversion.
        if (u < 0.72) {
            let a = affine2(
                q_in,
                0.24 + 0.08 * sin(w * 0.5),
                0.88,
                0.86,
                0.02 * cos(w * 0.4),
                vec2<f32>(0.14, 0.04),
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
                vec2<f32>(0.62, 0.12 * sin(w * 0.5)),
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
            0.19 + 0.11 * sin(w * 0.55),
            0.80,
            0.78,
            0.04 * cos(w * 0.4),
            vec2<f32>(0.24, 0.04),
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
            vec2<f32>(-0.36, 0.34),
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
            vec2<f32>(-0.28, -0.32),
        );
        *c_in = 0.5 * (*c_in + 0.14);
        return a;
    }
    return -q_in;
}

fn step_particle(idx: u32, t: f32) {
    let a = aspect();
    let n_flames = select(2u, 1u, a < 2.4);
    let ensemble = idx % n_flames;
    let fe = f32(ensemble);
    let dims = splat_dims();
    let texels = f32(dims.x * dims.y);

    let stage_raw = t / STAGE_SECS + fe * 0.5 + g.seed * 2.0;
    let arch = u32(floor(stage_raw)) % 4u;
    let fstage = fract(stage_raw);
    let breath = smoothstep(0.0, 0.06, fstage) * (1.0 - smoothstep(0.94, 1.0, fstage));

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
            q = iter_flame(q, &c_idx, arch, ensemble, t, &rng);
        }
    }

    // Drift lockstep with `resolve_state` advection so filaments stay razor sharp with zero smear.
    let x0 = (fe + 0.5) / f32(n_flames) * a + 0.12 * a * g.seed;
    let y0 = fract(0.32 + fe * 0.5 + g.seed * 0.37);
    let center = vec2<f32>(
        fract((x0 + DRIFT_VX * t) / a) * a,
        fract(y0 + DRIFT_VY * t),
    );
    let scale = vec2<f32>(
        0.55 + 0.05 * sin(t * 0.11 + fe * 2.1),
        0.40 + 0.04 * cos(t * 0.09 + fe * 1.7),
    ) * select(1.0, 1.30, arch == 3u);
    let tilt = 0.22 * sin(t * 0.045 + fe * 1.4) + fe * 0.65;
    let cs = cos(tilt);
    let ss = sin(tilt);

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
        q = iter_flame(q, &c_idx, arch, ensemble, t, &rng);
        if (!all(q == q) || dot(q, q) > 25.0) {
            q = vec2<f32>(rng_f32(&rng) * 2.0 - 1.0, rng_f32(&rng) * 2.0 - 1.0);
            continue;
        }
        if (k < 4 && g.frame < 0.5) {
            continue;
        }
        // Soft hyperbolic framing keeps runaway tails inside the screen gracefully without clipping.
        let r2 = dot(q, q);
        let q_framed = q / (1.0 + 0.08 * r2);
        let qr = vec2<f32>(q_framed.x * cs - q_framed.y * ss, q_framed.x * ss + q_framed.y * cs);
        let p_world = center + qr * scale;
        let col = flame_palette(clamp(c_idx + 0.08 * fe, 0.0, 1.0), t);
        splat_point_wrap(p_world, col * w_splat, w_splat);
    }

    particles[idx].p = vec4<f32>(q, c_idx, f32(rng & 0x00ffffffu));
}

fn resolve_state(uv: vec2<f32>, _p: vec2<f32>, _t: f32, splat: vec4<f32>) -> vec4<f32> {
    let duv = vec2<f32>(DRIFT_VX * g.dt / aspect(), -DRIFT_VY * g.dt);
    return state_sample(uv - duv) * g.fade + splat;
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

    let caustic_halo = halo.a * 0.22 * smoothstep(2.0, 14.0, halo.a);
    let density = max(s.a + caustic_halo, 0.0);
    if (density <= 1e-4) {
        return vec3<f32>(0.0);
    }

    // High-contrast Draves log-density curve: gossamer tails, jewel ribbons, bright caustic ridges.
    let alpha = log(1.0 + 1.65 * density) / log(1.0 + 1.65 * 18.0);
    let lum = pow(clamp(alpha, 0.0, 1.0), 1.26);

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

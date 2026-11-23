// Julia Filigree: luminous Julia-set boundary filaments and equipotential
// ribbons drifting across the dark as c traces the Mandelbrot border.
// After xscreensaver's Julia (Sean McCullough, 1995).

// Anti-aliased line of world half-width `hw` (in canvas heights) with filter
// half-width `aa`. Preserves integrated energy at wear-test resolution.
fn crisp_line(d: f32, hw: f32, aa: f32) -> f32 {
    let cov = clamp((hw + aa - d) / (2.0 * aa), 0.0, 1.0);
    return smoothstep(0.0, 1.0, cov) * min(1.0, hw / aa);
}

// Cyclical nocturnal dichroic palette: frost, amethyst, copper-amber, jade.
fn julia_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let frost = vec3<f32>(0.20, 0.78, 0.94);
    let amethyst = vec3<f32>(0.68, 0.34, 0.92);
    let copper = vec3<f32>(0.96, 0.62, 0.28);
    let jade = vec3<f32>(0.24, 0.84, 0.60);
    let s = p * 4.0;
    if (s < 1.0) {
        return mix(frost, amethyst, smoothstep(0.0, 1.0, s));
    }
    if (s < 2.0) {
        return mix(amethyst, copper, smoothstep(0.0, 1.0, s - 1.0));
    }
    if (s < 3.0) {
        return mix(copper, jade, smoothstep(0.0, 1.0, s - 2.0));
    }
    return mix(jade, frost, smoothstep(0.0, 1.0, s - 3.0));
}

// C-infinity path hugging just outside the Mandelbrot main cardioid and
// weaving cleanly past the elephant cusp and seahorse/dragon neck.
fn julia_c(theta: f32, t: f32, cell_phase: f32) -> vec2<f32> {
    let e1 = vec2<f32>(cos(theta), sin(theta));
    let e2 = vec2<f32>(cos(2.0 * theta), sin(2.0 * theta));
    let base = 0.5 * e1 - 0.25 * e2;
    let c_half = 0.5 + 0.5 * cos(theta);
    let cusp = c_half * c_half * c_half * c_half;
    let s_half = 0.5 - 0.5 * cos(theta);
    let neck = s_half * s_half * s_half * s_half;
    let inflate = 1.032 + 0.048 * sin(3.0 * theta + 0.5) + 0.068 * cusp;
    let wobble = vec2<f32>(-0.028, 0.135 * sin(t * 0.067 + cell_phase)) * neck;
    return base * inflate + wobble;
}

fn eval_julia_cell(
    q: vec2<f32>,
    rx: f32,
    ry: f32,
    x_off: f32,
    sx: f32,
    sy: f32,
    t: f32,
    aa: f32,
) -> vec3<f32> {
    let cell_id = vec2<f32>(rx, ry);
    let h = hash22(cell_id + vec2<f32>(g.seed * 19.3, g.seed * 7.1));
    let h2 = hash11(rx * 13.7 + ry * 29.1 + g.seed * 41.0);

    let cx = rx * sx + x_off + (h.x - 0.5) * 0.16;
    let cy = ry * sy + (h.y - 0.5) * 0.12;
    let d_cell = q - vec2<f32>(cx, cy);

    let r_world = 0.275 + 0.042 * sin(t * 0.041 + h2 * TAU);
    let max_r = r_world * 2.05;
    if (dot(d_cell, d_cell) > max_r * max_r) {
        return vec3<f32>(0.0);
    }

    let dir = select(-1.0, 1.0, h2 > 0.5);
    let ang = h.x * TAU + t * dir * (0.11 + 0.05 * h.y);
    let z0 = (rot2(-ang) * d_cell) / r_world;
    let z0_len = length(z0);
    let env = smoothstep(2.05, 1.55, z0_len);
    if (env <= 0.001) {
        return vec3<f32>(0.0);
    }

    let theta = h.x * TAU + h.y * 2.7 + t * (0.078 + 0.024 * h2);
    let c = julia_c(theta, t, h2 * TAU);
    let trap_r = 0.62 + 0.12 * sin(t * 0.37 + h2 * TAU);

    var z = z0;
    var dz = vec2<f32>(1.0, 0.0);
    var escaped = false;
    var hit_inf = false;
    var iter = 0.0;
    var trap_ring = 10.0;

    for (var i = 0; i < 48; i = i + 1) {
        let m2 = dot(z, z);
        if (m2 > 256.0) {
            escaped = true;
            iter = f32(i);
            break;
        }
        if (dot(dz, dz) > 1e24) {
            hit_inf = true;
            iter = f32(i);
            break;
        }
        dz = 2.0 * vec2<f32>(z.x * dz.x - z.y * dz.y, z.x * dz.y + z.y * dz.x);
        z = vec2<f32>(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        let r_cur = sqrt(dot(z, z));
        trap_ring = min(trap_ring, abs(r_cur - trap_r));
    }

    let hue_base = t * 0.019 + h.x * 0.45 + atan2(z0.y, z0.x) / TAU + 0.14 * z0_len;
    let fil_tint = julia_palette(hue_base);
    let ribbon_tint = julia_palette(hue_base + 0.27);
    let vein_tint = julia_palette(hue_base + 0.52);
    let pearl = vec3<f32>(0.94, 0.90, 0.98);

    var col = vec3<f32>(0.0);
    if (escaped) {
        let m2 = dot(z, z);
        let dz_len = max(length(dz), 1e-6);
        let d_world = (0.5 * sqrt(m2) * log(max(m2, 2.0)) / dz_len) * r_world;
        let nu = iter + 1.0 - log2(max(0.5 * log2(max(m2, 2.0)), 1.0));
        let shimmer = 0.56 + 0.44 * sin(nu * 0.72 - t * 1.18 + h2 * TAU);

        // Resolution-invariant primary Julia boundary filament and tight aura.
        let fil_line = crisp_line(d_world, 0.0028, aa);
        let aura = exp(-d_world * 55.0) * shimmer;

        // Marching outer equipotential contour ribbons fading smoothly outward.
        let u_ring = -log2(max(d_world, 1e-5)) * 1.15 - t * 0.29 + h.x;
        let ring_dist = abs(fract(u_ring) - 0.5) / 1.15;
        let band_mask = smoothstep(0.0025, 0.014, d_world) * (1.0 - smoothstep(0.08, 0.24, d_world));
        let contour = smoothstep(0.18, 0.0, ring_dist) * band_mask * (0.45 + 0.55 * shimmer);

        col = col + mix(fil_tint, pearl, 0.28) * fil_line * (0.62 + 0.48 * shimmer);
        col = col + fil_tint * aura * 0.44;
        col = col + ribbon_tint * contour * 0.34;
    } else {
        let dz_len = length(dz);
        let chaos = select(smoothstep(2.0, 28.0, dz_len), 1.0, hit_inf);
        let core_shimmer = 0.55 + 0.45 * sin(t * 1.07 + trap_ring * 8.0 + h2 * TAU);
        let vein = exp(-trap_ring * 24.0) * (1.0 - chaos) * 0.24;
        col = col + mix(fil_tint, pearl, 0.32) * chaos * (0.35 + 0.50 * core_shimmer);
        col = col + vein_tint * vein * (0.55 + 0.45 * core_shimmer);
    }

    return col * env;
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let px = 1.0 / max(g.target_size.y, 1.0);
    let aa = px * 0.95;

    let sx: f32 = 1.26;
    let sy: f32 = 0.96;
    let drift = vec2<f32>(0.064, 0.022) * t;
    let q = p - drift;

    let ry0 = floor(q.y / sy);
    var col = vec3<f32>(0.0);

    for (var dy = 0; dy < 2; dy = dy + 1) {
        let ry = ry0 + f32(dy);
        let x_off = select(0.0, 0.5 * sx, (i32(round(ry)) & 1) != 0);
        let rx0 = floor((q.x - x_off) / sx);
        for (var dx = 0; dx < 2; dx = dx + 1) {
            let rx = rx0 + f32(dx);
            col = col + eval_julia_cell(q, rx, ry, x_off, sx, sy, t, aa);
        }
    }

    // Soft shoulder keeps dense filament crossings from clipping flat.
    return col / (vec3<f32>(1.0) + col * 0.25);
}

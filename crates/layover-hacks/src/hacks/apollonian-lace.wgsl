// Apollonian Lace: nested tangent Apollonian circle packings gliding across
// the dark in hexagonal medallions with Mobius-drifting symmetry.
// After xscreensaver's Apollonian (Allan R. Wilks and David Bagley, 2002).

struct CircleHit {
    center: vec2<f32>,
    radius: f32,
    depth: f32,
    hit: bool,
};

// Anti-aliased crisp stroke of world half-width `hw` (in canvas heights) with
// pixel filter half-width `aa`. Preserves integrated energy at wear-test resolution.
fn crisp_line(d: f32, hw: f32, aa: f32) -> f32 {
    let cov = clamp((hw + aa - d) / (2.0 * aa), 0.0, 1.0);
    return smoothstep(0.0, 1.0, cov) * min(1.0, hw / aa);
}

fn c_conj(a: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(a.x, -a.y);
}

fn c_mul(a: vec2<f32>, b: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

fn c_mul_i(a: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(-a.y, a.x);
}

// Balanced 4-stop nocturnal jewel palette: cerulean, orchid, gold, viridian.
fn lace_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let cerulean = vec3<f32>(0.18, 0.72, 0.98);
    let orchid = vec3<f32>(0.76, 0.34, 0.94);
    let gold = vec3<f32>(0.98, 0.62, 0.24);
    let viridian = vec3<f32>(0.22, 0.88, 0.56);
    let s = p * 4.0;
    if (s < 1.0) {
        return mix(cerulean, orchid, smoothstep(0.0, 1.0, s));
    }
    if (s < 2.0) {
        return mix(orchid, gold, smoothstep(0.0, 1.0, s - 1.0));
    }
    if (s < 3.0) {
        return mix(gold, viridian, smoothstep(0.0, 1.0, s - 2.0));
    }
    return mix(viridian, cerulean, smoothstep(0.0, 1.0, s - 3.0));
}

// Smooth 3-mode cycle: (Filigree Lace, Resonant Ripples, Faceted Orbs).
fn stage_weights(t: f32) -> vec3<f32> {
    let stage = t / 46.0 + g.seed * 3.0;
    let idx0 = u32(floor(stage)) % 3u;
    let blend = smoothstep(0.78, 1.0, fract(stage));
    let a = 1.0 - blend;
    if (idx0 == 0u) {
        return vec3<f32>(a, blend, 0.0);
    }
    if (idx0 == 1u) {
        return vec3<f32>(0.0, a, blend);
    }
    return vec3<f32>(blend, 0.0, a);
}

// Nearest hexagonal lattice center offset (xy) and unique integer cell id (zw).
fn hex_cell(q: vec2<f32>) -> vec4<f32> {
    let r = vec2<f32>(1.0, 1.73205081);
    let h = r * 0.5;
    let ia = round(q / r);
    let ib = round((q - h) / r);
    let pa = q - ia * r;
    let pb = (q - h) - ib * r;
    if (dot(pa, pa) < dot(pb, pb)) {
        return vec4<f32>(pa.x, pa.y, ia.x * 2.0, ia.y * 2.0);
    }
    return vec4<f32>(pb.x, pb.y, ib.x * 2.0 + 1.0, ib.y * 2.0 + 1.0);
}

fn finish_circle(
    A_u: f32,
    B_u: vec2<f32>,
    num_radius: f32,
    depth: f32,
    parity: bool,
) -> CircleHit {
    if (abs(A_u) < 1e-5) {
        return CircleHit(vec2<f32>(0.0), 0.0, depth, false);
    }
    let u_c = -B_u / A_u;
    let center = select(u_c, c_conj(u_c), parity);
    return CircleHit(center, num_radius / abs(A_u), depth, true);
}

// Exact Mobius pullback solver in the Apollonian strip for unit-disk point `u`.
fn apollonian_solve(u: vec2<f32>, x0: f32, h_param: f32) -> CircleHit {
    let one_minus_u = vec2<f32>(1.0 - u.x, -u.y);
    let denom = dot(one_minus_u, one_minus_u);
    if (denom < 1e-5) {
        return CircleHit(vec2<f32>(0.0), 0.0, 14.0, false);
    }

    let k = inverseSqrt(2.0 * h_param);
    var a = vec2<f32>(-x0, h_param + 1.0) * k;
    var b = vec2<f32>(x0, h_param - 1.0) * k;
    var c = vec2<f32>(-1.0, 0.0) * k;
    var d = vec2<f32>(1.0, 0.0) * k;
    var parity = false;

    let cayley_re = (1.0 - dot(u, u)) / denom;
    let cayley_im = (2.0 * u.y) / denom;
    var w = vec2<f32>(x0 - h_param * cayley_im, -1.0 + h_param * cayley_re);

    if (w.y >= 1.0) {
        let A_u = (a.x * c.y - a.y * c.x) + dot(c, c);
        let B_u = -0.5 * c_mul_i(c_mul(c_conj(a), d) - c_mul(b, c_conj(c))) + c_mul(c_conj(c), d);
        return finish_circle(A_u, B_u, 0.5, 0.0, parity);
    }

    for (var i = 0; i < 14; i = i + 1) {
        if (abs(w.x) > 120.0 || dot(a, a) + dot(c, c) > 6000.0) {
            return CircleHit(vec2<f32>(0.0), 0.0, f32(i), false);
        }

        let n = round(w.x * 0.5);
        w.x = w.x - 2.0 * n;
        a = a - 2.0 * n * c;
        b = b - 2.0 * n * d;

        if (w.x < 0.0) {
            w.x = -w.x;
            a = -c_conj(a);
            b = -c_conj(b);
            c = c_conj(c);
            d = c_conj(d);
            parity = !parity;
        }

        if (w.y < 0.0) {
            w.y = -w.y;
            a = c_conj(a);
            b = c_conj(b);
            c = c_conj(c);
            d = c_conj(d);
            parity = !parity;
        }

        let d4_v = w - vec2<f32>(1.0, 0.0);
        if (dot(d4_v, d4_v) < 1.0) {
            let A_u = dot(a, a) - 2.0 * dot(a, c);
            let B_u = c_mul(c_conj(a), b - d) - c_mul(b, c_conj(c));
            return finish_circle(A_u, B_u, 1.0, f32(i) + 1.0, parity);
        }

        let q_inv = w - vec2<f32>(0.0, 1.0);
        let r2 = dot(q_inv, q_inv);
        if (r2 < 1e-6) {
            return CircleHit(vec2<f32>(0.0), 0.0, f32(i) + 1.0, false);
        }
        w = vec2<f32>(0.0, 1.0) + q_inv / r2;
        let ab = c_conj(a);
        let bb = c_conj(b);
        let cb = c_conj(c);
        let db = c_conj(d);
        a = c_mul_i(ab);
        b = c_mul_i(bb);
        c = ab + c_mul_i(cb);
        d = bb + c_mul_i(db);
        parity = !parity;

        if (w.y < -1.0) {
            let A_u = (a.y * c.x - a.x * c.y) + dot(c, c);
            let B_u = 0.5 * c_mul_i(c_mul(c_conj(a), d) - c_mul(b, c_conj(c))) + c_mul(c_conj(c), d);
            return finish_circle(A_u, B_u, 0.5, f32(i) + 1.5, parity);
        }
    }

    return CircleHit(vec2<f32>(0.0), 0.0, 14.0, false);
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = aspect();
    let px = 1.0 / max(g.target_size.y, 1.0);
    let aa = px * 0.95;

    let mid = vec2<f32>(a * 0.5, 0.5);
    let rot = 0.09 * sin(t * 0.014 + g.seed * TAU) + 0.03 * cos(t * 0.023 + 0.9);
    // Shallow irrational drift keeps perpendicular velocity high across circular arc tangents.
    let drift = vec2<f32>(0.062, 0.026) * t + vec2<f32>(g.seed * 13.7, g.seed * 8.3);
    let S = 0.88 + 0.04 * sin(t * 0.019 + g.seed * 4.1);
    let q = (rot2(rot) * (p - mid) - drift) / S;

    let hc = hex_cell(q);
    let local_hex = hc.xy;
    let cid = hc.zw;
    let hex_d = length(local_hex);

    let h0 = hash22(cid + vec2<f32>(g.seed * 17.3, g.seed * 29.1));
    let h1 = hash22(cid * 1.37 + vec2<f32>(g.seed * 43.7, g.seed * 11.9));

    let r_hex = 0.440 + 0.015 * sin(t * 0.09 + h0.x * TAU);
    let r_med = r_hex * S;

    if (hex_d > r_hex + 0.044) {
        return vec3<f32>(0.0);
    }

    let dir = select(-1.0, 1.0, h0.y > 0.5);
    let spin = h0.x * TAU + t * dir * (0.09 + 0.045 * h1.x);
    let u = rot2(-spin) * (local_hex / r_hex);
    let u_len = length(u);

    // Two oblique soliton light waves sweeping across the 32:9 panorama.
    let wa = fract(dot(p, vec2<f32>(0.24, 0.15)) - t * 0.17 + 0.14 * sin(p.y * 2.2 + t * 0.09) + g.seed) - 0.5;
    let wb = fract(dot(p, vec2<f32>(-0.16, 0.27)) - t * 0.13 + 0.12 * cos(p.x * 1.5 - t * 0.08) + g.seed * 2.3) - 0.5;
    let pulse = clamp(exp(-wa * wa * 34.0) * 0.85 + exp(-wb * wb * 38.0) * 0.70, 0.0, 1.0);

    let light_dir = normalize(vec3<f32>(
        cos(t * 0.27 + g.seed * 2.0),
        sin(t * 0.21 + 1.1),
        0.54,
    ));
    let half_v = normalize(light_dir + vec3<f32>(0.0, 0.0, 1.0));

    let pearl = vec3<f32>(0.96, 0.94, 0.99);
    let sw = stage_weights(t);
    let w_lace = sw.x;
    let w_ripple = sw.y;
    let w_orbs = sw.z;

    let d_med_world = (hex_d - r_hex) * S;
    var col = vec3<f32>(0.0);

    // Interior of the Apollonian medallion (u_len < 1.0).
    if (u_len < 1.0) {
        let m_phase = t * (0.11 + 0.03 * h1.y) + h0.x * TAU + h1.x * 3.7;
        let x0 = 0.72 * sin(m_phase) + 0.16 * sin(m_phase * 2.0 + 0.7);
        let h_param = 1.24 + 0.50 * cos(m_phase * 0.73 + h0.y * TAU);

        let hit = apollonian_solve(u, x0, h_param);
        let inner_mask = smoothstep(0.0, 0.004 + aa, -d_med_world);

        if (hit.hit) {
            let r_disk = max(hit.radius, 1e-4);
            let r_world = r_disk * r_med;
            let rel = u - hit.center;
            let d_center_disk = length(rel);
            let d_center_world = d_center_disk * r_med;
            let d_rim_world = max(r_world - d_center_world, 0.0);

            // Scale-adaptive rim keeps intricate cusps sharp at 1440p and safe at wear-test size.
            let vis = smoothstep(aa * 0.42, aa * 2.5, r_world);
            let hw_rim = clamp(r_world * 0.075, 0.0011, 0.0025);
            let rim = crisp_line(d_rim_world, hw_rim, aa) * vis;

            let hue_idx = t * 0.017
                + p.x * 0.08
                + p.y * 0.06
                + h0.x * 0.55
                + log2(max(1.0 / r_disk, 1.0)) * 0.115
                + hit.depth * 0.055
                + atan2(hit.center.y, hit.center.x) / TAU * 0.14
                + g.seed;
            let tint = lace_palette(hue_idx);
            let accent = lace_palette(hue_idx + 0.34);

            // 2.5D spherical dome normal inside each tangent circle.
            let n_xy = (rot2(spin) * (rel / r_disk)) * 0.85;
            let nz = sqrt(max(1.0 - min(dot(n_xy, n_xy), 0.96), 0.04));
            let n = normalize(vec3<f32>(n_xy.x, n_xy.y, nz));
            let diff = max(dot(n, light_dir), 0.0);
            let spec = pow(max(dot(n, half_v), 0.0), 22.0);
            let rim_catch = 0.62 + 0.38 * max(dot(n_xy, light_dir.xy), -0.35);

            // Dark stained-glass circle fill stays strictly below LIT so interiors never dwell.
            let base_glass = tint * (0.022 + 0.050 * diff + 0.042 * pulse) * vis;

            // Mode 0: Filigree Lace (crisp rim + inset hairline + tiny pulsing center pip).
            let large_vis = smoothstep(0.024, 0.068, r_world);
            let inset_hair = crisp_line(abs(d_rim_world - r_world * 0.14), 0.0011, aa) * large_vis * vis;
            let pip_pulse = 0.66 + 0.34 * sin(t * 1.2 + hit.depth * 1.7 + h1.x * TAU);
            let pip = crisp_line(d_center_world, 0.0024, aa) * large_vis * vis * pip_pulse;
            let mode0 = mix(accent, pearl, 0.28) * inset_hair * (0.82 + 0.48 * pulse)
                + mix(accent, pearl, 0.52) * pip * 1.25;

            // Mode 1: Resonant Ripples (marching concentric waves clipped inside circle wall).
            let ring_phase = d_center_world * 26.0 - t * 0.44 + h0.y;
            let d_ring = abs(fract(ring_phase) - 0.5) / 26.0;
            let ring_mask = smoothstep(0.004, 0.012, d_rim_world) * smoothstep(0.010, 0.020, d_center_world) * large_vis;
            let rings = crisp_line(d_ring, 0.0013, aa) * ring_mask * vis;
            let mode1 = mix(accent, pearl, 0.22 + 0.18 * pulse) * rings * (0.95 + 0.65 * pulse);

            // Mode 2: Faceted Orbs (double-bevel rim + spherical dome specular + crescent glow).
            let inner_bevel = crisp_line(abs(d_rim_world - 0.0085), 0.0012, aa) * smoothstep(0.018, 0.042, r_world) * vis;
            let orb_spec = mix(tint, pearl, 0.48) * spec * (0.24 + 0.14 * pulse) * vis;
            let mode2 = mix(accent, pearl, 0.34) * inner_bevel * (0.85 + 0.50 * rim_catch) + orb_spec;

            let rim_aura = exp(-d_rim_world * 78.0) * (0.055 + 0.16 * pulse) * vis;
            let rim_col = mix(tint, pearl, 0.30 + 0.22 * pulse) * rim * (1.42 + 0.50 * pulse) * rim_catch
                + tint * rim_aura;

            col = (base_glass + rim_col + mode0 * w_lace + mode1 * w_ripple + mode2 * w_orbs) * inner_mask;
        } else {
            // Unresolved cusp dust stays dim below LIT so dense corners never dwell.
            let cusp_hue = t * 0.017 + p.x * 0.08 + p.y * 0.06 + h0.x * 0.55 + g.seed;
            let cusp_tint = lace_palette(cusp_hue);
            let cusp_shimmer = 0.55 + 0.45 * sin(t * 0.8 + p.x * 6.0 + p.y * 5.0);
            col = cusp_tint * (0.08 + 0.10 * pulse * cusp_shimmer) * inner_mask;
        }
    }

    // Outer medallion astrolabe bezel + secondary hairline + strict Voronoi boundary fade.
    let med_hue = t * 0.017 + p.x * 0.08 + p.y * 0.06 + h0.x * 0.55 + g.seed;
    let med_tint = lace_palette(med_hue);
    let med_accent = lace_palette(med_hue + 0.36);

    let outer_bezel = crisp_line(abs(d_med_world), 0.0026, aa);
    let outer_hair = crisp_line(abs(d_med_world - 0.0105), 0.0011, aa);
    let hex_guard = smoothstep(0.492, 0.455, hex_d);
    let outer_aura = exp(-abs(d_med_world) * 80.0) * (0.055 + 0.17 * pulse) * hex_guard;

    col = col
        + mix(med_tint, pearl, 0.34 + 0.20 * pulse) * outer_bezel * (1.28 + 0.42 * pulse)
        + mix(med_accent, pearl, 0.28) * outer_hair * (0.68 + 0.36 * pulse) * hex_guard
        + med_tint * outer_aura;

    // Soft highlight shoulder keeps overlapping rims crisp without flat white clipping.
    return col / (vec3<f32>(1.0) + col * 0.18);
}

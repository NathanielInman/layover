// Lava Drift: buoyant 3D molten wax columns rising, merging into stretched
// necks and pinching apart across the dark.
// After xscreensaver's Lavalite (Jamie Zawinski, 2002) and Metaballs
// (W.P. van Paassen, 2002).

const COL_W: f32 = 2.05;
const BLOBS_PER_COL: i32 = 3;
const K_SMIN: f32 = 3.7;
const SLAB_Z: f32 = 0.98;

// Anti-aliased crisp stroke of world half-width `hw` with pixel filter half-width `aa`.
fn crisp_line(d: f32, hw: f32, aa: f32) -> f32 {
    let cov = clamp((hw + aa - d) / (2.0 * aa), 0.0, 1.0);
    return smoothstep(0.0, 1.0, cov) * min(1.0, hw / max(aa, 1e-5));
}

// Balanced 6-stop nocturnal jewel wheel: coral-amber, rose, orchid, sapphire, viridian, gold.
// Every adjacent transition stays saturated (no olive/slate midpoints), and channel
// shares remain balanced around 33% before and after care hue rotation.
fn lava_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let coral = vec3<f32>(0.98, 0.44, 0.18);
    let rose = vec3<f32>(0.94, 0.22, 0.56);
    let orchid = vec3<f32>(0.62, 0.30, 0.98);
    let sapphire = vec3<f32>(0.16, 0.72, 0.98);
    let viridian = vec3<f32>(0.18, 0.90, 0.62);
    let gold = vec3<f32>(0.92, 0.78, 0.20);
    let s = p * 6.0;
    if (s < 1.0) {
        return mix(coral, rose, smoothstep(0.0, 1.0, s));
    }
    if (s < 2.0) {
        return mix(rose, orchid, smoothstep(0.0, 1.0, s - 1.0));
    }
    if (s < 3.0) {
        return mix(orchid, sapphire, smoothstep(0.0, 1.0, s - 2.0));
    }
    if (s < 4.0) {
        return mix(sapphire, viridian, smoothstep(0.0, 1.0, s - 3.0));
    }
    if (s < 5.0) {
        return mix(viridian, gold, smoothstep(0.0, 1.0, s - 4.0));
    }
    return mix(gold, coral, smoothstep(0.0, 1.0, s - 5.0));
}

// Smooth 3-mode cycle: (Lavalite Wax, Iridescent Metaballs, Magma Crucible).
fn stage_weights(t: f32) -> vec3<f32> {
    let stage = t / 44.0 + g.seed * 3.0;
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

// World-space drifted blob `(center.xyz, radius)` for column `cx` and index `idx`.
// Local X stays strictly inside [0.23, 0.77] * COL_W so dx in -1..=1 is seamless,
// while horizontal column drift keeps every blob moving monotonically across pixels.
fn blob_geom(cx: f32, idx: i32, t: f32) -> vec4<f32> {
    let fi = f32(idx);
    let h = hash22(vec2<f32>(cx * 13.7 + fi * 3.1, g.seed * 29.3 + fi * 7.7));
    let h2 = hash22(vec2<f32>(cx * 5.3 + fi * 11.9, g.seed * 17.1 + 4.3));

    let wx = 0.25 + 0.13 * h.x;
    let wy = 0.29 + 0.12 * h2.x + 0.05 * fi;
    let wz = 0.24 + 0.13 * h2.y;

    let ph_y = h.y * TAU + fi * 2.18;
    let ph_x = ph_y + 1.5707963;
    let ph_z = h2.x * TAU + fi * 1.37;

    let x_home = (0.37 + 0.13 * fi + (h2.y - 0.5) * 0.08) * COL_W;
    let x_sway = 0.10 * COL_W * cos(t * wx + ph_x);
    let drift_x = t * 0.26 + g.seed * 19.7;
    let bx = cx * COL_W + x_home + x_sway - drift_x;

    let y_amp = 0.70 + 0.07 * fi;
    let by = y_amp * sin(t * wy + ph_y) + 0.09 * sin(t * (wy * 1.9) + h.x * TAU);
    let bz = (0.24 + 0.05 * h.y) * sin(t * wz + ph_z);

    var r_base = 0.39 + 0.06 * h.x;
    if (idx == 1) {
        r_base = 0.30 + 0.06 * h.x;
    } else if (idx == 2) {
        r_base = 0.21 + 0.05 * h.x;
    }
    let br = r_base * (1.0 + 0.10 * sin(t * (0.38 + 0.11 * h2.y) + ph_y));

    return vec4<f32>(bx, by, bz, br);
}

fn blob_dist(p: vec3<f32>, b: vec4<f32>, cx: f32, idx: i32, t: f32) -> f32 {
    let stretch = 1.0 + 0.12 * sin(t * 0.44 + cx * 2.1 + f32(idx) * 1.7);
    let d = p - b.xyz;
    let q = vec3<f32>(d.x * 1.06, d.y * (0.90 / stretch), d.z * 1.06);
    return (length(q) - b.w) * 0.94;
}

// Conservative signed distance across the active 3-column stencil using online
// max-shifted log-sum-exp smooth minimum (100% associative across columns).
fn sdf(p: vec3<f32>, t: f32) -> f32 {
    let drift_x = t * 0.26 + g.seed * 19.7;
    let col_f = floor((p.x + drift_x) / COL_W);

    var m = 1e6;
    var sum_exp = 0.0;
    for (var dx: i32 = -1; dx <= 1; dx = dx + 1) {
        let cx = col_f + f32(dx);
        for (var i: i32 = 0; i < BLOBS_PER_COL; i = i + 1) {
            let b = blob_geom(cx, i, t);
            let di = blob_dist(p, b, cx, i, t);
            if (di < m) {
                sum_exp = sum_exp * exp(-min(K_SMIN * (m - di), 30.0)) + 1.0;
                m = di;
            } else {
                sum_exp = sum_exp + exp(-min(K_SMIN * (di - m), 30.0));
            }
        }
    }
    let smooth_d = m - log(max(sum_exp, 1.0)) / K_SMIN;
    let wobble = 0.015
        * sin(p.x * 3.1 + t * 0.85)
        * cos(p.y * 3.7 - t * 0.72)
        * sin(p.z * 3.4 + t * 0.61);
    return smooth_d + wobble;
}

// Swirled circular-hue color mix across merging blobs using the same weights.
fn wax_color(p: vec3<f32>, t: f32) -> f32 {
    let drift_x = t * 0.26 + g.seed * 19.7;
    let col_f = floor((p.x + drift_x) / COL_W);
    let hue_base = t * 0.017 + (p.x + drift_x * 0.15) * 0.075 + p.y * 0.06 + g.seed;

    var m = 1e6;
    var sum_exp = 0.0;
    var vec_cs = vec2<f32>(0.0);
    for (var dx: i32 = -1; dx <= 1; dx = dx + 1) {
        let cx = col_f + f32(dx);
        for (var i: i32 = 0; i < BLOBS_PER_COL; i = i + 1) {
            let b = blob_geom(cx, i, t);
            let di = blob_dist(p, b, cx, i, t);
            let h_cell = hash21(vec2<f32>(cx * 7.3 + f32(i) * 4.1, g.seed * 13.9));
            let bh = hue_base + (h_cell - 0.5) * 0.44;
            let cs = vec2<f32>(cos(bh * TAU), sin(bh * TAU));
            if (di < m) {
                let scale = exp(-min(K_SMIN * (m - di), 30.0));
                sum_exp = sum_exp * scale + 1.0;
                vec_cs = vec_cs * scale + cs;
                m = di;
            } else {
                let w = exp(-min(K_SMIN * (di - m), 30.0));
                sum_exp = sum_exp + w;
                vec_cs = vec_cs + cs * w;
            }
        }
    }
    let avg_cs = vec_cs / max(sum_exp, 1e-4)
        + 0.08 * vec2<f32>(cos(hue_base * TAU), sin(hue_base * TAU));
    return fract(atan2(avg_cs.y, avg_cs.x) / TAU);
}

// Sparse rising micro-bubbles drifting in the deep fluid behind/around the wax.
fn micro_bubbles(p: vec2<f32>, t: f32) -> f32 {
    let uv = vec2<f32>(p.x * 3.8 + t * 0.08, p.y * 3.8 - t * 0.52);
    let cid = floor(uv);
    let f = fract(uv);
    let h = hash22(cid + vec2<f32>(g.seed * 19.3, 4.7));
    if (h.x < 0.62) {
        return 0.0;
    }
    let center = vec2<f32>(0.25 + 0.50 * h.x, 0.25 + 0.50 * h.y)
        + 0.08 * vec2<f32>(sin(t * 1.4 + h.y * TAU), cos(t * 1.1 + h.x * TAU));
    let d = length(f - center);
    let twinkle = 0.55 + 0.45 * sin(t * 2.2 + h.x * TAU);
    return smoothstep(0.065, 0.012, d) * twinkle * 0.12;
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let ro = vec3<f32>(0.0, 0.08 * sin(t * 0.13 + g.seed * TAU), 3.35);
    let look_at = vec3<f32>(
        0.12 * sin(t * 0.09 + g.seed * 3.1),
        0.05 * cos(t * 0.11 + 1.4),
        0.0,
    );
    let roll = 0.035 * sin(t * 0.07 + g.seed * 5.2);
    let focal = 1.38;
    let rd = camera_ray(p, ro, look_at, roll, focal);

    // Analytical Z-slab clipping + 64 steps avoids grazing-ray exhaustion behind front blobs.
    let inv_z = 1.0 / min(rd.z, -0.05);
    let t_enter = max((SLAB_Z - ro.z) * inv_z, 0.0);
    let t_exit = max((-SLAB_Z - ro.z) * inv_z, t_enter + 0.01);
    let ro_slab = ro + rd * t_enter;
    let h = rm_march(ro_slab, rd, t, t_exit - t_enter, 64, 0.88);

    let bg = vec3<f32>(0.001, 0.002, 0.004);
    let sw = stage_weights(t);
    let w_wax = sw.x;
    let w_irid = sw.y;
    let w_magma = sw.z;
    let pearl = vec3<f32>(0.96, 0.94, 0.99);

    // Soft backlit fluid halo + rising bubbles stay well below LIT so background never dwells.
    let t_mid = -ro.z * inv_z;
    let p_mid = ro + rd * t_mid;
    let d_mid = sdf(p_mid, t);
    let mid_h = t * 0.017 + p_mid.x * 0.075 + p_mid.y * 0.06 + g.seed;
    let halo_col = lava_palette(mid_h);
    let halo = halo_col * exp(-max(d_mid, 0.0) * 3.2) * 0.085;
    let bubbles = lava_palette(mid_h + 0.28) * micro_bubbles(p, t);
    var col = bg + halo + bubbles;

    if (h.hit) {
        let total_d = t_enter + h.dist;
        let hp = ro + rd * total_d;
        let n = rm_normal(hp, t, 0.0022);
        let ao = rm_ao(hp, n, t);
        let v = -rd;

        // Primary warm lamp illumination from below-front + cool upper counter-rim.
        let l0 = normalize(vec3<f32>(0.45 * cos(t * 0.21 + g.seed * TAU), -0.68, 0.58));
        let l1 = normalize(vec3<f32>(-0.55 * sin(t * 0.17 + 1.2), 0.72, 0.42));
        let diff0 = max(dot(n, l0), 0.0);
        let diff1 = max(dot(n, l1), 0.0);
        let spec0 = pow(max(dot(n, normalize(l0 + v)), 0.0), 26.0);
        let spec1 = pow(max(dot(n, normalize(l1 + v)), 0.0), 18.0);

        let ndv = max(dot(n, v), 0.0);
        let rim = fresnel(n, v, 1.85);
        let rim_sharp = fresnel(n, v, 3.6);

        // Single inward thickness sample lights up thin stretched necks and fringes.
        let d_in = sdf(hp - n * 0.24, t);
        let thin = smoothstep(-0.24, -0.02, d_in);

        // Moving internal convection waves keep lit plumes shifting continuously.
        let conv = 0.5 + 0.5 * sin(hp.y * 4.8 - t * 1.25 + hp.x * 1.5 + sin(hp.z * 3.2 + t * 0.45));
        let conv2 = 0.5 + 0.5 * cos(hp.x * 3.6 - t * 0.96 - hp.y * 2.8);
        let caustic = pow(conv, 2.2) * (0.45 + 0.55 * conv2);

        let blob_h = wax_color(hp, t);
        let wax_tint = lava_palette(blob_h);
        let accent = lava_palette(blob_h + 0.17);

        // Rich dark translucent wax core (still safely below LIT on unlit domes).
        let core_col = mix(wax_tint, accent, 0.35 * conv);
        let core = core_col * (0.024 + 0.068 * diff0 * ao + 0.034 * diff1 + 0.062 * caustic);

        // Mode 0: Lavalite Wax (glowing convection caustics, backlit rim, hot stretched necks).
        let neck_glow = mix(wax_tint, accent, 0.32) * thin * (0.54 + 0.48 * conv) * (0.55 + 0.45 * (1.0 - ao));
        let wax_caustic = mix(wax_tint, accent, 0.50) * caustic * (0.38 + 0.32 * diff0);
        let wax_rim = mix(wax_tint, pearl, 0.16 + 0.14 * conv2) * rim * (1.08 + 0.42 * conv2)
            + mix(accent, pearl, 0.28) * rim_sharp * (0.68 + 0.25 * diff0);
        let wax_spec = mix(wax_tint, pearl, 0.42) * (spec0 * 0.98 + spec1 * 0.54);
        let wax_col = core + neck_glow + wax_caustic + wax_rim + wax_spec;

        // Mode 1: Iridescent Metaballs (thin-film dichroic sheen + crisp dual iso-contour ribbons).
        let irid_tint = lava_palette(blob_h + (1.0 - ndv) * 0.48 + t * 0.03);
        let irid_accent = lava_palette(blob_h + (1.0 - ndv) * 0.48 + 0.18);
        let px_w = total_d / (focal * max(g.target_size.y, 1.0));
        let iso_ph = hp.y * 2.9 - t * 0.65 + 0.44 * sin(hp.x * 2.3 + hp.z * 2.1 + t * 0.35);
        let d_iso = abs(fract(iso_ph) - 0.5) / 2.9;
        let d_iso2 = abs(fract(iso_ph * 2.0 + 0.25) - 0.5) / 5.8;
        let iso_main = crisp_line(d_iso, 0.017, px_w * 1.1);
        let iso_sub = crisp_line(d_iso2, 0.008, px_w * 1.1);
        let irid_rim = irid_tint * rim * (1.08 + 0.38 * conv);
        let irid_lines = mix(irid_accent, pearl, 0.24 + 0.16 * conv2) * iso_main * (0.82 + 0.45 * (0.35 + 0.65 * rim))
            + mix(irid_tint, pearl, 0.16) * iso_sub * 0.44 * (0.5 + 0.5 * conv);
        let irid_spec = mix(irid_tint, pearl, 0.42) * (spec0 * 0.88 + spec1 * 0.58);
        let irid_col = core * 0.92 + irid_rim + irid_lines + irid_spec + mix(irid_tint, accent, 0.30) * thin * 0.30 * conv;

        // Mode 2: Magma Crucible (dark cooled shell laced with flowing 3D gyroid magma veins).
        let mq = hp * 6.2 + vec3<f32>(0.0, -t * 0.95, t * 0.28) + n * 0.38;
        let gy = abs(dot(sin(mq), cos(mq.yzx)));
        let vein_glow = exp(-gy * 6.2) * (0.82 + 0.46 * conv);
        let vein_core = smoothstep(0.115, 0.0, gy) * (0.94 + 0.36 * conv2);
        let magma_veins = mix(wax_tint, pearl, 0.14) * vein_glow
            + mix(accent, pearl, 0.36) * vein_core;
        let magma_rim = mix(wax_tint, pearl, 0.16) * rim * (0.76 + 0.35 * conv);
        let magma_neck = mix(accent, pearl, 0.22) * thin * (0.46 + 0.32 * conv2);
        let magma_col = core * 0.80 + magma_veins + magma_rim + magma_neck + mix(wax_tint, pearl, 0.36) * spec0 * 0.55;

        let surf_col = wax_col * w_wax + irid_col * w_irid + magma_col * w_magma;
        let edge_fade = exp(-max(total_d - 2.6, 0.0) * 0.16);
        col = mix(col, surf_col, edge_fade);
    }

    return col / (vec3<f32>(1.0) + col * 0.20);
}

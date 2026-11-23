// Truchet Weave: multi-scale interlaced Truchet arcs, basketweave overpasses
// and chevron tracks gliding across the dark with traveling light pulses.
// After xscreensaver's Truchet (Adrian Likins, 1998).

// Anti-aliased crisp stroke of world half-width `hw` (in canvas heights) with
// pixel filter half-width `aa`. Preserves integrated energy at wear-test resolution.
fn crisp_line(d: f32, hw: f32, aa: f32) -> f32 {
    let cov = clamp((hw + aa - d) / (2.0 * aa), 0.0, 1.0);
    return smoothstep(0.0, 1.0, cov) * min(1.0, hw / aa);
}

// Cyclical nocturnal dichroic palette: sapphire, amethyst, amber, jade.
fn weave_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let sapphire = vec3<f32>(0.18, 0.74, 0.96);
    let amethyst = vec3<f32>(0.78, 0.34, 0.92);
    let amber = vec3<f32>(0.98, 0.58, 0.24);
    let jade = vec3<f32>(0.22, 0.86, 0.58);
    let s = p * 4.0;
    if (s < 1.0) {
        return mix(sapphire, amethyst, smoothstep(0.0, 1.0, s));
    }
    if (s < 2.0) {
        return mix(amethyst, amber, smoothstep(0.0, 1.0, s - 1.0));
    }
    if (s < 3.0) {
        return mix(amber, jade, smoothstep(0.0, 1.0, s - 2.0));
    }
    return mix(jade, sapphire, smoothstep(0.0, 1.0, s - 3.0));
}

fn stage_morph(idx: u32) -> f32 {
    if (idx == 0u) {
        return 0.0;
    }
    if (idx == 1u) {
        return 0.42;
    }
    return 1.0;
}

// Morph smoothly across circular Truchet arcs (0.0), chamfered Art-Deco arches
// (0.42), and 45-degree angled chevron tracks (1.0).
fn morph_factor(t: f32) -> f32 {
    let stage = t / 42.0 + g.seed * 3.0;
    let idx0 = u32(floor(stage)) % 3u;
    let idx1 = (idx0 + 1u) % 3u;
    let blend = smoothstep(0.76, 1.0, fract(stage));
    return mix(stage_morph(idx0), stage_morph(idx1), blend);
}

// First-order Euclidean distance to the L2/L1 morphed curve:
// mix(length(abs(u)), abs(u).x + abs(u).y, m) = r.
fn sd_morph_arc(u: vec2<f32>, r: f32, m: f32) -> f32 {
    let a = abs(u);
    let len2 = length(a);
    let dir2 = select(vec2<f32>(0.70710678, 0.70710678), a / max(len2, 1e-5), len2 > 1e-5);
    let val = mix(len2, a.x + a.y, m) - r;
    let grad = mix(dir2, vec2<f32>(1.0, 1.0), m);
    return abs(val) / max(length(grad), 1e-5);
}

// Sculpted enamel ribbon with dim interior, crisp metallic twin rims,
// luminous traveling spine tracer, and tight pulse aura.
fn shade_ribbon(
    d_world: f32,
    hw_rib: f32,
    aa: f32,
    tint: vec3<f32>,
    pulse: f32,
    boost: f32,
) -> vec3<f32> {
    let pearl = vec3<f32>(0.96, 0.94, 0.99);
    let body = smoothstep(hw_rib + aa, hw_rib - aa, d_world) * min(1.0, hw_rib / aa);
    let ratio = clamp(d_world / max(hw_rib, 1e-5), 0.0, 1.0);
    let curve_shade = sqrt(max(1.0 - ratio * ratio, 0.0));
    let enamel = tint * body * (0.055 + 0.085 * curve_shade) * (0.72 + 0.42 * pulse);

    let rim = crisp_line(abs(d_world - hw_rib), 0.0019, aa);
    let rim_col = mix(tint, pearl, 0.22 + 0.18 * pulse) * rim * (1.00 + 0.36 * pulse);

    let spine = crisp_line(d_world, 0.0013 + 0.0007 * pulse, aa);
    let spine_col = mix(tint, pearl, 0.34 + 0.34 * pulse) * spine * (0.34 + 1.02 * pulse);

    let aura = tint * exp(-max(d_world - hw_rib, 0.0) * 115.0) * (0.025 + 0.12 * pulse);

    return (enamel + rim_col + spine_col + aura) * boost;
}

// Over-under basketweave bridge: clears a crisp dark moat around the upper
// ribbon, applies subtle ambient shadow to the passing-under strand, and keeps
// boundary energy identical to non-crossing ribbons at tile edges.
fn composite_weave(
    d_over: f32,
    d_under: f32,
    hw_rib: f32,
    aa: f32,
    tint_over: vec3<f32>,
    tint_under: vec3<f32>,
    pulse: f32,
) -> vec3<f32> {
    let hw_gap = hw_rib + 0.0052;
    let under_mask = smoothstep(hw_gap - aa, hw_gap + aa, d_over);
    let under_ao = 0.56 + 0.44 * smoothstep(hw_gap, hw_gap + 0.016, d_over);
    let over_boost = 1.0 + 0.10 * smoothstep(hw_gap * 2.5, 0.0, d_under);
    let under_col = shade_ribbon(d_under, hw_rib, aa, tint_under, pulse, 1.0) * under_mask * under_ao;
    let over_col = shade_ribbon(d_over, hw_rib, aa, tint_over, pulse, over_boost);
    return under_col + over_col;
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = aspect();
    let px = 1.0 / max(g.target_size.y, 1.0);
    let aa = px * 0.95;

    let mid = vec2<f32>(a * 0.5, 0.5);
    let rot = 0.14 * sin(t * 0.013 + g.seed * TAU) + 0.05 * cos(t * 0.021 + 1.3);
    // ~22.65-degree irrational drift keeps perpendicular velocity high across 0, 90, +45, -45 deg tracks.
    let drift = vec2<f32>(0.052, 0.0217) * t + vec2<f32>(g.seed * 11.3, g.seed * 7.1);
    let scale = 4.15 + 0.22 * sin(t * 0.019 + g.seed * 3.7);
    let q_world = rot2(rot) * (p - mid) - drift;
    let q = q_world * scale;
    let w_scale = 1.0 / scale;

    let cid = floor(q);
    let f = fract(q) - vec2<f32>(0.5);
    let hw_rib = 0.0092;
    let m = morph_factor(t);

    // Globally continuous palette and crossing soliton pulses prevent tile-edge jumps.
    let hue_pos = t * 0.017 + q.x * 0.052 + q.y * 0.038 + 0.14 * sin(q.x * 0.35 - q.y * 0.27 + t * 0.09) + g.seed;
    let tint = weave_palette(hue_pos);

    let wa = fract(dot(q, vec2<f32>(0.21, 0.13)) - t * 0.17 + 0.18 * sin(q.y * 0.45 + t * 0.11) + g.seed) - 0.5;
    let wb = fract(dot(q, vec2<f32>(-0.14, 0.23)) - t * 0.13 + 0.16 * cos(q.x * 0.42 - t * 0.09) + g.seed * 2.7) - 0.5;
    let pulse = clamp(exp(-wa * wa * 34.0) * 0.88 + exp(-wb * wb * 38.0) * 0.72, 0.0, 1.0);

    let h = hash22(cid + vec2<f32>(g.seed * 19.7, g.seed * 31.3));
    var col = vec3<f32>(0.0);

    if (h.x < 0.52) {
        // Cell type 0: subdivided 2x2 fine Truchet (Smith dual arcs + woven crosses).
        let sub_q = (f + vec2<f32>(0.5)) * 2.0;
        let sub_cell = clamp(floor(sub_q), vec2<f32>(0.0), vec2<f32>(1.0));
        let sub_id = cid * 2.0 + sub_cell;
        let sf = fract(sub_q) - vec2<f32>(0.5);
        let sub_scale = 0.5 * w_scale;
        let sh = hash22(sub_id + vec2<f32>(g.seed * 43.1, g.seed * 13.9));

        if (sh.x < 0.76) {
            var sfp = sf;
            if (sh.x >= 0.38) {
                sfp.x = -sfp.x;
            }
            let d1 = sd_morph_arc(sfp - vec2<f32>(0.5, 0.5), 0.5, m);
            let d2 = sd_morph_arc(sfp + vec2<f32>(0.5, 0.5), 0.5, m);
            let d_world = min(d1, d2) * sub_scale;
            col = shade_ribbon(d_world, hw_rib, aa, tint, pulse, 1.0);
        } else {
            let d_h = abs(sf.y) * sub_scale;
            let d_v = abs(sf.x) * sub_scale;
            let h_over = sh.y > 0.5;
            let d_over = select(d_v, d_h, h_over);
            let d_under = select(d_h, d_v, h_over);
            col = composite_weave(d_over, d_under, hw_rib, aa, tint, tint, pulse);
        }
    } else if (h.x < 0.78) {
        // Cell type 1: coarse grand concentric elbow + twin U-returns.
        let rot_idx = u32(floor(h.y * 4.0)) & 3u;
        var rf = f;
        if (rot_idx == 1u) {
            rf = vec2<f32>(-f.y, f.x);
        } else if (rot_idx == 2u) {
            rf = -f;
        } else if (rot_idx == 3u) {
            rf = vec2<f32>(f.y, -f.x);
        }
        let d_small = sd_morph_arc(rf - vec2<f32>(0.5, 0.5), 0.25, m);
        let d_big = sd_morph_arc(rf - vec2<f32>(0.5, 0.5), 0.75, m);
        let d_ul = sd_morph_arc(rf - vec2<f32>(-0.5, 0.0), 0.25, m);
        let d_ub = sd_morph_arc(rf - vec2<f32>(0.0, -0.5), 0.25, m);
        let d_min = min(min(d_small, d_big), min(d_ul, d_ub)) * w_scale;
        let grand_boost = 1.0 + 0.06 * smoothstep(0.08 * w_scale, 0.0, d_big * w_scale) * smoothstep(0.5, 0.35, max(abs(rf.x), abs(rf.y)));
        col = shade_ribbon(d_min, hw_rib, aa, tint, pulse, grand_boost);
    } else if (h.x < 0.90) {
        // Cell type 2: coarse 2x2 alternating basketweave overpass.
        let d_h = abs(abs(f.y) - 0.25) * w_scale;
        let d_v = abs(abs(f.x) - 0.25) * w_scale;
        let q_par = (f.x >= 0.0) == (f.y >= 0.0);
        let h_over = select(!q_par, q_par, h.y > 0.5);
        let d_over = select(d_v, d_h, h_over);
        let d_under = select(d_h, d_v, h_over);
        col = composite_weave(d_over, d_under, hw_rib, aa, tint, tint, pulse);
    } else {
        // Cell type 3: coarse four-corner rosette with an isolated central medallion.
        let d_corner = sd_morph_arc(vec2<f32>(0.5, 0.5) - abs(f), 0.25, m) * w_scale;
        col = shade_ribbon(d_corner, hw_rib, aa, tint, pulse, 1.0);

        let med_tint = weave_palette(hue_pos + 0.36);
        let med_pulse = clamp(pulse * 0.7 + 0.3 * (0.5 + 0.5 * sin(t * 1.15 + h.y * TAU)), 0.0, 1.0);
        let d_med = sd_morph_arc(f, 0.235, m) * w_scale;
        let hw_med = hw_rib * 0.78;
        col = col + shade_ribbon(d_med, hw_med, aa, med_tint, med_pulse, 1.02);

        let d_in = sd_morph_arc(f, 0.115, m) * w_scale;
        let pearl = vec3<f32>(0.96, 0.94, 0.99);
        col = col + mix(med_tint, pearl, 0.35) * crisp_line(d_in, 0.0014, aa) * (0.72 + 0.38 * med_pulse);
        let d_pip = length(f) * w_scale;
        col = col + mix(med_tint, pearl, 0.55) * crisp_line(d_pip, 0.0042, aa) * (0.65 + 0.45 * med_pulse);
    }

    // Soft shoulder keeps pulse intersections crisp without clipping flat white.
    return col / (vec3<f32>(1.0) + col * 0.16);
}

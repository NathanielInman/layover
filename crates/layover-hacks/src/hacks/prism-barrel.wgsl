// Prism Barrel: stained-glass shards, sweeping optical arcs and jewel beads
// tumbling through shifting 12-, 8- and 6-fold mirror chambers.
// After xscreensaver's Kaleidescope (Ron Tapia, 1997).

// Anti-aliased crisp stroke of world half-width `hw` (in canvas heights) with
// pixel filter half-width `aa`. Preserves integrated energy at wear-test resolution.
fn crisp_line(d: f32, hw: f32, aa: f32) -> f32 {
    let cov = clamp((hw + aa - d) / (2.0 * aa), 0.0, 1.0);
    return smoothstep(0.0, 1.0, cov) * min(1.0, hw / aa);
}

// Signed distance from `p` to a circular arc centered at `c` with radius `r`,
// midpoint angle `mid_ang`, and half-aperture `half_ap`.
fn sd_arc(p: vec2<f32>, c: vec2<f32>, r: f32, mid_ang: f32, half_ap: f32) -> f32 {
    var q = rot2(-mid_ang) * (p - c);
    q.y = abs(q.y);
    let sc = vec2<f32>(cos(half_ap), sin(half_ap));
    if (sc.x * q.y > sc.y * q.x) {
        return length(q - sc * r);
    }
    return abs(length(q) - r);
}

// Exact signed distance from `p` to an axis-aligned diamond (rhombus) of half-axes `b`.
fn sd_diamond(p: vec2<f32>, b: vec2<f32>) -> f32 {
    let q = abs(p);
    let e = vec2<f32>(-b.x, b.y);
    let v = q - vec2<f32>(b.x, 0.0);
    let h = clamp(dot(v, e) / max(dot(e, e), 1e-6), 0.0, 1.0);
    let d = length(v - e * h);
    let s = select(1.0, -1.0, (q.x * b.y + q.y * b.x) < (b.x * b.y));
    return d * s;
}

// Cyclical nocturnal stained-glass jewel palette: sapphire, amethyst, amber, jade.
fn prism_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let sapphire = vec3<f32>(0.18, 0.76, 0.96);
    let amethyst = vec3<f32>(0.76, 0.32, 0.94);
    let amber = vec3<f32>(0.98, 0.56, 0.24);
    let jade = vec3<f32>(0.22, 0.88, 0.58);
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

// Nearest hexagonal lattice center offset (unit spacing).
fn hex_offset(u: vec2<f32>) -> vec2<f32> {
    let r = vec2<f32>(1.0, 1.73205081);
    let h = r * 0.5;
    let a = u - r * round(u / r);
    let b = (u - h) - r * round((u - h) / r);
    return select(b, a, dot(a, a) < dot(b, b));
}

// Mode 0 (*632): 30-60-90 triangle mirror chamber -> 12-fold rosettes + 6-fold stars + 4-fold clasps.
// Returns (chamber.x, chamber.y, distance_to_nearest_mirror).
fn fold_632(u: vec2<f32>) -> vec3<f32> {
    var h = abs(hex_offset(u));
    let n60 = vec2<f32>(-0.86602540, 0.5);
    h = h - 2.0 * max(dot(h, n60), 0.0) * n60;
    let n30 = vec2<f32>(-0.5, 0.86602540);
    h = h - 2.0 * max(dot(h, n30), 0.0) * n30;
    let w = h * 2.0;
    let d_m = max(min(w.y, min(1.0 - w.x, -dot(w, n30))), 0.0);
    return vec3<f32>(w.x, w.y, d_m);
}

// Mode 1 (*442): 45-45-90 triangle mirror chamber -> dual 8-fold cathedral rose windows.
fn fold_442(u: vec2<f32>) -> vec3<f32> {
    var f = abs(u - round(u));
    if (f.y > f.x) {
        f = f.yx;
    }
    let w = f * 2.0;
    let d_m = max(min(w.y, min(1.0 - w.x, (w.x - w.y) * 0.70710678)), 0.0);
    return vec3<f32>(w.x, w.y, d_m);
}

// Mode 2 (*333): 60-60-60 equilateral mirror chamber -> interlocking 6-fold blossoms.
fn fold_333(u: vec2<f32>) -> vec3<f32> {
    let h = hex_offset(u);
    let r_len = length(h);
    var w = vec2<f32>(0.0);
    if (r_len > 1e-6) {
        let sector_w = PI / 3.0;
        let u_sec = (atan2(h.y, h.x) + PI / 6.0) / sector_w;
        let sec = i32(floor(u_sec));
        var f = fract(u_sec);
        if ((sec & 1) != 0) {
            f = 1.0 - f;
        }
        let a_f = (f - 0.5) * sector_w;
        w = vec2<f32>(cos(a_f), sin(a_f)) * (r_len * 2.0);
    }
    let d_m = max(min(1.0 - w.x, 0.5 * w.x - 0.86602540 * abs(w.y)), 0.0);
    return vec3<f32>(w.x, w.y, d_m);
}

// Place a drifting point cleanly inside (and gently grazing the mirrors of)
// each fundamental triangle so rosettes weave around every symmetry vertex.
fn chamber_pos(mode: u32, sx: f32, sy: f32) -> vec2<f32> {
    let cx = 0.14 + 0.78 * (0.5 + 0.5 * sx);
    if (mode == 0u) {
        let cy = (0.5 + 0.58 * sy) * (cx * 0.57735027);
        return vec2<f32>(cx, cy);
    }
    if (mode == 1u) {
        let cy = (0.5 + 0.56 * sy) * cx;
        return vec2<f32>(cx, cy);
    }
    let cy = (0.66 * sy) * (cx * 0.57735027);
    return vec2<f32>(cx, cy);
}

fn eval_chamber(
    w: vec2<f32>,
    w_scale: f32,
    d_m: f32,
    mode: u32,
    t: f32,
    aa: f32,
    pan_hue: f32,
) -> vec3<f32> {
    let pearl = vec3<f32>(0.96, 0.94, 0.99);
    var col = vec3<f32>(0.0);
    var local_light = 0.0;

    // Layer 1: Four sweeping optical ribbon arcs curving across all three mirrors.
    for (var i = 0; i < 4; i = i + 1) {
        let fi = f32(i);
        let h = hash22(vec2<f32>(fi * 5.7 + 1.3, f32(mode) * 3.1 + g.seed * 11.0));
        let sx = sin(t * (0.14 + 0.045 * h.x) + fi * 1.9 + g.seed * TAU);
        let sy = cos(t * (0.12 + 0.040 * h.y) + fi * 2.3 + h.x * TAU);
        let center = chamber_pos(mode, sx, sy);
        let radius = 0.21 + 0.055 * fi + 0.035 * sin(t * 0.19 + fi * 1.4);
        let mid_ang = t * (0.28 - 0.10 * fi) * select(-1.0, 1.0, (i & 1) == 0) + h.x * TAU;
        let half_ap = 0.72 + 0.36 * h.y + 0.14 * sin(t * 0.23 + fi);
        let d_w = sd_arc(w, center, radius, mid_ang, half_ap);
        let d_world = d_w * w_scale;

        let line = crisp_line(d_world, 0.0025, aa);
        let aura = exp(-d_world * 85.0) * 0.24;
        let shimmer = 0.78 + 0.22 * sin(t * 0.95 + fi * 1.7 + w.x * 5.0);
        let tint = prism_palette(pan_hue + fi * 0.23 + h.x * 0.35);

        let energy = (line * 1.25 + aura) * shimmer;
        col = col + mix(tint, pearl, 0.20 * line) * energy;
        local_light = local_light + line + aura * 2.0;
    }

    // Layer 2: Six tumbling faceted stained-glass diamond/lozenge shards.
    for (var i = 0; i < 6; i = i + 1) {
        let fi = f32(i);
        let h = hash22(vec2<f32>(fi * 9.1 + 4.2, f32(mode) * 7.3 + g.seed * 17.0));
        let sx = sin(t * (0.11 + 0.035 * h.x) + fi * 1.42 + g.seed * TAU);
        let sy = sin(t * (0.13 + 0.040 * h.y) + fi * 2.09 + 0.8);
        let pos = chamber_pos(mode, sx, sy);
        let spin = t * (0.31 + 0.12 * h.x) * select(-1.0, 1.0, h.y > 0.5) + fi * 1.1;
        let local_p = rot2(-spin) * (w - pos);
        let size = vec2<f32>(
            0.115 + 0.055 * h.x + 0.018 * sin(t * 0.17 + fi),
            0.052 + 0.028 * h.y,
        );
        // Subtle bevel rounding keeps tips razor clean without blobbing.
        let d_w = sd_diamond(local_p, size) - 0.006;
        let d_world = d_w * w_scale;

        let fill = smoothstep(aa, -aa, d_world);
        let rim = crisp_line(abs(d_world), 0.0025, aa);
        let inner_bevel = crisp_line(abs(d_world + 0.011), 0.0011, aa) * fill;

        // Cut-gemstone two-tone facet split along the shard's spine.
        let facet_split = smoothstep(-0.006, 0.006, (local_p.x * 0.78 - local_p.y * 0.62) * w_scale);
        let ridge = crisp_line(abs(local_p.x * 0.78 - local_p.y * 0.62) * w_scale, 0.0010, aa) * fill;
        let glint = 0.35 + 0.65 * facet_split;
        let tint = prism_palette(pan_hue + 0.12 + fi * 0.17 + h.y * 0.25);

        // Dark translucent stained-glass interior stays below LIT so overlapping shards never dwell.
        let glass = tint * fill * (0.052 + 0.062 * glint);
        let bevel_glow = mix(tint, pearl, 0.32) * (inner_bevel * 0.58 + ridge * 0.52) * (0.55 + 0.45 * glint);
        let lead_rim = mix(tint, pearl, 0.26 + 0.18 * glint) * rim * (1.12 + 0.28 * glint);

        col = col + glass + bevel_glow + lead_rim;
        local_light = local_light + rim + fill * 0.28;
    }

    // Layer 3: Four orbiting hollow jewel beads forming crowns at symmetry nodes.
    for (var i = 0; i < 4; i = i + 1) {
        let fi = f32(i);
        let h = hash22(vec2<f32>(fi * 13.7 + 2.9, f32(mode) * 5.9 + g.seed * 23.0));
        let sx = cos(t * (0.16 + 0.04 * h.x) + fi * 2.05 + h.y * TAU);
        let sy = sin(t * (0.15 + 0.05 * h.y) + fi * 1.45 + g.seed * 4.0);
        let pos = chamber_pos(mode, sx, sy);
        let rad = 0.036 + 0.026 * h.x + 0.006 * sin(t * 0.29 + fi * 2.1);
        let d_center = length(w - pos);
        let d_ring = abs(d_center - rad) * w_scale;

        let bezel = crisp_line(d_ring, 0.0021, aa);
        let core_glint = crisp_line(d_center * w_scale, 0.0050, aa);
        let tint = prism_palette(pan_hue + 0.42 + fi * 0.27);

        col = col + mix(tint, pearl, 0.34) * bezel * 1.15;
        col = col + mix(tint, pearl, 0.62) * core_glint * (0.55 + 0.40 * sin(t * 1.3 + fi * 2.0));
        local_light = local_light + bezel;
    }

    // Layer 4: Whisper-faint mirror reflection only where a lit element grazes the glass.
    let mirror_line = crisp_line(d_m * w_scale, 0.0010, aa);
    let mirror_tint = prism_palette(pan_hue + 0.55);
    col = col + mix(mirror_tint, pearl, 0.40) * mirror_line * clamp(local_light, 0.0, 1.0) * 0.18;

    // Soft shoulder keeps overlapping jewel layers crisp without clipping flat white.
    return col / (vec3<f32>(1.0) + col * 0.16);
}

fn eval_mode(
    u: vec2<f32>,
    w_scale: f32,
    mode: u32,
    t: f32,
    aa: f32,
    pan_hue: f32,
) -> vec3<f32> {
    var folded: vec3<f32>;
    if (mode == 0u) {
        folded = fold_632(u);
    } else if (mode == 1u) {
        folded = fold_442(u);
    } else {
        folded = fold_333(u);
    }
    return eval_chamber(folded.xy, w_scale, folded.z, mode, t, aa, pan_hue);
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = aspect();
    let px = 1.0 / max(g.target_size.y, 1.0);
    let aa = px * 0.95;

    let mid = vec2<f32>(a * 0.5, 0.5);
    let rot = t * 0.013 + 0.14 * sin(t * 0.019 + g.seed * TAU) + g.seed * TAU;
    let drift = vec2<f32>(0.074, 0.032) * t + vec2<f32>(g.seed * 7.3, g.seed * 4.1);
    let q_world = rot2(rot) * (p - mid) - drift;

    let scale = 1.02 + 0.08 * sin(t * 0.023 + g.seed * 3.1);
    let u = q_world * scale;
    let w_scale = 0.5 / scale;

    let pan_hue = dot(p, vec2<f32>(0.11, 0.07)) + t * 0.017 + g.seed;

    // Cycle smoothly through 12-fold (*632), 8-fold (*442) and 6-fold (*333) mirror chambers.
    let stage = t / 48.0 + g.seed * 3.0;
    let idx0 = u32(floor(stage)) % 3u;
    let idx1 = (idx0 + 1u) % 3u;
    let blend = smoothstep(0.84, 1.0, fract(stage));

    var col = eval_mode(u, w_scale, idx0, t, aa, pan_hue);
    if (blend > 0.001) {
        let col1 = eval_mode(u, w_scale, idx1, t, aa, pan_hue);
        col = mix(col, col1, blend);
    }
    return col;
}

// Marble Vein: domain-warped marble veins, combed ebru ink plumes and
// iridescent agate strata folding across the dark.
// After xscreensaver's Marbling (Jamie Zawinski and Dave Odell, 2021).

// Anti-aliased crisp stroke of world half-width `hw` (in canvas heights) with
// pixel filter half-width `aa`. Preserves integrated energy at wear-test resolution.
fn crisp_line(d: f32, hw: f32, aa: f32) -> f32 {
    let cov = clamp((hw + aa - d) / (2.0 * aa), 0.0, 1.0);
    return smoothstep(0.0, 1.0, cov) * min(1.0, hw / aa);
}

// Balanced 4-stop nocturnal mineral palette: sapphire, amethyst, amber, jade.
fn marble_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let sapphire = vec3<f32>(0.18, 0.72, 0.98);
    let amethyst = vec3<f32>(0.76, 0.34, 0.94);
    let amber = vec3<f32>(0.98, 0.60, 0.24);
    let jade = vec3<f32>(0.22, 0.88, 0.56);
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

// Smooth 3-mode cycle: (Combed Ebru Plumes, Suminagashi Drops, Brecciated Agate).
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

// Analytical 2D quintic value noise returning (value, d/dx, d/dy).
fn noise_grad(p: vec2<f32>) -> vec3<f32> {
    let i = floor(p);
    let f = fract(p);
    let f2 = f * f;
    let u = f2 * f * (f * (f * 6.0 - 15.0) + 10.0);
    let du = 30.0 * f2 * (f * (f - 2.0) + 1.0);

    let a = hash21(i);
    let b = hash21(i + vec2<f32>(1.0, 0.0));
    let c = hash21(i + vec2<f32>(0.0, 1.0));
    let d = hash21(i + vec2<f32>(1.0, 1.0));

    let k0 = a;
    let k1 = b - a;
    let k2 = c - a;
    let k3 = a - b - c + d;

    let val = k0 + k1 * u.x + k2 * u.y + k3 * u.x * u.y;
    let dx = (k1 + k3 * u.y) * du.x;
    let dy = (k2 + k3 * u.x) * du.y;
    return vec3<f32>(val, dx, dy);
}

// Three-octave rotated fBm returning (value, d/dx, d/dy) in input coordinates.
fn fbm_grad(p: vec2<f32>) -> vec3<f32> {
    var val = 0.0;
    var grad = vec2<f32>(0.0);
    var amp = 0.5;
    var freq = 1.0;
    var ang = 0.0;
    var shift = vec2<f32>(0.0);
    for (var i = 0; i < 3; i = i + 1) {
        let q = rot2(ang) * (p * freq) + shift;
        let ng = noise_grad(q);
        val = val + amp * ng.x;
        grad = grad + (amp * freq) * (rot2(-ang) * ng.yz);
        freq = freq * 2.03;
        amp = amp * 0.5;
        ang = ang + 0.67;
        shift = shift + vec2<f32>(1.73, 9.21);
    }
    return vec3<f32>(val, grad.x, grad.y);
}

// Divergence-free curl displacement derived from a scalar streamfunction.
fn curl_flow(p: vec2<f32>) -> vec2<f32> {
    let fg = fbm_grad(p);
    return vec2<f32>(fg.z, -fg.y);
}

fn smin_smooth(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// Smooth radial suminagashi floating ink-drop potential on a drifting lattice.
fn suminagashi_field(q: vec2<f32>, t: f32) -> f32 {
    let sc = 0.80;
    let qs = q * sc;
    let cid = floor(qs);

    var best_d = 10.0;
    for (var dy = -1; dy <= 1; dy = dy + 1) {
        for (var dx = -1; dx <= 1; dx = dx + 1) {
            let cell = cid + vec2<f32>(f32(dx), f32(dy));
            let h = hash22(cell + vec2<f32>(g.seed * 17.3, g.seed * 29.7));
            let jitter = vec2<f32>(
                0.5 + 0.28 * sin(t * (0.09 + 0.04 * h.x) + h.y * TAU),
                0.5 + 0.28 * cos(t * (0.08 + 0.05 * h.y) + h.x * TAU),
            );
            let rel = (cell + jitter) - qs;
            let d = sqrt(dot(rel, rel) + 0.015);
            if (best_d > 9.0) {
                best_d = d;
            } else {
                best_d = smin_smooth(best_d, d, 0.24);
            }
        }
    }
    return best_d;
}

// Evaluate marbling scalar potential `phi` and auxiliary warp signal at canvas point `p`.
fn eval_marble(
    p: vec2<f32>,
    t: f32,
    mid: vec2<f32>,
    rot: f32,
    drift: vec2<f32>,
    base_scale: f32,
    sw: vec3<f32>,
) -> vec2<f32> {
    let w_ebru = sw.x;
    let w_rings = sw.y;
    let w_agate = sw.z;

    let q0 = (rot2(rot) * (p - mid) - drift) * base_scale;

    // Stage 1: broad incompressible curl advection rolling large ink plumes.
    let s1 = 0.80;
    let c1 = curl_flow(q0 * s1 + vec2<f32>(t * 0.044, -t * 0.031) + vec2<f32>(g.seed * 11.1, 3.7));
    let amp1 = 0.36 * w_ebru + 0.34 * w_rings + 0.48 * w_agate;
    let q1 = q0 + amp1 * c1;

    // Stage 2: secondary curl eddies (restrained in Ebru so combed plumes stay crisp).
    let s2 = 1.42;
    let w2 = fbm_grad(q1 * s2 + vec2<f32>(-t * 0.046, t * 0.052) + vec2<f32>(17.2, g.seed * 5.9));
    let c2 = vec2<f32>(w2.z, -w2.y);
    let amp2 = 0.08 * w_ebru + 0.14 * w_rings + 0.26 * w_agate;
    let q1_eddy = q1 + amp2 * c2;

    // Stage 3: marbler's rake / comb shear pulled across the swirled bath.
    let comb_w = 0.60 * w_ebru + 0.06 * w_rings + 0.10 * w_agate;
    let comb_ph = q1_eddy.y * 3.70 - t * 0.26 + 0.45 * sin(q1_eddy.x * 0.85 + t * 0.13);
    let rake_x = comb_w * (sin(comb_ph) + 0.30 * sin(2.0 * comb_ph + 0.7));
    let comb2_ph = (q1_eddy.x + rake_x) * 2.10 + t * 0.18;
    let rake_y = (0.28 * w_ebru + 0.05 * w_agate) * sin(comb2_ph);
    let q2 = vec2<f32>(q1_eddy.x + rake_x, q1_eddy.y + rake_y);

    // Folded agate/ebru strata + drifting suminagashi drop rings.
    let strata_n = fbm_grad(q2 * 1.10 + vec2<f32>(t * 0.029, -t * 0.025) + vec2<f32>(g.seed * 9.1, 2.3)).x;
    let strata_amp = 0.42 * w_ebru + 0.60 * w_rings + 0.86 * w_agate;
    let strata_val = q2.x * 0.58 + q2.y * 0.96 + strata_amp * (strata_n - 0.5);
    let ring_val = suminagashi_field(q2, t) * 2.65;

    let w_ring_mix = 0.82 * w_rings;
    let phi = mix(strata_val, ring_val, w_ring_mix);
    return vec2<f32>(phi, w2.x);
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = aspect();
    let px = 1.0 / max(g.target_size.y, 1.0);
    let aa = px * 0.95;

    let mid = vec2<f32>(a * 0.5, 0.5);
    let rot = 0.11 * sin(t * 0.015 + g.seed * TAU) + 0.04 * cos(t * 0.023 + 1.1);
    let drift = vec2<f32>(0.062, 0.025) * t + vec2<f32>(g.seed * 13.7, g.seed * 7.9);
    let base_scale = 1.48 + 0.09 * sin(t * 0.019 + g.seed * 3.7);
    let sw = stage_weights(t);
    let w_ebru = sw.x;
    let w_rings = sw.y;
    let w_agate = sw.z;

    let eps = 0.0012;
    let m0 = eval_marble(p, t, mid, rot, drift, base_scale, sw);
    let mx = eval_marble(p + vec2<f32>(eps, 0.0), t, mid, rot, drift, base_scale, sw);
    let my = eval_marble(p + vec2<f32>(0.0, eps), t, mid, rot, drift, base_scale, sw);

    let phi = m0.x;
    let dphi_dp = vec2<f32>(mx.x - phi, my.x - phi) / eps;

    let freq = 2.55 + 0.25 * w_agate + 0.15 * w_rings;
    let psi = phi * freq - t * 0.46;
    let raw_grad = dphi_dp * freq;
    let g_len = length(raw_grad);
    let g_eff = clamp(g_len, 7.5, 34.0);

    let d_primary = abs(fract(psi) - 0.5) / g_eff;
    let d_sub = abs(fract(psi * 2.0 + 0.25) - 0.5) / (g_eff * 2.0);
    let d_crown = abs(fract(psi + 0.5) - 0.5) / g_eff;

    // Nyquist anti-aliasing guard prevents sub-vein stippling on tight curls.
    let nyq = g_len * px;
    let main_vis = smoothstep(1.35, 0.42, nyq);
    let sub_vis = smoothstep(0.68, 0.20, nyq);

    // Two oblique soliton light waves sweeping across the 32:9 panorama.
    let wa = fract(dot(p, vec2<f32>(0.24, 0.14)) - t * 0.17 + 0.14 * sin(p.y * 2.3 + t * 0.09) + g.seed) - 0.5;
    let wb = fract(dot(p, vec2<f32>(-0.15, 0.26)) - t * 0.13 + 0.12 * cos(p.x * 1.6 - t * 0.08) + g.seed * 2.3) - 0.5;
    let pulse = clamp(exp(-wa * wa * 34.0) * 0.85 + exp(-wb * wb * 38.0) * 0.70, 0.0, 1.0);

    // 2.5D mineral surface relief from the potential gradient.
    let n_dir = raw_grad / max(g_len, 1e-4);
    let slope = clamp(g_len * 0.048, 0.0, 1.25);
    let n = normalize(vec3<f32>(-n_dir.x * slope, -n_dir.y * slope, 1.0));
    let light_dir = normalize(vec3<f32>(
        cos(t * 0.23 + g.seed * 2.0),
        sin(t * 0.19 + 1.1),
        0.56,
    ));
    let half_v = normalize(light_dir + vec3<f32>(0.0, 0.0, 1.0));
    let spec = pow(max(dot(n, half_v), 0.0), 18.0);

    let hue_pos = t * 0.017
        + phi * 0.18
        + p.x * 0.08
        + p.y * 0.06
        + 0.12 * (m0.y - 0.5)
        + g.seed;
    let tint = marble_palette(hue_pos);
    let accent = marble_palette(hue_pos + 0.34);
    let crown_tint = marble_palette(hue_pos + 0.62);
    let pearl = vec3<f32>(0.96, 0.94, 0.99);

    // Primary gilded mineral vein + tight ink aura; troughs stay obsidian black.
    let hw_main = 0.0023 + 0.0003 * w_agate + 0.0004 * pulse;
    let vein = crisp_line(d_primary, hw_main, aa) * (0.35 + 0.65 * main_vis);
    let aura = exp(-d_primary * 68.0) * (0.085 + 0.22 * pulse);

    // Secondary capillary thread (feathered comb plume in Ebru, quartz echo in Agate).
    let sub_str = (0.54 * w_ebru + 0.44 * w_rings + 0.58 * w_agate) * sub_vis;
    let sub_vein = crisp_line(d_sub, 0.0011, aa) * sub_str;

    // Counter-phase ink filament along the band centerline.
    let crown_str = (0.48 * w_ebru + 0.36 * w_rings + 0.50 * w_agate) * sub_vis;
    let crown_vein = crisp_line(d_crown, 0.0010, aa) * crown_str;

    // Soft mineral sheen hugging the vein slope; strictly below LIT in troughs.
    let ridge_band = exp(-d_primary * 46.0);
    let mineral_sheen = tint * ridge_band * (0.036 + 0.16 * spec * (0.65 + 0.55 * pulse));

    var col = vec3<f32>(0.0);
    col = col + mix(tint, pearl, 0.28 + 0.24 * pulse) * vein * (1.28 + 0.52 * pulse);
    col = col + tint * aura;
    col = col + mix(accent, pearl, 0.22) * sub_vein * (0.92 + 0.38 * pulse);
    col = col + mix(crown_tint, pearl, 0.26) * crown_vein * (0.78 + 0.36 * pulse);
    col = col + mineral_sheen;

    return col / (vec3<f32>(1.0) + col * 0.18);
}

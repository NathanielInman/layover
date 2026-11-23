// Moire Loom: overlapping elliptical rings and a slowly turning bowed optical
// ruling weave sweeping watered-silk interference bands across the dark.
// After xscreensaver's Moire and Moire2 (Jamie Zawinski).

// Elliptical concentric grating centered at `center`, rotated by `ang` with
// eccentricity `ecc` and wavenumber `k`. Returns (phase, grad_x, grad_y).
fn elliptical_plate(
    p: vec2<f32>,
    center: vec2<f32>,
    ang: f32,
    ecc: f32,
    k: f32,
    phase_off: f32,
) -> vec3<f32> {
    let d = p - center;
    let u = rot2(ang) * d;
    let sc = vec2<f32>(ecc, 1.0 / ecc);
    let e = u * sc;
    let r = sqrt(dot(e, e) + 0.0004);
    let phi = k * r + phase_off;
    let grad = rot2(-ang) * ((e * sc) / r) * k;
    return vec3<f32>(phi, grad.x, grad.y);
}

// Gently bowed straight-line optical ruling anchored at `mid` with orientation
// `ang` and parabolic bow `curve`. Returns (phase, grad_x, grad_y).
fn bowed_plate(
    p: vec2<f32>,
    mid: vec2<f32>,
    ang: f32,
    curve: f32,
    k: f32,
    phase_off: f32,
) -> vec3<f32> {
    let q = p - mid;
    let dir = vec2<f32>(cos(ang), sin(ang));
    let perp = vec2<f32>(-dir.y, dir.x);
    let s_along = dot(dir, q);
    let s_across = dot(perp, q);
    let u = s_along + curve * s_across * s_across;
    let phi = k * u + phase_off;
    let grad = (dir + (2.0 * curve * s_across) * perp) * k;
    return vec3<f32>(phi, grad.x, grad.y);
}

// Band-limited cosine using exact analytical screen-space derivative width
// so energy matches between the 256x72 wear test and 5120x1440 output.
fn aa_cos(phi: f32, grad: vec2<f32>, px: f32) -> f32 {
    let w = length(grad) * px;
    return cos(phi) * exp(-0.5 * w * w * 0.45);
}

// Crisp optical ruling profile: fundamental plus harmonic overtone.
fn silk_thread(phi: f32, grad: vec2<f32>, px: f32) -> f32 {
    let c1 = aa_cos(phi, grad, px);
    let c2 = aa_cos(2.0 * phi, 2.0 * grad, px);
    return clamp(0.34 + 0.54 * c1 + 0.22 * c2, 0.0, 1.0);
}

// Cyclical nocturnal dichroic palette: frost, amethyst, copper-amber, jade.
fn moire_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let frost = vec3<f32>(0.18, 0.74, 0.90);
    let amethyst = vec3<f32>(0.64, 0.36, 0.92);
    let copper = vec3<f32>(0.94, 0.58, 0.34);
    let jade = vec3<f32>(0.26, 0.84, 0.62);
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

// Hue driven smoothly by beat gradient direction without branch-cut seams.
fn beat_tint(g_beat: vec2<f32>, base_hue: f32, offset: f32) -> vec3<f32> {
    let g_len = length(g_beat);
    let dir = g_beat / max(g_len, 1e-4);
    let dir_w = smoothstep(4.0, 28.0, g_len);
    let shift = (0.18 * dir.x + 0.13 * dir.y + 0.07 * (dir.x * dir.x - dir.y * dir.y)) * dir_w;
    return moire_palette(base_hue + offset + shift);
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = aspect();
    let px = 1.0 / max(g.target_size.y, 1.0);
    let mid = vec2<f32>(a * 0.5, 0.5);

    // Two elliptical ring centers sweeping leisurely across the full 32:9 width.
    let c0 = vec2<f32>(
        a * (0.5 + 0.38 * sin(t * 0.0016 + g.seed * TAU) + 0.14 * cos(t * 0.0025 + 1.1)),
        0.5 + 0.34 * cos(t * 0.0021 + g.seed * 4.3) + 0.12 * sin(t * 0.0031 + 2.4),
    );
    let c1 = vec2<f32>(
        a * (0.5 + 0.38 * cos(t * 0.0015 + g.seed * 5.2 + 1.7) + 0.14 * sin(t * 0.0024 + 0.5)),
        0.5 + 0.34 * sin(t * 0.0019 + g.seed * 2.9 + 0.9) + 0.12 * cos(t * 0.0029 + 1.8),
    );

    let ang0 = t * 0.0042 + g.seed * TAU;
    let ecc0 = 1.14 + 0.10 * sin(t * 0.007 + 0.6);
    let ang1 = -t * 0.0037 + g.seed * 3.7 + 1.2;
    let ecc1 = 1.16 + 0.10 * cos(t * 0.008 + 2.1);

    let ang2 = t * 0.0009 + g.seed * TAU + 0.4;
    let curve2 = 0.065 * sin(t * 0.009 + g.seed * 5.1);

    // Detuned breathing wavenumbers prevent zero-frequency overlap cancellation.
    let k0 = 148.0 + 2.5 * sin(t * 0.009 + g.seed * 3.1);
    let k1 = 166.0 + 2.5 * cos(t * 0.008 + g.seed * 6.7);
    let k2 = 156.0 + 2.2 * sin(t * 0.011 + g.seed * 1.9 + 1.2);

    // Phase drifts centered between 0 and 2*PI per second so no beat stalls or aliases at 1 fps.
    let p0 = elliptical_plate(p, c0, ang0, ecc0, k0, t * 1.65 + g.seed * TAU);
    let p1 = elliptical_plate(p, c1, ang1, ecc1, k1, -t * 1.55 + g.seed * 3.1);
    let p2 = bowed_plate(p, mid, ang2, curve2, k2, t * 0.02 + g.seed * 5.3);

    // Three pairwise moire interference beat envelopes and gradients.
    let g01 = p0.yz - p1.yz;
    let g02 = p0.yz - p2.yz;
    let g12 = p1.yz - p2.yz;
    let b01 = aa_cos(p0.x - p1.x, g01, px);
    let b02 = aa_cos(p0.x - p2.x, g02, px);
    let b12 = aa_cos(p1.x - p2.x, g12, px);

    // Sculpt bright silk interference bands with pure black troughs.
    let s01 = smoothstep(0.14, 0.97, b01);
    let r01 = s01 * s01;
    let s02 = smoothstep(0.20, 0.97, b02);
    let r02 = s02 * s02;
    let s12 = smoothstep(0.20, 0.97, b12);
    let r12 = s12 * s12;

    // Fine optical grating threads modulated inside each moire ribbon.
    let t0 = silk_thread(p0.x, p0.yz, px);
    let t1 = silk_thread(p1.x, p1.yz, px);
    let t2 = silk_thread(p2.x, p2.yz, px);
    let weave01 = mix(0.28, 1.0, max(t0, t1) * 0.52 + (t0 * t1) * 0.72);
    let weave02 = mix(0.28, 1.0, max(t0, t2) * 0.52 + (t0 * t2) * 0.72);
    let weave12 = mix(0.28, 1.0, max(t1, t2) * 0.52 + (t1 * t2) * 0.72);
    let weave_triple = mix(0.35, 1.0, t0 * t1 * 0.6 + t2 * 0.4);

    // Subtle crisp crest spine along the primary constructive band.
    let crest01 = smoothstep(0.70, 0.98, b01);
    let spine01 = crest01 * crest01;

    let base_hue = t * 0.017 + g.seed * 0.7;
    let col01 = beat_tint(g01, base_hue, 0.0);
    let col02 = beat_tint(g02, base_hue, 0.33);
    let col12 = beat_tint(g12, base_hue, 0.66);
    let pearl = vec3<f32>(0.92, 0.88, 0.96);

    var col = vec3<f32>(0.0);
    col = col + col01 * (r01 * weave01 * 0.68 + spine01 * 0.28);
    col = col + col02 * (r02 * weave02 * 0.42);
    col = col + col12 * (r12 * weave12 * 0.40);

    let triple = r01 * r02 + r01 * r12 + r02 * r12;
    col = col + mix(col01, pearl, 0.55) * triple * weave_triple * 0.24;

    return col;
}

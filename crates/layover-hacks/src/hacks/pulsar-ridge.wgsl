// Pulsar Ridge: scrolling hidden-line radio-pulse ridgelines rising and
// subsiding across the dark.
// After xscreensaver's Unknown Pleasures (Jamie Zawinski, 2012).

const ROW_DY: f32 = 0.040;
const ROW_RATE: f32 = 0.413;
const CELL_W: f32 = 1.24;
const H_MAX: f32 = 0.26;

// Anti-aliased crisp stroke of world half-width `hw` (in canvas heights) with
// pixel filter half-width `aa`. Preserves integrated energy at wear-test resolution.
fn crisp_line(d: f32, hw: f32, aa: f32) -> f32 {
    let cov = clamp((hw + aa - d) / (2.0 * aa), 0.0, 1.0);
    return smoothstep(0.0, 1.0, cov) * min(1.0, hw / aa);
}

// Cyclical nocturnal dichroic palette: sapphire, amethyst, amber, jade.
fn ridge_palette(x: f32) -> vec3<f32> {
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

// Evaluate one pulsar massif cell `c` at `x_drift` and row `fk`.
// Returns (height, dheight/dx).
fn pulsar_cell(x_drift: f32, c: f32, fk: f32, t: f32) -> vec2<f32> {
    let u_cell = x_drift - c * CELL_W;
    let q = u_cell / CELL_W;
    if (abs(q) >= 1.0) {
        return vec2<f32>(0.0, 0.0);
    }

    let hc = hash11(c * 17.3 + g.seed * 31.1);
    let hc2 = hash11(c * 29.7 + g.seed * 19.3 + 5.1);

    // Coherent row-to-row activity swell so massifs build into sharp alpine bursts and subside.
    let burst_wave = 0.5 + 0.5 * sin(fk * 0.21 + hc * TAU + 0.85 * sin(fk * 0.071 + hc2 * TAU));
    let ridge_active = smoothstep(0.18, 0.80, burst_wave);

    var inner = 0.0;
    var d_inner = 0.0;

    // Broad massif carrier plus four tighter pulsar sub-peaks drifting diagonally across rows.
    for (var j = 0; j < 5; j = j + 1) {
        let fj = f32(j);
        let h = hash22(vec2<f32>(c * 7.3 + fj * 11.9, g.seed * 23.0 + fj * 3.7));
        let row_spur = (hash11(fk * 1.9 + fj * 13.1 + c * 5.3) - 0.5) * select(0.75, 0.22, j == 0);
        let center_off = select(
            (h.x - 0.5) * 0.34 + 0.11 * sin(fk * (0.22 + 0.05 * fj) + t * (0.10 + 0.04 * h.y) + h.y * TAU),
            (h.x - 0.5) * 0.14 + 0.06 * sin(fk * 0.13 + t * 0.05 + hc * TAU),
            j == 0,
        );
        let sigma = select(0.013 + 0.015 * h.y, 0.048 + 0.024 * h.y, j == 0);
        let amp_base = select(0.068 + 0.078 * h.x, 0.090 + 0.060 * h.x, j == 0);
        let pulse_breathe = 0.50 + 0.50 * sin(fk * (0.33 + 0.11 * fj) + t * (0.15 + 0.07 * h.y) + h.x * TAU);
        let amp = amp_base * (0.18 + 0.92 * ridge_active) * clamp(pulse_breathe + row_spur, 0.04, 1.45);

        let u = u_cell - center_off;
        let inv_s2 = 1.0 / (sigma * sigma);
        let g_val = amp * exp(-0.5 * u * u * inv_s2);
        inner = inner + g_val;
        d_inner = d_inner - g_val * u * inv_s2;
    }

    // Fine radio-pulse serration inside active peaks so slopes read like oscilloscope traces.
    let ph_a = u_cell * 52.0 + fk * 2.31 + t * 0.37;
    let ph_b = u_cell * 88.0 - fk * 3.77 - t * 0.23;
    let tremor = 1.0 + 0.065 * sin(ph_a) + 0.040 * sin(ph_b);
    let d_tremor = 0.065 * 52.0 * cos(ph_a) + 0.040 * 88.0 * cos(ph_b);
    let mod_inner = inner * tremor;
    let d_mod_inner = d_inner * tremor + inner * d_tremor;

    // C2-smooth compact cell window on |q| <= 1 so only two neighboring cells overlap.
    let s = 1.0 - q * q;
    let env = s * s * s;
    let d_env = -6.0 * s * s * q / CELL_W;

    return vec2<f32>(env * mod_inner, d_env * mod_inner + env * d_mod_inner);
}

// Evaluate ridgeline `fk` at horizontal position `x`.
// Returns (capped_height, d(capped_height)/dx, normalized_energy).
fn ridge_eval(x: f32, fk: f32, t: f32) -> vec3<f32> {
    let x_drift = x - t * 0.042 + 0.16 * sin(fk * 0.11 + t * 0.05 + g.seed * TAU) + g.seed * 13.7;
    let c0 = floor(x_drift / CELL_W);

    let p0 = pulsar_cell(x_drift, c0, fk, t);
    let p1 = pulsar_cell(x_drift, c0 + 1.0, fk, t);

    // Subtle living oscilloscope micro-ripple along quiet flanks.
    let r_phase0 = hash11(fk * 3.17 + g.seed * 11.0) * TAU;
    let r_phase1 = hash11(fk * 7.43 + g.seed * 19.0) * TAU;
    let k0 = 18.0;
    let k1 = 35.0;
    let a0 = 0.0016;
    let a1 = 0.0010;
    let w0 = x * k0 + t * 0.61 + r_phase0;
    let w1 = x * k1 - t * 0.43 + r_phase1;
    let ripple = a0 * (1.0 + sin(w0)) + a1 * (1.0 + sin(w1));
    let d_ripple = a0 * k0 * cos(w0) + a1 * k1 * cos(w1);

    let h_raw = max(p0.x + p1.x + ripple, 0.0);
    let dh_raw = p0.y + p1.y + d_ripple;

    // Smooth rational cap guarantees height strictly below H_MAX.
    let denom = 1.0 + h_raw / 0.245;
    let hc = h_raw / denom;
    let dhc = dh_raw / (denom * denom);
    let energy = clamp((hc - 0.005) / 0.145, 0.0, 1.0);

    return vec3<f32>(hc, dhc, energy);
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let px = 1.0 / max(g.target_size.y, 1.0);
    let aa = px * 0.95;

    let scroll = t * ROW_RATE + g.seed * 100.0;
    let k_top = i32(floor((p.y + 0.09) / ROW_DY + scroll));
    let k_bot = i32(floor((p.y - H_MAX - 0.05) / ROW_DY + scroll));

    let pearl = vec3<f32>(0.97, 0.94, 0.99);
    var col = vec3<f32>(0.0);

    // Paint back-to-front so nearer (lower) ridges cleanly occlude farther peaks.
    for (var k = k_top; k >= k_bot; k = k - 1) {
        let fk = f32(k);
        let y_base = (fk - scroll) * ROW_DY;
        let eval = ridge_eval(p.x, fk, t);
        let hc = eval.x;
        let dhc = eval.y;
        let energy = eval.z;

        let y_r = y_base + hc;
        let d_vert = p.y - y_r;
        let d_perp = d_vert * inverseSqrt(1.0 + dhc * dhc);

        // Opaque dark body occludes everything behind this ridgeline.
        let body = 1.0 - smoothstep(-aa, aa, d_perp);
        col = col * (1.0 - body);

        let hue_pos = t * 0.017 + p.x * 0.09 + fk * 0.022 + energy * 0.30 + g.seed;
        let crest_tint = ridge_palette(hue_pos);
        let echo_tint = ridge_palette(hue_pos + 0.16);
        let shimmer = 0.84 + 0.16 * sin(p.x * 3.8 - t * 1.15 + fk * 0.73);

        // Subtle under-crest rim wash and secondary contour echo inside the dark slope.
        let rim_wash = exp(-max(-d_perp, 0.0) * 68.0) * (0.04 + 0.22 * energy);
        let contour = crisp_line(abs(d_perp + 0.0085), 0.0008, aa) * smoothstep(0.045, 0.12, hc) * 0.48;
        col = col + echo_tint * (rim_wash + contour) * body * shimmer;

        // Crisp glowing ridgeline crest and tight upward peak halo.
        let hw = 0.0014 + 0.0015 * energy;
        let crest = crisp_line(abs(d_perp), hw, aa);
        let halo = exp(-max(d_perp, 0.0) * 105.0) * (0.02 + 0.21 * energy);
        let crest_col = mix(crest_tint, pearl, 0.10 + 0.26 * energy);
        let crest_boost = 0.62 + 0.68 * energy;
        col = col + crest_col * (crest * crest_boost + halo) * shimmer;
    }

    // Soft shoulder keeps overlapping crest highlights vivid without clipping flat white.
    return col / (vec3<f32>(1.0) + col * 0.14);
}

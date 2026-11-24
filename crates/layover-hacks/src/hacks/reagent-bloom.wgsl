// Reagent Bloom: reaction-diffusion waves, curling spirals and coral blooms
// drifting across the dark.
// After xscreensaver's RD-Bomb (Scott Draves, 1997).

const DU: f32 = 1.0;
const DV: f32 = 0.5;
const SIM_DT: f32 = 0.95;
const BOMB_PERIOD: f32 = 1.8;

fn toroidal_delta_p(uv: vec2<f32>, center_uv: vec2<f32>) -> vec2<f32> {
    let d = fract(uv - center_uv + 0.5) - 0.5;
    return vec2<f32>(d.x * aspect(), d.y);
}

// Balanced 6-stop nocturnal jewel wheel keeping R/G/B channel shares even.
fn reagent_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let sapphire = vec3<f32>(0.14, 0.56, 0.98);
    let cyan = vec3<f32>(0.12, 0.88, 0.90);
    let seafoam = vec3<f32>(0.18, 0.92, 0.56);
    let gold = vec3<f32>(0.94, 0.72, 0.18);
    let rose = vec3<f32>(0.96, 0.24, 0.54);
    let orchid = vec3<f32>(0.64, 0.28, 0.98);
    let s = p * 6.0;
    if (s < 1.0) {
        return mix(sapphire, cyan, smoothstep(0.0, 1.0, s));
    }
    if (s < 2.0) {
        return mix(cyan, seafoam, smoothstep(0.0, 1.0, s - 1.0));
    }
    if (s < 3.0) {
        return mix(seafoam, gold, smoothstep(0.0, 1.0, s - 2.0));
    }
    if (s < 4.0) {
        return mix(gold, rose, smoothstep(0.0, 1.0, s - 3.0));
    }
    if (s < 5.0) {
        return mix(rose, orchid, smoothstep(0.0, 1.0, s - 4.0));
    }
    return mix(orchid, sapphire, smoothstep(0.0, 1.0, s - 5.0));
}

// Cycle smoothly across three active Gray-Scott regimes:
// (Concentric Pulse Waves, Curling Labyrinth, Branching Coral).
fn chemistry_params(t: f32, uv: vec2<f32>) -> vec2<f32> {
    let stage = t / 42.0 + g.seed * 3.0;
    let idx0 = u32(floor(stage)) % 3u;
    let blend = smoothstep(0.70, 1.0, fract(stage));
    let a = 1.0 - blend;
    var w = vec3<f32>(blend, 0.0, a);
    if (idx0 == 0u) {
        w = vec3<f32>(a, blend, 0.0);
    } else if (idx0 == 1u) {
        w = vec3<f32>(0.0, a, blend);
    }

    let fk0 = vec2<f32>(0.022, 0.0485);
    let fk1 = vec2<f32>(0.030, 0.0555);
    let fk2 = vec2<f32>(0.038, 0.0585);
    var fk = fk0 * w.x + fk1 * w.y + fk2 * w.z;

    // Gentle spatial modulation so multiple morphologies coexist across 32:9.
    let mod_f = 0.0018 * sin(uv.x * TAU * 2.0 + t * 0.08) * cos(uv.y * TAU + t * 0.06);
    let mod_k = 0.0007 * cos(uv.x * TAU * 3.0 - t * 0.07);
    fk = fk + vec2<f32>(mod_f, mod_k);

    // Narrow traveling inhibitory quench tide: sweeps gently across ~24% of each
    // wave cycle so colonies bloom freely while never stalling past max_dwell.
    let waves = max(1.0, round(aspect() * 0.55));
    let tide_phase = uv.x * waves - t * 0.050 + 0.14 * sin(uv.y * TAU + t * 0.19) + g.seed;
    let quench = smoothstep(0.76, 0.97, 0.5 + 0.5 * cos(tide_phase * TAU));
    fk.y = fk.y + 0.028 * quench;
    return fk;
}

fn bomb_mask(uv: vec2<f32>, center_uv: vec2<f32>, r_world: f32, kind: f32) -> f32 {
    let dp = toroidal_delta_p(uv, center_uv);
    let d = length(dp);
    let px_h = max(state_texel().y, 1.0 / 240.0);
    let edge = 1.3 * px_h;
    if (kind < 0.34) {
        // Broken crescent ring that curls straight into spirals.
        let ring_r = r_world * 0.68;
        let ring_w = max(r_world * 0.24, 1.8 * px_h);
        let ring = 1.0 - smoothstep(ring_w - edge, ring_w + edge, abs(d - ring_r));
        let ang = atan2(dp.y, dp.x) - kind * 23.0;
        let gap = smoothstep(-0.35, 0.25, cos(ang));
        return ring * gap;
    }
    if (kind < 0.68) {
        // Hollow RD-Bomb ring with a small core seed.
        let ring_r = r_world * 0.74;
        let ring_w = max(r_world * 0.22, 1.7 * px_h);
        let ring = 1.0 - smoothstep(ring_w - edge, ring_w + edge, abs(d - ring_r));
        let core = 1.0 - smoothstep(ring_w - edge, ring_w + edge, d);
        return max(ring, core * 0.9);
    }
    // Asymmetric cluster of three off-center droplets for organic branching.
    var m = 0.0;
    let r2 = max(r_world * 0.34, 1.9 * px_h);
    for (var i: i32 = 0; i < 3; i = i + 1) {
        let ang = kind * 17.0 + f32(i) * 2.15 + 0.4 * sin(f32(i) * 3.1);
        let off = vec2<f32>(cos(ang), sin(ang)) * (r_world * (0.42 + 0.14 * f32(i)));
        let di = length(dp - off);
        m = max(m, 1.0 - smoothstep(r2 - edge, r2 + edge, di));
    }
    return m;
}

fn apply_bomb(
    uv: vec2<f32>,
    center_uv: vec2<f32>,
    r_world: f32,
    kind: f32,
    bomb_phase: f32,
    u_in: ptr<function, f32>,
    v_in: ptr<function, f32>,
    col_dir_in: ptr<function, vec2<f32>>,
    col_w_in: ptr<function, f32>,
) {
    let m = bomb_mask(uv, center_uv, r_world, kind);
    if (m > 0.01) {
        *u_in = min(*u_in, mix(1.0, 0.45, m));
        *v_in = max(*v_in, 0.38 * m);
        let dir = vec2<f32>(cos(bomb_phase * TAU), sin(bomb_phase * TAU));
        *col_dir_in = mix(*col_dir_in, dir, clamp(m * 1.2, 0.0, 1.0));
        *col_w_in = max(*col_w_in, m);
    }
}

// State channels: x = u, y = v, (z, w) = glow * (cos(hue), sin(hue)).
// Storing hue as a 2D vector avoids branch-cut seams under linear filtering.
fn step_state(uv: vec2<f32>, _p: vec2<f32>, t: f32) -> vec4<f32> {
    if (g.frame < 0.5) {
        var u = 1.0;
        var v = 0.0;
        var col_dir = vec2<f32>(1.0, 0.0);
        var col_w = 0.0;
        let min_r = max(0.052, 3.8 * state_texel().y);
        let n_init = i32(clamp(round(aspect() * 3.8), 6.0, 14.0));
        for (var i: i32 = 0; i < 14; i = i + 1) {
            if (i >= n_init) {
                break;
            }
            let fi = f32(i);
            let h = hash22(vec2<f32>(fi * 7.13 + g.seed * 41.0, g.seed * 19.7 + fi));
            let center = vec2<f32>((fi + 0.12 + 0.76 * h.x) / f32(n_init), 0.14 + 0.72 * h.y);
            let r = min_r + 0.044 * hash11(fi * 3.7 + g.seed * 11.3);
            let kind = hash11(fi * 9.1 + g.seed * 23.0);
            let b_phase = fract(fi / f32(n_init) + g.seed * 2.3);
            apply_bomb(uv, center, r, kind, b_phase, &u, &v, &col_dir, &col_w);
        }
        let glow0 = clamp(v * 0.9, 0.0, 1.0);
        return vec4<f32>(u, v, col_dir * glow0);
    }

    let prev = state_sample(uv);
    let lap = state_laplacian(uv);
    let u = clamp(prev.x, 0.0, 1.0);
    let v = clamp(prev.y, 0.0, 1.0);
    let fk = chemistry_params(t, uv);
    let f = fk.x;
    let k = fk.y;

    let uvv = u * v * v;
    var u_next = clamp(u + (DU * lap.x - uvv + f * (1.0 - u)) * SIM_DT, 0.0, 1.0);
    var v_next = clamp(v + (DV * lap.y + uvv - (f + k) * v) * SIM_DT, 0.0, 1.0);

    // Smooth vector diffusion of colony hue weighted by neighbor catalyst `v`.
    let d = state_texel();
    let n0 = state_sample(uv + vec2<f32>(d.x, 0.0));
    let n1 = state_sample(uv - vec2<f32>(d.x, 0.0));
    let n2 = state_sample(uv + vec2<f32>(0.0, d.y));
    let n3 = state_sample(uv - vec2<f32>(0.0, d.y));
    let dir_sum = prev.zw * (v + 0.05)
        + n0.zw * (n0.y * 0.55)
        + n1.zw * (n1.y * 0.55)
        + n2.zw * (n2.y * 0.55)
        + n3.zw * (n3.y * 0.55);
    let dir_len = length(dir_sum);
    var col_dir = select(vec2<f32>(1.0, 0.0), dir_sum / max(dir_len, 1e-6), dir_len > 1e-5);
    var bomb_w = 0.0;

    // Periodic reagent bomb drops distributed evenly across all active waves.
    let slot = floor(t / BOMB_PERIOD);
    let local_t = fract(t / BOMB_PERIOD) * BOMB_PERIOD;
    if (local_t < 0.25) {
        let waves = max(1.0, round(aspect() * 0.55));
        let bombs = i32(clamp(round(aspect() * 1.1), 2.0, 4.0));
        let min_r = max(0.050, 3.8 * state_texel().y);
        for (var b: i32 = 0; b < 4; b = b + 1) {
            if (b >= bombs) {
                break;
            }
            let fb = f32(b);
            let h = hash22(vec2<f32>(slot * 13.7 + fb * 5.3, g.seed * 37.1 + fb * 9.7));
            let kind = hash11(slot * 7.9 + fb * 17.3 + g.seed * 13.1);
            let crest = 0.50 + (h.x - 0.5) * 0.42;
            let wave_idx = fb + floor(hash11(slot * 5.3 + fb * 11.7) * waves);
            let active_x = fract((t * 0.050 - g.seed + crest + wave_idx) / waves);
            let center = vec2<f32>(active_x, 0.14 + 0.72 * h.y);
            let r = min_r + 0.044 * hash11(slot * 3.1 + fb * 11.1);
            let b_phase = fract(slot * 0.21 + fb * 0.37 + g.seed);
            apply_bomb(uv, center, r, kind, b_phase, &u_next, &v_next, &col_dir, &bomb_w);
        }
    }

    // Active reaction front + strictly decayed glow magnitude encoded into `zw`.
    let prev_glow = length(prev.zw);
    let front = clamp(u_next * v_next * 5.8, 0.0, 1.0);
    let glow = clamp(max(prev_glow * g.fade, max(front * 0.92, bomb_w * 0.65)), 0.0, 1.0);
    let dir_norm = normalize(col_dir + vec2<f32>(1e-6, 0.0));

    return vec4<f32>(u_next, v_next, dir_norm * glow);
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    // Gentle monotonic drift on the toroidal state canvas so nothing ever sits still.
    let drift = vec2<f32>(t * 0.044 / aspect(), t * 0.012 + 0.010 * sin(t * 0.17));
    let uv = fract(state_uv(p) + drift);

    let s = state_sample(uv);
    let d = state_texel() * 1.15;
    let vx0 = state_sample(uv - vec2<f32>(d.x, 0.0)).y;
    let vx1 = state_sample(uv + vec2<f32>(d.x, 0.0)).y;
    let vy0 = state_sample(uv - vec2<f32>(0.0, d.y)).y;
    let vy1 = state_sample(uv + vec2<f32>(0.0, d.y)).y;
    let grad = vec2<f32>(vx1 - vx0, vy1 - vy0);
    let grad_mag = length(grad);

    let u = clamp(s.x, 0.0, 1.0);
    let v = clamp(s.y, 0.0, 1.0);
    let glow = clamp(length(s.zw), 0.0, 1.0);
    let hue_phase = fract(atan2(s.w, s.z) / TAU);

    // Sculpted liquid-ridge lighting across the catalyst surface.
    let n = normalize(vec3<f32>(-grad.x * 18.0, -grad.y * 18.0, 1.0));
    let l_dir = normalize(vec3<f32>(0.42 * cos(t * 0.19), 0.36 * sin(t * 0.14) + 0.25, 0.85));
    let half_v = normalize(l_dir + vec3<f32>(0.0, 0.0, 1.0));
    let spec = pow(max(dot(n, half_v), 0.0), 24.0);
    let rim = pow(clamp(1.0 - n.z, 0.0, 1.0), 1.6);

    // Bright advancing reaction-front membrane + sculpted edges + iso-contour filaments.
    let front = smoothstep(0.016, 0.13, u * v) * (1.0 - 0.55 * smoothstep(0.28, 0.50, v));
    let membrane = smoothstep(0.012, 0.13, grad_mag) * smoothstep(0.025, 0.20, v);
    let iso = pow(0.5 + 0.5 * cos(v * 34.0 - t * 0.75), 4.5)
        * smoothstep(0.06, 0.34, v)
        * smoothstep(0.04, 0.18, u);

    let base_col = reagent_palette(hue_phase + v * 0.16 + t * 0.008);
    let crest_col = reagent_palette(hue_phase + v * 0.16 + 0.08 + u * 0.08 + t * 0.008);

    var col = base_col * (glow * glow * 0.34 + front * 0.50 + membrane * 0.44);
    col = col + crest_col * (iso * 0.52 + rim * (front + membrane) * 0.42);
    col = col + mix(crest_col, vec3<f32>(0.92, 0.96, 1.0), 0.45) * (spec * (front * 0.58 + membrane * 0.72));

    return clamp(col, vec3<f32>(0.0), vec3<f32>(1.0));
}

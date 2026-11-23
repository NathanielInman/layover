// Flux Grid: an undulating 3D wave-lattice canopy with wireframe ribs,
// faceted lit tiles, checker inlays and rolling sinusoidal color swells.
// After xscreensaver's Gflux (Josiah Pease, 2000) and CWaves (Jamie Zawinski, 2007).

// Anti-aliased crisp stroke of half-width `hw` with pixel filter half-width `aa`.
// Preserves integrated energy at wear-test resolution.
fn crisp_line(d: f32, hw: f32, aa: f32) -> f32 {
    let cov = clamp((hw + aa - d) / (2.0 * aa), 0.0, 1.0);
    return smoothstep(0.0, 1.0, cov) * min(1.0, hw / aa);
}

// Balanced 4-stop nocturnal jewel palette: sapphire, orchid, amber, viridian.
fn flux_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let sapphire = vec3<f32>(0.18, 0.74, 0.98);
    let orchid = vec3<f32>(0.78, 0.34, 0.94);
    let amber = vec3<f32>(0.98, 0.60, 0.24);
    let viridian = vec3<f32>(0.20, 0.88, 0.58);
    let s = p * 4.0;
    if (s < 1.0) {
        return mix(sapphire, orchid, smoothstep(0.0, 1.0, s));
    }
    if (s < 2.0) {
        return mix(orchid, amber, smoothstep(0.0, 1.0, s - 1.0));
    }
    if (s < 3.0) {
        return mix(amber, viridian, smoothstep(0.0, 1.0, s - 2.0));
    }
    return mix(viridian, sapphire, smoothstep(0.0, 1.0, s - 3.0));
}

// Smooth 3-mode cycle: (Wireframe + Sub-grid, Faceted Lit Tiles, Dichroic Checker Matrix).
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

// World-space Gflux radial ripple center `i` drifting across the 32:9 panorama.
fn ripple_center(i: i32, t: f32) -> vec2<f32> {
    let fi = f32(i);
    let h = hash22(vec2<f32>(fi * 13.7 + 1.9, g.seed * 31.3 + fi * 5.3));
    let home_x = -2.25 + 1.50 * fi;
    let x = home_x
        + 0.85 * sin(t * (0.043 + 0.017 * h.x) + fi * 2.1 + g.seed * TAU)
        + 0.35 * cos(t * (0.071 + 0.013 * h.y) + fi * 0.9);
    let y = 1.15
        + 0.48 * sin(t * (0.053 + 0.019 * h.y) + fi * 1.7 + g.seed * 4.3)
        + 0.18 * cos(t * (0.083 + 0.011 * h.x) + fi * 2.7);
    return vec2<f32>(x, y);
}

// Evaluate combined CWaves plane swells + Gflux radial ripples.
// Returns (height, dH/d(hit_xy.x), dH/d(hit_xy.y), cwave_color_phase).
fn wave_eval(
    hit_xy: vec2<f32>,
    yaw: f32,
    grid_scale: f32,
    drift: vec2<f32>,
    t: f32,
) -> vec4<f32> {
    let rot_m = rot2(yaw);
    let inv_rot = rot2(-yaw);
    let u = (rot_m * hit_xy) * grid_scale + drift;

    var h_val = 0.0;
    var grad_u = vec2<f32>(0.0);
    var cwave = 0.0;

    // 1. CWaves: 4 incommensurate sinusoidal swells gliding through lattice space.
    let dirs = array<vec2<f32>, 4>(
        vec2<f32>(0.8200, 0.5724),
        vec2<f32>(-0.6100, 0.7924),
        vec2<f32>(0.3400, -0.9404),
        vec2<f32>(0.9500, -0.3122),
    );
    let freqs = array<f32, 4>(0.58, 0.83, 1.14, 0.42);
    let speeds = array<f32, 4>(0.41, -0.33, 0.27, -0.19);
    let amps = array<f32, 4>(0.044, 0.034, 0.024, 0.036);
    let seed_offs = array<f32, 4>(0.0, 3.7, 5.3, 1.9);

    for (var i = 0; i < 4; i = i + 1) {
        let dir = dirs[i];
        let freq = freqs[i];
        let ph = dot(u, dir) * freq - t * speeds[i] + g.seed * (TAU + seed_offs[i]);
        let amp = amps[i];
        h_val = h_val + amp * sin(ph);
        grad_u = grad_u + dir * (amp * freq * cos(ph));
        cwave = cwave + (0.28 - 0.04 * f32(i)) * cos(ph * 0.72 + t * 0.08 * f32(i + 1));
    }

    var grad_xy = inv_rot * (grad_u * grid_scale);

    // 2. Gflux: 4 world-space radial ripple centers with birth/fade envelopes.
    let r_freqs = array<f32, 4>(6.2, 7.4, 5.5, 8.1);
    let r_speeds = array<f32, 4>(1.55, 1.85, 1.35, 2.05);
    for (var j = 0; j < 4; j = j + 1) {
        let fj = f32(j);
        let c = ripple_center(j, t);
        let d = hit_xy - c;
        let r2 = dot(d, d);
        let r = sqrt(r2 + 0.08);
        let breath = 0.56 + 0.44 * sin(t * (0.14 + 0.03 * fj) + fj * 2.3 + g.seed * 7.1);
        let denom = 1.0 + r2 * 0.42;
        let att = 0.032 * breath / denom;
        let d_att_dr2 = -0.032 * breath * 0.42 / (denom * denom);
        let k = r_freqs[j];
        let ph = k * r - t * r_speeds[j] + fj * 1.4;
        let s = sin(ph);
        let cs = cos(ph);
        h_val = h_val + att * s;
        // Exact analytical chain rule: d/d(hit_xy) [att(r^2) * sin(k*r - w*t)]
        let radial_factor = (2.0 * d_att_dr2 * s) + (att * k * cs / r);
        grad_xy = grad_xy + d * radial_factor;
    }

    return vec4<f32>(h_val, grad_xy.x, grad_xy.y, cwave);
}

// Fast scalar height-only check for ray-heightfield bracket stepping.
fn wave_height(
    hit_xy: vec2<f32>,
    yaw: f32,
    grid_scale: f32,
    drift: vec2<f32>,
    t: f32,
) -> f32 {
    let u = (rot2(yaw) * hit_xy) * grid_scale + drift;
    var h_val = 0.0;

    h_val = h_val + 0.044 * sin(dot(u, vec2<f32>(0.8200, 0.5724)) * 0.58 - t * 0.41 + g.seed * TAU);
    h_val = h_val + 0.034 * sin(dot(u, vec2<f32>(-0.6100, 0.7924)) * 0.83 + t * 0.33 + g.seed * (TAU + 3.7));
    h_val = h_val + 0.024 * sin(dot(u, vec2<f32>(0.3400, -0.9404)) * 1.14 - t * 0.27 + g.seed * (TAU + 5.3));
    h_val = h_val + 0.036 * sin(dot(u, vec2<f32>(0.9500, -0.3122)) * 0.42 + t * 0.19 + g.seed * (TAU + 1.9));

    let r_freqs = array<f32, 4>(6.2, 7.4, 5.5, 8.1);
    let r_speeds = array<f32, 4>(1.55, 1.85, 1.35, 2.05);
    for (var j = 0; j < 4; j = j + 1) {
        let fj = f32(j);
        let c = ripple_center(j, t);
        let d = hit_xy - c;
        let r2 = dot(d, d);
        let r = sqrt(r2 + 0.08);
        let breath = 0.56 + 0.44 * sin(t * (0.14 + 0.03 * fj) + fj * 2.3 + g.seed * 7.1);
        let att = 0.032 * breath / (1.0 + r2 * 0.42);
        h_val = h_val + att * sin(r_freqs[j] * r - t * r_speeds[j] + fj * 1.4);
    }

    return h_val;
}

fn ray_f(
    ro: vec3<f32>,
    ray: vec3<f32>,
    tau: f32,
    yaw: f32,
    grid_scale: f32,
    drift: vec2<f32>,
    t: f32,
) -> f32 {
    let pos3 = ro + ray * tau;
    return pos3.z - wave_height(pos3.xy, yaw, grid_scale, drift, t);
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = aspect();
    let uv = p - vec2<f32>(a * 0.5, 0.5);

    // Oblique downward-gazing 3D camera spanning the full 32:9 horizonless canopy.
    let ro = vec3<f32>(0.0, 0.0, 2.38);
    let look_at = vec3<f32>(0.0, 1.06 + 0.10 * sin(t * 0.029 + g.seed * TAU), 0.0);
    let roll = 0.11 * sin(t * 0.019 + g.seed * 3.7) + 0.04 * cos(t * 0.031 + 1.2);
    let focal = 1.36;

    let fwd = normalize(look_at - ro);
    let up0 = vec3<f32>(sin(roll), cos(roll), 0.0);
    let right = normalize(cross(fwd, up0));
    let up = cross(right, fwd);
    let ray = right * uv.x + up * uv.y + fwd * focal;
    let rd = normalize(ray);

    // Bounded yaw sway + irrational oblique drift keeps perpendicular velocity high on all edges.
    let yaw = 0.17 * sin(t * 0.015 + g.seed * TAU) + 0.05 * cos(t * 0.023 + 0.9);
    let drift = vec2<f32>(0.48, 0.29) * t + vec2<f32>(g.seed * 17.3, g.seed * 11.9);
    let grid_scale = 2.55 + 0.14 * sin(t * 0.019 + g.seed * 4.3);

    // Bracket ray-heightfield crossing in [-0.30, +0.30] and refine via regula falsi.
    let tau_min = (0.30 - ro.z) / ray.z;
    let tau_max = (-0.30 - ro.z) / ray.z;
    var tau_a = tau_min;
    var fa = ray_f(ro, ray, tau_a, yaw, grid_scale, drift, t);
    var tau_b = tau_max;
    var fb = ray_f(ro, ray, tau_b, yaw, grid_scale, drift, t);

    for (var i = 1; i <= 6; i = i + 1) {
        let tau_i = mix(tau_min, tau_max, f32(i) / 6.0);
        let fi = ray_f(ro, ray, tau_i, yaw, grid_scale, drift, t);
        if (fi <= 0.0) {
            tau_b = tau_i;
            fb = fi;
            break;
        }
        tau_a = tau_i;
        fa = fi;
    }

    for (var s = 0; s < 2; s = s + 1) {
        let t_sec = clamp(tau_a - fa * (tau_b - tau_a) / min(fb - fa, -1e-5), tau_a, tau_b);
        let f_sec = ray_f(ro, ray, t_sec, yaw, grid_scale, drift, t);
        if (f_sec > 0.0) {
            tau_a = t_sec;
            fa = f_sec;
        } else {
            tau_b = t_sec;
            fb = f_sec;
        }
    }
    let tau = clamp(tau_a - fa * (tau_b - tau_a) / min(fb - fa, -1e-5), tau_a, tau_b);

    let hit_xy = ro.xy + ray.xy * tau;
    let wv = wave_eval(hit_xy, yaw, grid_scale, drift, t);
    let h_val = wv.x;
    let h_grad = wv.yz;
    let cwave = wv.w;

    // Lattice coordinates and perspective-scaled pixel footprint in grid-cell units.
    let u = (rot2(yaw) * hit_xy) * grid_scale + drift;
    let cid = floor(u);
    let cell_uv = fract(u);
    let local = cell_uv - vec2<f32>(0.5);
    let edge_dist = min(cell_uv, vec2<f32>(1.0) - cell_uv);
    let d_maj = min(edge_dist.x, edge_dist.y);
    let d_node = length(edge_dist);

    let sub_uv = fract(u * 4.0);
    let sub_edge = min(sub_uv, vec2<f32>(1.0) - sub_uv) * 0.25;
    let d_sub = min(sub_edge.x, sub_edge.y);

    let px_u = (1.0 / max(g.target_size.y, 1.0)) * (tau / focal) * grid_scale;
    let aa_u = px_u * 0.95;
    let sub_vis = smoothstep(0.14, 0.04, px_u);
    let maj_vis = smoothstep(0.45, 0.14, px_u);

    // 3D surface lighting over the displaced wave sheet.
    let n = normalize(vec3<f32>(-h_grad.x, -h_grad.y, 1.0));
    let l_dir = normalize(vec3<f32>(
        0.55 * cos(t * 0.24 + g.seed * TAU),
        0.45 * sin(t * 0.19 + 1.3),
        0.72,
    ));
    let h_dir = normalize(l_dir - rd);
    let diff = max(dot(n, l_dir), 0.0);
    let spec = pow(max(dot(n, h_dir), 0.0), 22.0);
    let fres = pow(clamp(1.0 - max(dot(n, -rd), 0.0), 0.0, 1.0), 2.5);
    let crest = smoothstep(-0.12, 0.18, h_val);

    // Two oblique soliton light waves sweeping across the 32:9 panorama.
    let wa = fract(dot(p, vec2<f32>(0.24, 0.15)) - t * 0.17 + 0.14 * sin(p.y * 2.2 + t * 0.09) + g.seed) - 0.5;
    let wb = fract(dot(p, vec2<f32>(-0.16, 0.27)) - t * 0.13 + 0.12 * cos(p.x * 1.5 - t * 0.08) + g.seed * 2.3) - 0.5;
    let pulse = clamp(exp(-wa * wa * 34.0) * 0.85 + exp(-wb * wb * 38.0) * 0.70, 0.0, 1.0);

    // CWaves palette sweep across height, lattice phase, and panorama position.
    let hue_pos = t * 0.017
        + cwave * 0.55
        + h_val * 1.10
        + p.x * 0.06
        + p.y * 0.05
        + g.seed;
    let tint = flux_palette(hue_pos);
    let accent = flux_palette(hue_pos + 0.34);
    let comp_tint = flux_palette(hue_pos + 0.50);
    let pearl = vec3<f32>(0.96, 0.94, 0.99);

    let sw = stage_weights(t);
    let w_wire = sw.x;
    let w_facet = sw.y;
    let w_checker = sw.z;

    // Mode 0: Gflux Wireframe + 4x4 Sub-grid + Elevation Contours.
    let maj_rib = crisp_line(d_maj, 0.024, aa_u) * maj_vis;
    let sub_rib = crisp_line(d_sub, 0.010, aa_u) * sub_vis;
    let maj_aura = exp(-d_maj * 24.0) * (0.045 + 0.14 * pulse + 0.08 * crest);
    let node_pip = crisp_line(d_node, 0.046, aa_u) * maj_vis;
    let node_glow = exp(-d_node * 18.0) * (0.14 + 0.24 * crest + 0.16 * pulse);

    // Elevation contour curves moving softly along wave crests.
    let h_g_u = max(length(h_grad) / grid_scale, 0.18);
    let iso_ph = h_val * 16.0 - t * 0.14;
    let d_iso_u = abs(fract(iso_ph) - 0.5) / (16.0 * h_g_u);
    let iso_line = crisp_line(d_iso_u, 0.011, aa_u) * smoothstep(0.24, 0.07, px_u);

    let wire_fill = tint * (0.014 + 0.036 * diff * crest + 0.024 * pulse);
    let wire_col = wire_fill
        + mix(tint, pearl, 0.24 + 0.22 * crest) * maj_rib * (1.10 + 0.45 * crest + 0.35 * pulse)
        + tint * maj_aura
        + mix(accent, pearl, 0.16) * sub_rib * (0.52 + 0.38 * crest + 0.24 * pulse)
        + mix(accent, pearl, 0.28) * iso_line * (0.58 + 0.40 * pulse)
        + mix(tint, pearl, 0.46) * (node_pip * (1.15 + 0.35 * pulse) + node_glow);

    // Mode 1: Gflux Lit Facets (beveled floating tiles catching wave light over dark gutters).
    let tile_h = hash22(cid + vec2<f32>(g.seed * 23.1, g.seed * 41.7));
    let n_facet = normalize(n + vec3<f32>((tile_h.x - 0.5) * 0.22, (tile_h.y - 0.5) * 0.22, 0.0));
    let diff_f = max(dot(n_facet, l_dir), 0.0);
    let spec_f = pow(max(dot(n_facet, h_dir), 0.0), 20.0);
    let gutter_mask = smoothstep(0.036 - aa_u, 0.048 + aa_u, d_maj);
    let bevel_rim = crisp_line(abs(d_maj - 0.055), 0.018, aa_u) * maj_vis;
    let inner_chamfer = crisp_line(abs(d_maj - 0.115), 0.0085, aa_u) * sub_vis;
    let facet_tint = mix(tint, accent, tile_h.x * 0.26);
    // Keep facet interior strictly below LIT so broad tiles never dwell.
    let facet_fill = facet_tint * (0.018 + 0.048 * diff_f + 0.036 * crest + 0.030 * pulse + 0.14 * spec_f + 0.07 * fres) * gutter_mask;
    let facet_aura = exp(-max(d_maj - 0.055, 0.0) * 26.0) * (0.04 + 0.13 * pulse + 0.07 * crest);
    let facet_col = facet_fill
        + mix(facet_tint, pearl, 0.28 + 0.24 * spec_f + 0.18 * pulse) * bevel_rim * (1.05 + 0.48 * crest + 0.35 * spec_f)
        + mix(accent, pearl, 0.22) * inner_chamfer * (0.56 + 0.36 * pulse)
        + facet_tint * facet_aura;

    // Mode 2: Gflux Checker + CWaves Dichroic Matrix.
    let parity_even = ((i32(cid.x) + i32(cid.y)) & 1) == 0;
    let chk_tint = select(comp_tint, tint, parity_even);
    let chk_accent = select(tint, accent, parity_even);
    let chk_seam = crisp_line(d_maj, 0.020, aa_u) * maj_vis;
    let chk_fill = chk_tint * select(0.018, 0.042, parity_even) * (0.65 + 0.45 * diff + 0.40 * crest + 0.35 * pulse);

    // Alternating geometric inlays: diamond frame on even squares, ring + pip on odd squares.
    let d_diamond = abs(abs(local.x) + abs(local.y) - 0.34) * 0.70710678;
    let d_ring = abs(length(local) - 0.23);
    let d_pip = length(local);
    let inlay_line = select(
        crisp_line(d_ring, 0.013, aa_u),
        crisp_line(d_diamond, 0.013, aa_u),
        parity_even,
    ) * sub_vis;
    let pip_mark = select(crisp_line(d_pip, 0.038, aa_u), 0.0, parity_even) * sub_vis;
    let chk_col = chk_fill
        + mix(chk_tint, pearl, 0.24 + 0.20 * crest) * chk_seam * (1.00 + 0.42 * crest + 0.32 * pulse)
        + mix(chk_accent, pearl, 0.26) * inlay_line * (0.86 + 0.42 * pulse)
        + mix(chk_accent, pearl, 0.44) * pip_mark * (0.95 + 0.35 * pulse);

    var col = wire_col * w_wire + facet_col * w_facet + chk_col * w_checker;

    // Gentle distant perspective depth fade + soft highlight compression.
    let depth_fade = exp(-max(tau - 1.85, 0.0) * 0.10);
    let specular_crest = mix(tint, pearl, 0.45) * spec * (0.10 + 0.08 * crest) * (0.6 + 0.4 * pulse);
    col = (col + specular_crest) * depth_fade;

    return col / (vec3<f32>(1.0) + col * 0.18);
}

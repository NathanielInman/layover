// Helix Tunnel: curving helical ribs, swirling vortex filaments and rushing
// starlight bending smoothly across the dark.
// After xscreensaver's Atunnel (Roman Podobedov & Eric Lassauge, 2003),
// Timetunnel (Sean Brennan, 2005) and Wormhole (Jon Rafkind, 2004).

const TUNNEL_SPEED: f32 = 2.15;
const RING_STEP: f32 = 1.30;
const BASE_RADIUS: f32 = 1.15;

// Anti-aliased crisp stroke of world half-width `hw` with filter half-width `aa`.
// Preserves integrated energy at wear-test resolution.
fn crisp_line(d: f32, hw: f32, aa: f32) -> f32 {
    let cov = clamp((hw + aa - d) / (2.0 * aa), 0.0, 1.0);
    return smoothstep(0.0, 1.0, cov) * min(1.0, hw / aa);
}

// Cyclical nocturnal dichroic palette: sapphire, amethyst, amber, jade.
fn tunnel_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let sapphire = vec3<f32>(0.18, 0.74, 0.96);
    let amethyst = vec3<f32>(0.82, 0.34, 0.90);
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

// Smoothly curving tunnel centerline in xy as a function of depth z.
fn tunnel_center(z: f32) -> vec2<f32> {
    let s = g.seed * TAU;
    return vec2<f32>(
        1.35 * sin(z * 0.110 + s) + 0.55 * cos(z * 0.067 + s * 1.7 + 1.1),
        0.76 * cos(z * 0.097 + s * 2.3) + 0.32 * sin(z * 0.157 + 0.5),
    );
}

// Exact derivative dC/dz for analytical surface normals.
fn tunnel_center_d(z: f32) -> vec2<f32> {
    let s = g.seed * TAU;
    return vec2<f32>(
        1.35 * 0.110 * cos(z * 0.110 + s) - 0.55 * 0.067 * sin(z * 0.067 + s * 1.7 + 1.1),
        -0.76 * 0.097 * sin(z * 0.097 + s * 2.3) + 0.32 * 0.157 * cos(z * 0.157 + 0.5),
    );
}

// Smooth 3-stage cross-section weights summing to 1.
fn stage_weights(t: f32) -> vec3<f32> {
    let stage = t / 38.0 + g.seed * 3.0;
    let idx0 = u32(floor(stage)) % 3u;
    let blend = smoothstep(0.80, 1.0, fract(stage));
    let a = 1.0 - blend;
    if (idx0 == 0u) {
        return vec3<f32>(a, blend, 0.0);
    }
    if (idx0 == 1u) {
        return vec3<f32>(0.0, a, blend);
    }
    return vec3<f32>(blend, 0.0, a);
}

// Sculpted tunnel wall radius: 8-fluted conduit, 6-ribbed hex vault, 4-lobed arch.
fn tube_radius(theta: f32, z: f32, sw: vec3<f32>) -> f32 {
    let r0 = 0.075 * cos(8.0 * theta + 0.80 * z);
    let r1 = 0.105 * cos(6.0 * theta - 0.65 * z);
    let r2 = 0.115 * cos(4.0 * theta + 0.95 * z);
    return BASE_RADIUS + sw.x * r0 + sw.y * r1 + sw.z * r2;
}

// Exact inward-pointing surface normal on the curved, fluted wall.
fn tube_normal(hp: vec3<f32>, rel: vec2<f32>, r: f32, theta: f32, sw: vec3<f32>) -> vec3<f32> {
    let safe_r = max(r, 1e-4);
    let u_r = rel / safe_r;
    let u_t = vec2<f32>(-u_r.y, u_r.x);

    let a0 = 8.0 * theta + 0.80 * hp.z;
    let a1 = 6.0 * theta - 0.65 * hp.z;
    let a2 = 4.0 * theta + 0.95 * hp.z;
    let s0 = sin(a0);
    let s1 = sin(a1);
    let s2 = sin(a2);

    let dr_dth = -sw.x * 0.60 * s0 - sw.y * 0.63 * s1 - sw.z * 0.46 * s2;
    let dr_dz = -sw.x * 0.060 * s0 + sw.y * 0.06825 * s1 - sw.z * 0.10925 * s2;

    let grad_xy = u_r - (dr_dth / safe_r) * u_t;
    let grad_z = -dot(grad_xy, tunnel_center_d(hp.z)) - dr_dz;
    return normalize(vec3<f32>(-grad_xy.x, -grad_xy.y, -grad_z));
}

// One coaxial Wormhole streak shell evaluated at ray-shell intersection `sp`.
fn streak_shell(
    sp: vec3<f32>,
    ds: f32,
    n_lanes: f32,
    cell_len: f32,
    shell_seed: f32,
    t: f32,
    px: f32,
    focal: f32,
    shell_r: f32,
) -> vec3<f32> {
    let srel = sp.xy - tunnel_center(sp.z);
    let phi = fract(atan2(srel.y, srel.x) / TAU) * n_lanes;
    let lane = floor(phi) % n_lanes;
    let lane_dist = abs(fract(phi) - 0.5) * (TAU * shell_r / n_lanes);

    let lane_h = hash22(vec2<f32>(lane + shell_seed * 37.0, shell_seed * 19.3 + g.seed * 29.0));
    let speed_mul = 0.88 + 0.28 * lane_h.x;
    let z_stream = sp.z + t * (2.80 * speed_mul) + lane_h.y * cell_len * 3.0;
    let cell = floor(z_stream / cell_len);
    let cf = fract(z_stream / cell_len);

    let cell_h = hash22(vec2<f32>(lane * 3.1 + cell * 0.73, shell_seed * 41.0 + g.seed * 17.0));
    if (cell_h.x > 0.42) {
        return vec3<f32>(0.0);
    }

    // Sleek luminous head near cf = 0.15 with an exponentially tapering tail.
    let tail_pos = cf - 0.14;
    let mask = smoothstep(0.0, 0.035, tail_pos) * (1.0 - smoothstep(0.42, 0.56, tail_pos));
    let profile = mask * (0.32 + 0.68 * exp(-max(tail_pos, 0.0) * 7.2));

    let aa_s = max(px * ds / focal, 0.0010);
    let width = crisp_line(lane_dist, 0.0048 + 0.0024 * cell_h.y, aa_s);
    let fade = smoothstep(0.24, 1.10, ds) * exp(-ds * ds * 0.010);

    let tint = tunnel_palette(cell_h.y * 0.85 + lane / n_lanes * 0.35 + t * 0.022 + shell_seed * 0.31);
    let pearl = vec3<f32>(0.96, 0.94, 0.99);
    let head_glint = exp(-max(tail_pos - 0.025, 0.0) * 24.0) * smoothstep(0.0, 0.02, tail_pos);
    return mix(tint, pearl, 0.48 * head_glint) * profile * width * fade * 1.65;
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = aspect();
    let px = 1.0 / max(g.target_size.y, 1.0);
    let focal: f32 = 1.25;

    let z_cam = t * TUNNEL_SPEED + g.seed * 37.0;
    let cam_sway = vec2<f32>(
        0.15 * sin(t * 0.23 + g.seed * 5.0),
        0.11 * cos(t * 0.19 + g.seed * 2.7),
    );
    let ro = vec3<f32>(tunnel_center(z_cam) + cam_sway, z_cam);
    let look_at = vec3<f32>(tunnel_center(z_cam + 3.4), z_cam + 3.4);

    let fwd = normalize(look_at - ro);
    let roll = 0.26 * sin(t * 0.053 + g.seed * TAU);
    let up0 = vec3<f32>(sin(roll), cos(roll), 0.0);
    let ref_up = select(up0, vec3<f32>(0.0, 0.0, 1.0), abs(dot(fwd, up0)) > 0.99);
    let right = normalize(cross(fwd, ref_up));
    let up = cross(right, fwd);

    // Off-axis panoramic vanishing-point sweep across 32:9.
    let vp = vec2<f32>(
        a * (0.5 + 0.24 * sin(t * 0.029 + g.seed * TAU) + 0.07 * cos(t * 0.047 + 1.3)),
        0.5 + 0.14 * cos(t * 0.037 + g.seed * 4.1),
    );
    let uv = p - vp;
    let rd = normalize(right * uv.x + up * uv.y + fwd * focal);

    let sw = stage_weights(t);
    let max_d: f32 = 16.5;
    var d: f32 = 0.05;
    var hit = false;

    var prev_r = length(ro.xy - tunnel_center(ro.z));
    var prev_d = 0.0;
    var s0_hit = false;
    var s0_d = 0.0;
    var s1_hit = false;
    var s1_d = 0.0;
    var s2_hit = false;
    var s2_d = 0.0;

    for (var i = 0; i < 42; i = i + 1) {
        let pos = ro + rd * d;
        let rel = pos.xy - tunnel_center(pos.z);
        let r = length(rel);

        // Capture first intersections with three coaxial Wormhole streak shells.
        if (!s0_hit && prev_r < 0.34 && r >= 0.34) {
            let frac = clamp((0.34 - prev_r) / max(r - prev_r, 1e-4), 0.0, 1.0);
            s0_d = mix(prev_d, d, frac);
            s0_hit = true;
        }
        if (!s1_hit && prev_r < 0.56 && r >= 0.56) {
            let frac = clamp((0.56 - prev_r) / max(r - prev_r, 1e-4), 0.0, 1.0);
            s1_d = mix(prev_d, d, frac);
            s1_hit = true;
        }
        if (!s2_hit && prev_r < 0.78 && r >= 0.78) {
            let frac = clamp((0.78 - prev_r) / max(r - prev_r, 1e-4), 0.0, 1.0);
            s2_d = mix(prev_d, d, frac);
            s2_hit = true;
        }

        let theta = atan2(rel.y, rel.x);
        let h = tube_radius(theta, pos.z, sw) - r;
        let eps = max(0.0018, 0.0016 * d);
        if (h < eps) {
            hit = true;
            break;
        }

        prev_r = r;
        prev_d = d;
        d = d + min(h * 0.65, 0.82);
        if (d > max_d) {
            break;
        }
    }

    let bg = vec3<f32>(0.001, 0.002, 0.004);
    var col = bg;

    if (hit) {
        let hp = ro + rd * d;
        let rel = hp.xy - tunnel_center(hp.z);
        let r = length(rel);
        let theta = atan2(rel.y, rel.x);
        let n = tube_normal(hp, rel, r, theta, sw);

        let grazing = abs(dot(n, -rd));
        let aa_wall = max(px * d / focal, 0.0014);
        let aa_z = aa_wall / max(grazing, 0.16);
        let aa_theta = aa_wall / max(r, 0.4);
        let aa_surf = max(aa_z * 0.80, aa_theta);

        // Band-limit fine wall features cleanly before subpixel horizon aliasing.
        let near_fade = smoothstep(0.42, 1.05, d);
        let detail_fade = near_fade * smoothstep(1.85, 0.24, aa_z) * exp(-d * d * 0.011);

        // Dark sculpted obsidian wall with moving internal lantern specular along flutes.
        let lpos = vec3<f32>(tunnel_center(z_cam + 4.4), z_cam + 4.4);
        let to_l = lpos - hp;
        let l_dist = length(to_l);
        let l_dir = to_l / max(l_dist, 1e-4);
        let l_atten = 1.0 / (1.0 + l_dist * l_dist * 0.14);
        let half_v = normalize(l_dir - rd);
        let spec_broad = pow(max(dot(n, half_v), 0.0), 8.0) * l_atten;
        let spec_sharp = pow(max(dot(n, half_v), 0.0), 26.0) * l_atten;
        let rim = fresnel(n, -rd, 2.8);

        let pulse0 = pow(0.5 + 0.5 * sin(hp.z * 0.75 + t * 1.35 + theta * 2.0), 4.0);
        let pulse1 = pow(0.5 + 0.5 * cos(hp.z * 0.52 - t * 1.15 - theta * 3.0), 4.0);
        let rim_tint = tunnel_palette(hp.z * 0.045 + t * 0.018);

        // Subtle architectural bay seam along each cross-section lobe so curved volume reads clearly.
        let d_flute = sw.x * (abs(sin(8.0 * theta + 0.80 * hp.z)) / 8.0)
            + sw.y * (abs(sin(6.0 * theta - 0.65 * hp.z)) / 6.0)
            + sw.z * (abs(sin(4.0 * theta + 0.95 * hp.z)) / 4.0);
        let flute_seam = crisp_line(d_flute, 0.0055, aa_theta);

        col = vec3<f32>(0.012, 0.022, 0.038) * (0.35 + 0.65 * grazing)
            + rim_tint * (rim * (0.045 + 0.024 * pulse0) + (spec_broad * 0.095 + spec_sharp * 0.24) * detail_fade)
            + rim_tint * flute_seam * (0.14 + 0.18 * spec_broad) * detail_fade;

        // Layer 1 (Atunnel): slender transverse architectural ribs, twin flanges, and helical rails.
        let z_cyc = hp.z / RING_STEP;
        let d_ring = abs(fract(z_cyc) - 0.5) * RING_STEP;
        let ring_line = crisp_line(d_ring, 0.013, aa_z);
        let ring_flange = crisp_line(abs(d_ring - 0.044), 0.0045, aa_z);
        let ring_sheen = 0.68 + 0.32 * sin(hp.z * 0.65 + t * 1.45 + 2.0 * theta);
        let ring_tint = tunnel_palette(floor(z_cyc) * 0.13 + t * 0.016 + 0.10);

        let h1_phase = 6.0 * theta + 1.05 * hp.z + 0.58 * t;
        let d_h1 = abs(fract(h1_phase / TAU) - 0.5) * (TAU / 6.0);
        let rail1 = crisp_line(d_h1, 0.013, aa_theta);

        let h2_phase = 6.0 * theta - 1.15 * hp.z - 0.35 * t;
        let d_h2 = abs(fract(h2_phase / TAU) - 0.5) * (TAU / 6.0);
        let rail2 = crisp_line(d_h2, 0.0075, aa_theta);

        let pearl = vec3<f32>(0.94, 0.92, 0.99);
        let rail_tint1 = tunnel_palette(hp.z * 0.055 + t * 0.020 + 0.34);
        let rail_tint2 = tunnel_palette(hp.z * 0.055 + t * 0.020 + 0.72);

        col = col + mix(ring_tint, pearl, 0.28) * (ring_line * 1.05 + ring_flange * 0.45) * ring_sheen * detail_fade;
        col = col + mix(rail_tint1, pearl, 0.24) * rail1 * (0.68 + 0.32 * pulse0) * detail_fade * 0.94;
        col = col + rail_tint2 * rail2 * (0.58 + 0.42 * pulse1) * detail_fade * 0.64;

        // Crisp node glint where transverse ribs cross primary helical rails.
        let node = ring_line * rail1;
        col = col + pearl * node * detail_fade * 0.85;

        // Layer 2 (Timetunnel): crisp swirling harmonic vortex ribbons over black troughs.
        let u1 = 3.0 * theta + 0.58 * hp.z + 0.32 * t
            + 1.05 * sin(2.0 * theta - 0.45 * hp.z - 0.45 * t);
        let u2 = 4.0 * theta - 0.60 * hp.z - 0.25 * t
            + 0.95 * sin(theta + 0.40 * hp.z + 0.55 * t);

        let d_v1 = abs(sin(u1)) / 2.85;
        let d_v2 = abs(cos(u2)) / 3.65;
        let v_line1 = crisp_line(d_v1, 0.011, aa_surf);
        let v_line2 = crisp_line(d_v2, 0.0085, aa_surf);
        let v_aura1 = exp(-d_v1 * 36.0) * 0.16;
        let v_aura2 = exp(-d_v2 * 40.0) * 0.13;

        let v_hue1 = hp.z * 0.06 + t * 0.025 + 0.18 * sin(u2);
        let v_hue2 = hp.z * 0.06 + t * 0.025 + 0.50 + 0.18 * cos(u1);
        let v_col1 = tunnel_palette(v_hue1);
        let v_col2 = tunnel_palette(v_hue2);
        let vortex_fade = near_fade * exp(-d * d * 0.014) * smoothstep(1.65, 0.24, aa_z);

        col = col + mix(v_col1, pearl, 0.22 * v_line1) * (v_line1 * 0.82 + v_aura1) * vortex_fade;
        col = col + mix(v_col2, pearl, 0.18 * v_line2) * (v_line2 * 0.68 + v_aura2) * vortex_fade;
        col = col + pearl * (v_line1 * v_line2) * vortex_fade * 0.45;

        col = fog_exp(col, bg, d, 0.014);
    }

    // Layer 3 (Wormhole): rushing interior starlight streaks on three coaxial shells.
    let wall_d = select(max_d, d, hit);
    if (s0_hit && s0_d < wall_d) {
        col = col + streak_shell(ro + rd * s0_d, s0_d, 16.0, 3.70, 1.0, t, px, focal, 0.34);
    }
    if (s1_hit && s1_d < wall_d) {
        col = col + streak_shell(ro + rd * s1_d, s1_d, 22.0, 3.70, 2.0, t, px, focal, 0.56);
    }
    if (s2_hit && s2_d < wall_d) {
        col = col + streak_shell(ro + rd * s2_d, s2_d, 28.0, 3.70, 3.0, t, px, focal, 0.78);
    }

    // Soft shoulder keeps overlapping ribs, filaments and star streaks vivid without flat white clipping.
    return col / (vec3<f32>(1.0) + col * 0.22);
}

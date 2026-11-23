// Voronoi Glass: drifting Voronoi cells with beveled crystal borders,
// faceted glass interiors, concentric growth contours and glowing nuclei.
// After xscreensaver's Voronoi (Jamie Zawinski, 2007).

// Anti-aliased crisp stroke of world half-width `hw` (in canvas heights) with
// pixel filter half-width `aa`. Preserves integrated energy at wear-test resolution.
fn crisp_line(d: f32, hw: f32, aa: f32) -> f32 {
    let cov = clamp((hw + aa - d) / (2.0 * aa), 0.0, 1.0);
    return smoothstep(0.0, 1.0, cov) * min(1.0, hw / aa);
}

// Cyclical nocturnal dichroic palette: sapphire, amethyst, amber, jade.
fn voronoi_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let sapphire = vec3<f32>(0.18, 0.76, 0.96);
    let amethyst = vec3<f32>(0.78, 0.34, 0.92);
    let amber = vec3<f32>(0.98, 0.58, 0.24);
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

// Smooth 3-mode cycle: (leadlight, polygonal geode, conical elevation contours).
fn stage_weights(t: f32) -> vec3<f32> {
    let stage = t / 45.0 + g.seed * 3.0;
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

// Continuous Lissajous site motion bounded strictly inside [-0.38, +0.38]^2
// around each integer cell center so 4x4 evaluation is always artifact-free.
fn cell_site_offset(cid: vec2<f32>, t: f32) -> vec2<f32> {
    let h0 = hash22(cid + vec2<f32>(g.seed * 17.3, g.seed * 29.1));
    let h1 = hash22(cid * 1.37 + vec2<f32>(g.seed * 43.7, g.seed * 11.9));
    let wx0 = 0.22 + 0.14 * h0.x;
    let wy0 = 0.20 + 0.15 * h0.y;
    let wx1 = 0.37 + 0.19 * h1.x;
    let wy1 = 0.35 + 0.21 * h1.y;
    return vec2<f32>(
        0.24 * sin(t * wx0 + h0.x * TAU) + 0.14 * cos(t * wx1 + h1.x * TAU),
        0.24 * cos(t * wy0 + h0.y * TAU) + 0.14 * sin(t * wy1 + h1.y * TAU),
    );
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = aspect();
    let px = 1.0 / max(g.target_size.y, 1.0);
    let aa = px * 0.95;

    let mid = vec2<f32>(a * 0.5, 0.5);
    let rot = 0.12 * sin(t * 0.015 + g.seed * TAU) + 0.04 * cos(t * 0.023 + 1.1);
    // Shallow irrational drift keeps perpendicular velocity high across arbitrary edge angles.
    let drift = vec2<f32>(0.058, 0.024) * t + vec2<f32>(g.seed * 11.3, g.seed * 7.1);
    let scale = 3.25 + 0.25 * sin(t * 0.021 + g.seed * 3.1);
    let q = (rot2(rot) * (p - mid) - drift) * scale;
    let w_scale = 1.0 / scale;

    // Pass 1: exact 4x4 grid search around `q` to locate the winning Voronoi cell.
    let base = floor(q - vec2<f32>(0.5));
    var rels: array<vec2<f32>, 16>;
    var best_idx: i32 = 0;
    var best_d2: f32 = 1e9;
    var best_cid = vec2<f32>(0.0);

    var k: i32 = 0;
    for (var oy: i32 = -1; oy <= 2; oy = oy + 1) {
        for (var ox: i32 = -1; ox <= 2; ox = ox + 1) {
            let cid = base + vec2<f32>(f32(ox), f32(oy));
            let site = cid + vec2<f32>(0.5) + cell_site_offset(cid, t);
            let rel = site - q;
            rels[k] = rel;
            let d2 = dot(rel, rel);
            if (d2 < best_d2) {
                best_d2 = d2;
                best_idx = k;
                best_cid = cid;
            }
            k = k + 1;
        }
    }

    // Pass 2: exact Euclidean distance to the nearest and second-nearest cell borders.
    let r0 = rels[best_idx];
    var d_edge1: f32 = 1e6;
    var d_edge2: f32 = 1e6;
    var dir1 = vec2<f32>(1.0, 0.0);
    var dir2 = vec2<f32>(0.0, 1.0);

    for (var i: i32 = 0; i < 16; i = i + 1) {
        if (i == best_idx) {
            continue;
        }
        let diff = rels[i] - r0;
        let diff_len = length(diff);
        if (diff_len < 1e-5) {
            continue;
        }
        let dir = diff / diff_len;
        let d_bis = dot(0.5 * (r0 + rels[i]), dir);
        if (d_bis < d_edge1) {
            d_edge2 = d_edge1;
            dir2 = dir1;
            d_edge1 = d_bis;
            dir1 = dir;
        } else if (d_bis < d_edge2) {
            d_edge2 = d_bis;
            dir2 = dir;
        }
    }

    let d1 = max(d_edge1, 0.0);
    let d2 = max(d_edge2, 0.0);
    let d_edge_world = d1 * w_scale;
    let d_seed_world = sqrt(best_d2) * w_scale;

    // Exact distance to the nearest Voronoi triple-junction vertex.
    let c12 = dot(dir1, dir2);
    let denom = 1.0 - c12 * c12;
    var d_vertex_world: f32 = 10.0;
    if (denom > 0.01) {
        let raw_v2 = (d1 * d1 + d2 * d2 - 2.0 * c12 * d1 * d2) / denom;
        d_vertex_world = sqrt(max(raw_v2, max(d1 * d1, d2 * d2))) * w_scale;
    }

    // Cell tint combines spatial panorama gradient, per-cell jewel offset, and slow drift.
    let cell_h = hash22(best_cid + vec2<f32>(g.seed * 31.7, g.seed * 19.3));
    let hue_pos = t * 0.018
        + q.x * 0.048
        + q.y * 0.036
        + cell_h.x * 0.58
        + 0.12 * sin(t * 0.07 + cell_h.y * TAU)
        + g.seed;
    let tint = voronoi_palette(hue_pos);
    let accent = voronoi_palette(hue_pos + 0.34);
    let pearl = vec3<f32>(0.96, 0.94, 0.99);

    // Two oblique soliton light waves sweeping across the 32:9 field.
    let wa = fract(dot(q, vec2<f32>(0.19, 0.12)) - t * 0.16 + 0.16 * sin(q.y * 0.41 + t * 0.09) + g.seed) - 0.5;
    let wb = fract(dot(q, vec2<f32>(-0.13, 0.21)) - t * 0.12 + 0.14 * cos(q.x * 0.38 - t * 0.08) + g.seed * 2.3) - 0.5;
    let pulse = clamp(exp(-wa * wa * 32.0) * 0.85 + exp(-wb * wb * 36.0) * 0.70, 0.0, 1.0);

    // Faceted 2.5D crystal normal: conical flank near the seed blending into the border bevel.
    let seed_dir = select(vec2<f32>(0.0), -r0 / max(length(r0), 1e-5), best_d2 > 1e-6);
    let edge_blend = smoothstep(0.038, 0.002, d_edge_world);
    let slope_xy = mix(seed_dir * 0.42, dir1 * 0.92, edge_blend);
    let n = normalize(vec3<f32>(slope_xy.x, slope_xy.y, 0.82));
    let light_dir = normalize(vec3<f32>(
        cos(t * 0.29 + g.seed * 2.0),
        sin(t * 0.23 + 1.1),
        0.52,
    ));
    let half_v = normalize(light_dir + vec3<f32>(0.0, 0.0, 1.0));
    let diff = max(dot(n, light_dir), 0.0);
    let spec = pow(max(dot(n, half_v), 0.0), 22.0);
    let edge_catch = 0.52 + 0.48 * max(dot(dir1, light_dir.xy), -0.35);

    // Dark stained-glass cell interior stays strictly below LIT so panes never dwell.
    let bevel_tint = mix(tint, accent, 0.28 * edge_blend);
    let glass = bevel_tint * (0.024 + 0.050 * diff + 0.042 * pulse + 0.15 * spec * (0.35 + 0.65 * edge_blend));

    let sw = stage_weights(t);
    let w_lead = sw.x;
    let w_geode = sw.y;
    let w_cone = sw.z;

    // Mode 0: Cathedral Leadlight (dark hairline moat + twin beveled glass rims + inner chamfer).
    let lead_moat = smoothstep(0.0016 - aa, 0.0028 + aa, d_edge_world);
    let twin_rim = crisp_line(abs(d_edge_world - 0.0048), 0.0020, aa);
    let inner_chamfer = crisp_line(abs(d_edge_world - 0.0150), 0.0011, aa);
    let lead_aura = exp(-max(d_edge_world - 0.004, 0.0) * 64.0) * (0.055 + 0.17 * pulse);
    let lead_col = mix(tint, pearl, 0.24 + 0.20 * pulse) * twin_rim * (1.15 + 0.40 * pulse) * (0.62 + 0.38 * edge_catch)
        + mix(accent, pearl, 0.22) * inner_chamfer * (0.62 + 0.42 * pulse)
        + tint * lead_aura;

    // Mode 1: Polygonal Crystal Geode (luminous border seam + marching agate terraces).
    let geo_phase = d_edge_world * 24.0 - t * 0.38 + cell_h.x;
    let d_geo = abs(fract(geo_phase) - 0.5) / 24.0;
    let geo_mask = smoothstep(0.006, 0.018, d_edge_world) * (1.0 - smoothstep(0.11, 0.20, d_edge_world));
    let geo_rings = crisp_line(d_geo, 0.0012, aa) * geo_mask;
    let geo_col = mix(accent, pearl, 0.14 * pulse) * geo_rings * (0.68 + 0.48 * pulse);

    // Mode 2: Conical Elevation Contours (luminous seam + concentric rings clipped at cell walls).
    let cone_phase = d_seed_world * 22.0 - t * 0.42 + cell_h.y;
    let d_cone = abs(fract(cone_phase) - 0.5) / 22.0;
    let cone_mask = smoothstep(0.014, 0.026, d_seed_world) * smoothstep(0.003, 0.009, d_edge_world);
    let cone_rings = crisp_line(d_cone, 0.0012, aa) * cone_mask;
    let cone_col = mix(mix(accent, tint, 0.35), pearl, 0.14 * pulse) * cone_rings * (0.72 + 0.50 * pulse);

    // Unified luminous Voronoi crystal seam for Modes 1 & 2.
    let seam_line = crisp_line(d_edge_world, 0.0022, aa);
    let seam_aura = exp(-d_edge_world * 78.0) * (0.045 + 0.16 * pulse);
    let seam_col = mix(tint, pearl, 0.28 + 0.22 * pulse) * seam_line * (1.16 + 0.40 * pulse) * (0.64 + 0.36 * edge_catch)
        + tint * seam_aura;

    // Combine interior + mode-specific crystal borders.
    let moat_scale = mix(1.0, lead_moat, w_lead);
    var col = glass * moat_scale
        + lead_col * w_lead
        + (seam_col + geo_col) * w_geode
        + (seam_col + cone_col) * w_cone;

    // Triple-junction vertex clasps along the tessellation corners.
    let v_bead = crisp_line(d_vertex_world, 0.0038, aa);
    let v_glow = exp(-d_vertex_world * 110.0) * 0.22;
    let v_pulse = 0.68 + 0.32 * sin(t * 1.1 + q.x * 0.7 - q.y * 0.5);
    col = col + mix(tint, pearl, 0.48) * (v_bead * (1.05 + 0.32 * pulse) + v_glow) * v_pulse;

    // Delicate moving seed nuclei inside each Voronoi cell (brighter in Cone Contours mode).
    let nuc_ring = crisp_line(abs(d_seed_world - 0.0076), 0.0011, aa);
    let nuc_core = crisp_line(d_seed_world, 0.0023, aa);
    let nuc_pulse = 0.62 + 0.38 * sin(t * 1.25 + cell_h.y * TAU);
    let nuc_boost = 0.85 + 0.40 * w_cone;
    col = col + mix(accent, pearl, 0.44) * (nuc_ring * 0.82 + nuc_core * 1.18) * nuc_pulse * nuc_boost;

    // Soft shoulder keeps dense vertex clasps and rim crossings vivid without clipping flat white.
    return col / (vec3<f32>(1.0) + col * 0.16);
}

// Quasi Lattice: crisp aperiodic crystal tilings from interfering plane waves
// that slowly morph across 5-, 7-, 9- and 11-fold symmetry, cut into stepped
// dark-glass facets with razor-sharp dichroic bezels.
// After xscreensaver's Quasicrystal (Jamie Zawinski, 2013).

// Evaluate an n-wave quasicrystal field and its analytical gradient with
// respect to canvas coordinates `q` (in canvas heights). Normalized by sqrt(n)
// so contrast and brightness stay consistent across symmetry orders.
fn quasi_field(q: vec2<f32>, n: i32, freq: f32, rot: f32, phase: f32) -> vec3<f32> {
    let fn_f = f32(n);
    let inv_norm = inverseSqrt(fn_f);
    var v = 0.0;
    var gx = 0.0;
    var gy = 0.0;
    for (var k = 0; k < n; k = k + 1) {
        let a = rot + f32(k) * PI / fn_f;
        let dir = vec2<f32>(cos(a), sin(a));
        let u = dot(dir, q) * freq + phase;
        v = v + cos(u);
        let s = -sin(u) * freq;
        gx = gx + s * dir.x;
        gy = gy + s * dir.y;
    }
    return vec3<f32>(v, gx, gy) * inv_norm;
}

// Anti-aliased crisp stroke of world half-width `hw` (in canvas heights) with
// pixel filter half-width `aa`. Drops cleanly to zero with no soft halo, and
// preserves integrated brightness at low render resolutions (like the wear test).
fn crisp_line(d: f32, hw: f32, aa: f32) -> f32 {
    let cov = clamp((hw + aa - d) / (2.0 * aa), 0.0, 1.0);
    return smoothstep(0.0, 1.0, cov) * min(1.0, hw / aa);
}

// Smooth nocturnal dichroic palette: frost, amethyst, amber, jade.
fn crystal_palette(angle: f32) -> vec3<f32> {
    let p = fract(angle / TAU);
    let frost = vec3<f32>(0.26, 0.80, 0.96);
    let amethyst = vec3<f32>(0.78, 0.36, 0.92);
    let amber = vec3<f32>(0.96, 0.68, 0.28);
    let jade = vec3<f32>(0.30, 0.86, 0.62);
    let s = p * 4.0;
    if (s < 1.0) {
        return mix(frost, amethyst, smoothstep(0.0, 1.0, s));
    }
    if (s < 2.0) {
        return mix(amethyst, amber, smoothstep(0.0, 1.0, s - 1.0));
    }
    if (s < 3.0) {
        return mix(amber, jade, smoothstep(0.0, 1.0, s - 2.0));
    }
    return mix(jade, frost, smoothstep(0.0, 1.0, s - 3.0));
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = aspect();
    // One render-target pixel in canvas-height units for pixel-tight AA.
    let px = 1.0 / max(g.target_size.y, 1.0);
    let aa = px * 0.95;

    // Wandering symmetry origin sweeping across the 32:9 panorama so rosettes
    // glide smoothly and never park on one patch of pixels.
    let center = vec2<f32>(
        a * (0.5 + 0.36 * sin(t * 0.053 + g.seed * TAU) + 0.11 * cos(t * 0.089 + 1.4)),
        0.5 + 0.30 * cos(t * 0.047 + g.seed * 4.1) + 0.10 * sin(t * 0.073 + 0.7),
    );
    let q = p - center;

    // Clean crystalline tile scale, gentle rotation and steady phase march.
    let freq = 36.0 + 2.0 * sin(t * 0.037 + g.seed * 5.0);
    let rot = t * 0.028 + 0.18 * sin(t * 0.017 + g.seed * 2.7);
    let phase = t * 0.76 + g.seed * TAU;

    // Cycle smoothly through 5-, 7-, 9- and 11-fold quasicrystal symmetries.
    var orders = array<i32, 4>(5, 7, 9, 11);
    let stage = t / 44.0 + g.seed * 4.0;
    let idx0 = u32(floor(stage)) % 4u;
    let idx1 = (idx0 + 1u) % 4u;
    let blend = smoothstep(0.80, 1.0, fract(stage));

    var fg = quasi_field(q, orders[idx0], freq, rot, phase);
    if (blend > 0.001) {
        let fg1 = quasi_field(q, orders[idx1], freq, rot, phase);
        let a_mix = blend * PI * 0.5;
        fg = fg * cos(a_mix) + fg1 * sin(a_mix);
    }

    let v = fg.x;
    let grad = fg.yz;
    let g_len = length(grad);
    let g_safe = max(g_len, freq * 0.18);
    // Unit-scale gradient (divided by freq) for facet normal & lighting.
    let g_unit = grad / freq;
    let g_unit_len = length(g_unit);

    // Signed world distances (in canvas heights) to each crystal terrace level.
    let sd_zero = v / g_safe;
    let sd_tile = (v - 0.34) / g_safe;
    let sd_mid = (v - 0.86) / g_safe;
    let sd_core = (v - 1.38) / g_safe;

    // Crisp anti-aliased filled crystal terraces (hard edges, zero blur).
    let tile_fill = smoothstep(-aa, aa, sd_tile);
    let mid_fill = smoothstep(-aa, aa, sd_mid);
    let core_fill = smoothstep(-aa, aa, sd_core);

    // Pixel-tight geometric lines: architectural zero-web, outer crystal bezel,
    // raised terrace ridge, and inner star-jewel rim.
    let zero_web = crisp_line(abs(sd_zero), 0.0009, aa);
    let outer_rim = crisp_line(abs(sd_tile), 0.0014, aa);
    let mid_rim = crisp_line(abs(sd_mid), 0.0012, aa);
    let core_rim = crisp_line(abs(sd_core), 0.0010, aa);

    // Crisp 2.5D crystal bevel normal lit by a slowly orbiting directional light.
    let n = normalize(vec3<f32>(g_unit.x * 1.85, g_unit.y * 1.85, 0.72));
    let light_dir = normalize(vec3<f32>(
        cos(t * 0.27 + g.seed * 2.0),
        sin(t * 0.21 + 1.1),
        0.42,
    ));
    let view_dir = vec3<f32>(0.0, 0.0, 1.0);
    let half_v = normalize(light_dir + view_dir);
    let diff = max(dot(n, light_dir), 0.0);
    let spec = pow(max(dot(n, half_v), 0.0), 18.0);
    // Directional glint along bezel edges facing the light.
    let edge_dir = select(vec2<f32>(0.0), g_unit / g_unit_len, g_unit_len > 0.01);
    let edge_catch = 0.55 + 0.45 * max(dot(edge_dir, light_dir.xy), -0.35);

    // Dichroic crystal tints: slope dispersion blending cleanly into height hue
    // near flat peak centers so there is no pinwheel seam.
    let base_hue = v * 0.85 + length(q) * 0.28 + t * 0.11;
    let slope_tint = crystal_palette(atan2(g_unit.y, g_unit.x) + base_hue);
    let peak_tint = crystal_palette(base_hue + 0.70);
    let dir_weight = smoothstep(0.06, 0.40, g_unit_len);
    let tint = mix(peak_tint, slope_tint, dir_weight);
    let accent = crystal_palette(base_hue + PI * 0.68 - v * 0.35);

    let bg = vec3<f32>(0.001, 0.002, 0.004);
    var col = bg;

    // Fine architectural Ammann web connecting rosettes across the dark void.
    col = col + accent * zero_web * (0.30 + 0.22 * edge_catch);

    // Dark translucent cut-glass crystal tiles with crisp specular facets.
    let tile_body = tile_fill * (1.0 - mid_fill);
    let mid_body = mid_fill * (1.0 - core_fill);
    col = col + tint * tile_body * (0.09 + 0.16 * diff + 0.62 * spec);
    col = col + accent * mid_body * (0.16 + 0.22 * diff + 0.68 * spec);

    // Vivid faceted jewel cores at high constructive-interference stars.
    col = col + peak_tint * core_fill * (0.44 + 0.34 * diff) + vec3<f32>(0.96, 0.98, 1.0) * core_fill * spec * 0.65;

    // Razor-sharp lit crystal bezels along each terrace cut.
    let bright_white = vec3<f32>(0.96, 0.98, 1.0);
    col = col + mix(tint, bright_white, 0.26) * outer_rim * (0.88 * edge_catch + 0.42 * spec);
    col = col + mix(accent, bright_white, 0.28) * mid_rim * (0.86 * edge_catch + 0.38 * spec);
    col = col + mix(peak_tint, bright_white, 0.48) * core_rim * 0.96;

    return col;
}

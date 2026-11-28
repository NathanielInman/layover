// Ribbon Trace: bouncing vector ribbons, hollow triads, twisted quads and
// gravity arcs fanning across a single full-canvas dark field on Tier L
// instanced SDF lines.
// After xscreensaver's Qix (Jamie Zawinski, 1992).

const EPOCH_SECS: f32 = 42.0;
const SEG_SLOTS: u32 = 240u;
const SPARK_SLOTS: u32 = 16u;
const MARGIN_X: f32 = 0.045;
const MARGIN_Y: f32 = 0.045;

fn reflect_range(x: f32, lo: f32, hi: f32) -> f32 {
    let span = max(hi - lo, 1e-4);
    let u = (x - lo) / span;
    let m = u - 2.0 * floor(u * 0.5);
    let f = select(2.0 - m, m, m <= 1.0);
    return lo + f * span;
}

// Smooth 5-stop RGB-balanced vector phosphor palettes.
fn ribbon_palette(pal: u32, x: f32) -> vec3<f32> {
    let p = pal % 4u;
    var c0 = vec3<f32>(0.14, 0.92, 0.98);
    var c1 = vec3<f32>(1.00, 0.34, 0.28);
    var c2 = vec3<f32>(0.26, 0.96, 0.54);
    var c3 = vec3<f32>(0.70, 0.34, 1.00);
    var c4 = vec3<f32>(0.98, 0.78, 0.20);
    if (p == 1u) {
        c0 = vec3<f32>(0.98, 0.26, 0.76);
        c1 = vec3<f32>(0.22, 0.64, 1.00);
        c2 = vec3<f32>(0.18, 0.95, 0.64);
        c3 = vec3<f32>(1.00, 0.60, 0.18);
        c4 = vec3<f32>(0.50, 0.38, 1.00);
    } else if (p == 2u) {
        c0 = vec3<f32>(0.24, 0.88, 1.00);
        c1 = vec3<f32>(0.98, 0.32, 0.48);
        c2 = vec3<f32>(0.56, 0.98, 0.24);
        c3 = vec3<f32>(0.62, 0.44, 1.00);
        c4 = vec3<f32>(1.00, 0.52, 0.20);
    } else if (p == 3u) {
        c0 = vec3<f32>(1.00, 0.36, 0.24);
        c1 = vec3<f32>(0.20, 0.98, 0.50);
        c2 = vec3<f32>(0.24, 0.58, 1.00);
        c3 = vec3<f32>(0.92, 0.32, 0.92);
        c4 = vec3<f32>(0.96, 0.82, 0.22);
    }
    let s = fract(x) * 5.0;
    let i = u32(floor(s)) % 5u;
    let f = smoothstep(0.0, 1.0, fract(s));
    if (i == 0u) { return mix(c0, c1, f); }
    if (i == 1u) { return mix(c1, c2, f); }
    if (i == 2u) { return mix(c2, c3, f); }
    if (i == 3u) { return mix(c3, c4, f); }
    return mix(c4, c0, f);
}

struct ChapterSpec {
    chapter: u32,
    n_ribbons: u32,
    n_verts: u32,
    n_echoes: u32,
    n_edges: u32,
    spread_dt_base: f32,
    half_reach: f32,
    intensity: f32,
    env: f32,
    pal_id: u32,
    phase: f32,
    gen: u32,
};

fn chapter_spec(t: f32) -> ChapterSpec {
    let gen = u32(max(floor(t / EPOCH_SECS), 0.0));
    let phase = t - f32(gen) * EPOCH_SECS;
    let env = smoothstep(0.0, 1.8, phase) * smoothstep(EPOCH_SECS, EPOCH_SECS - 1.8, phase);
    let chapter = (gen + u32(floor(g.seed * 13.0))) % 4u;
    let pal_id = (gen * 3u + u32(floor(g.seed * 17.0))) % 4u;
    let n_ribbons = select(2u, 3u, aspect() > 2.35);

    var n_verts = 2u;
    var n_edges = 1u;
    var n_echoes = 56u;
    var spread_dt_base = 0.040;
    var half_reach = 0.74;
    var intensity = 1.0;

    if (chapter == 1u) {
        n_verts = 3u;
        n_edges = 3u;
        n_echoes = 24u;
        spread_dt_base = 0.062;
        half_reach = 0.64;
        intensity = 0.86;
    } else if (chapter == 2u) {
        n_verts = 4u;
        n_edges = 4u;
        n_echoes = 19u;
        spread_dt_base = 0.075;
        half_reach = 0.61;
        intensity = 0.80;
    } else if (chapter == 3u) {
        n_verts = 2u;
        n_edges = 1u;
        n_echoes = 56u;
        spread_dt_base = 0.040;
        half_reach = 0.56;
        intensity = 0.96;
    }

    return ChapterSpec(
        chapter,
        n_ribbons,
        n_verts,
        n_echoes,
        n_edges,
        spread_dt_base,
        half_reach,
        intensity,
        env,
        pal_id,
        phase,
        gen,
    );
}

struct VertexSample {
    pos: vec2<f32>,
    impact: f32,
};

// Exact O(1) isotropic billiard kinematics in canvas-height coordinates.
fn qix_vertex(spec: ChapterSpec, r: u32, v: u32, tau: f32) -> VertexSample {
    let tau_eval = tau + 12.0;
    let x_lo = MARGIN_X;
    let x_hi = max(aspect() - MARGIN_X, MARGIN_X + 0.25);
    let y_lo = MARGIN_Y;
    let y_hi = 1.0 - MARGIN_Y;
    let span_x = x_hi - x_lo;
    let span_y = y_hi - y_lo;

    let r_seed = f32(r) * 19.3 + f32(spec.gen) * 7.1 + g.seed * 53.0;
    let v_seed = r_seed + f32(v) * 31.7 + f32(spec.chapter) * 11.3;
    let hr = hash22(vec2<f32>(r_seed, f32(spec.chapter) * 5.7 + 1.3));
    let hv = hash22(vec2<f32>(v_seed, r_seed + 9.7));
    let hv2 = hash22(vec2<f32>(v_seed * 1.37 + 3.1, hv.x * 17.9 + g.seed * 29.0));

    let rx = min(spec.half_reach, 0.45 * span_x);
    let cx_lo = x_lo + 0.35 * rx;
    let cx_hi = max(x_hi - 0.35 * rx, cx_lo + 0.08);
    let cx_span = cx_hi - cx_lo;
    let start_frac = fract((f32(r) + 0.5) / f32(max(spec.n_ribbons, 1u)) + (hr.x - 0.5) * 0.14);
    let cx_start = mix(cx_lo, cx_hi, start_frac);
    let cx_dir = select(-1.0, 1.0, ((r + spec.gen) % 2u) == 0u);

    if (spec.chapter == 3u) {
        // Gravity arcs: fast non-stalling horizontal glide + C0 parabolic bounces.
        let cx_speed = mix(0.52, 0.68, hr.y);
        let cx_travel = cx_start + cx_dir * ((tau_eval - 12.0) * cx_speed + 0.16 * sin(tau_eval * 0.33 + hr.x * TAU));
        let cx = reflect_range(cx_travel, cx_lo, cx_hi);

        let ox_speed = mix(0.14, 0.22, hv.x);
        let ox_travel = (hv.y - 0.5) * 2.0 * rx + tau_eval * ox_speed * select(-1.0, 1.0, (v % 2u) == 0u) + 0.06 * sin(tau_eval * 0.47 + hv2.x * TAU);
        let ox = reflect_range(ox_travel, -rx, rx);
        let px = reflect_range(cx + ox, x_lo, x_hi);

        let bounce_rate = mix(0.62, 0.84, hv2.y);
        let u = tau_eval * bounce_rate + hv.x * 5.0 + f32(r) * 1.37;
        let b_idx = floor(u);
        let f = fract(u);
        let h_peak = span_y * mix(0.46, 0.96, hash21(vec2<f32>(b_idx, v_seed * 0.71 + 4.3)));
        let py = y_lo + h_peak * 4.0 * f * (1.0 - f);

        let wall_d = min(min(px - x_lo, x_hi - px), py - y_lo);
        let bounce_pulse = 1.0 - smoothstep(0.0, 0.055, min(f, 1.0 - f));
        let wall_pulse = 1.0 - smoothstep(0.0, 0.035, wall_d);
        return VertexSample(vec2<f32>(px, py), max(bounce_pulse, wall_pulse));
    }

    let cx_speed = mix(0.24, 0.34, hr.y);
    let cx_travel = cx_start + cx_dir * ((tau_eval - 12.0) * cx_speed + 0.18 * sin(tau_eval * 0.29 + hr.x * TAU));
    let cx = reflect_range(cx_travel, cx_lo, cx_hi);

    let ox_speed = mix(0.48, 0.72, hv.x);
    let ox_dir = select(-1.0, 1.0, ((v + r) % 2u) == 0u);
    let ox_travel = (hv.y - 0.5) * 2.0 * rx + ox_dir * (tau_eval * ox_speed + 0.12 * sin(tau_eval * 0.37 + hv2.x * TAU));
    let ox = reflect_range(ox_travel, -rx, rx);
    let px = reflect_range(cx + ox, x_lo, x_hi);

    let y_speed = mix(0.44, 0.76, hv2.y);
    let y_dir = select(-1.0, 1.0, ((v * 3u + r) % 2u) == 0u);
    let y_travel = y_lo + span_y * hv2.x + y_dir * (tau_eval * y_speed + 0.14 * sin(tau_eval * 0.31 + hv.y * TAU));
    let py = reflect_range(y_travel, y_lo, y_hi);

    let wall_d = min(min(px - x_lo, x_hi - px), min(py - y_lo, y_hi - py));
    let impact = 1.0 - smoothstep(0.0, 0.032, wall_d);
    return VertexSample(vec2<f32>(px, py), impact);
}

fn edge_endpoints(chapter: u32, r: u32, e: u32) -> vec2<u32> {
    if (chapter == 1u) {
        return vec2<u32>(e, (e + 1u) % 3u);
    }
    if (chapter == 2u) {
        if ((r % 2u) == 0u) {
            return vec2<u32>(e, (e + 1u) % 4u);
        }
        // Crossed hourglass / bowtie loop: 0 -> 2 -> 1 -> 3 -> 0
        if (e == 0u) { return vec2<u32>(0u, 2u); }
        if (e == 1u) { return vec2<u32>(2u, 1u); }
        if (e == 2u) { return vec2<u32>(1u, 3u); }
        return vec2<u32>(3u, 0u);
    }
    return vec2<u32>(0u, 1u);
}

fn hack(_p: vec2<f32>, _t: f32) -> vec3<f32> {
    return vec3<f32>(0.0);
}

fn shape(idx: u32, t: f32) -> Shape {
    let spec = chapter_spec(t);
    if (spec.env <= 1e-4) {
        return shape_none();
    }

    if (idx >= SEG_SLOTS) {
        let spark_idx = idx - SEG_SLOTS;
        let total_sparks = spec.n_ribbons * spec.n_verts;
        if (spark_idx >= total_sparks) {
            return shape_none();
        }
        let r = spark_idx / spec.n_verts;
        let v = spark_idx % spec.n_verts;
        let rib_seed = f32(r) * 19.3 + f32(spec.gen) * 7.1 + g.seed * 53.0;
        let rib_off = hash11(rib_seed) * 0.37;
        let vs = qix_vertex(spec, r, v, spec.phase);
        let hue_base = ribbon_palette(spec.pal_id, t * 0.22 + rib_off + f32(v) * 0.11);
        let spark_col = mix(hue_base, vec3<f32>(1.0), 0.30 + 0.35 * vs.impact) * spec.intensity;
        let rad = 0.0042 + 0.0026 * vs.impact;
        let glow_r = 0.018 + 0.014 * vs.impact;
        let alpha = (0.72 + 0.24 * vs.impact) * spec.env;
        return shape_glow(
            shape_disc(vs.pos, rad, vec4<f32>(spark_col, alpha), glow_r),
            glow_r,
            0.46 + 0.28 * vs.impact,
        );
    }

    let per_layer = spec.n_ribbons * spec.n_edges;
    let active_segs = spec.n_echoes * per_layer;
    if (idx >= active_segs) {
        return shape_none();
    }

    // Oldest-to-newest draw order so leading vectors cleanly sit over trailing echoes.
    let layer = idx / per_layer;
    let rem = idx % per_layer;
    let r = rem / spec.n_edges;
    let e = rem % spec.n_edges;

    let age_idx = (spec.n_echoes - 1u) - layer;
    let age_frac = f32(age_idx) / f32(max(spec.n_echoes - 1u, 1u));
    let head_w = 1.0 - age_frac;

    let rib_seed = f32(r) * 19.3 + f32(spec.gen) * 7.1 + g.seed * 53.0;
    let h_rib = hash22(vec2<f32>(rib_seed, 3.7));
    let spread_dt = spec.spread_dt_base * mix(0.88, 1.12, h_rib.x);
    let tau = spec.phase - f32(age_idx) * spread_dt;

    let ep = edge_endpoints(spec.chapter, r, e);
    let va = qix_vertex(spec, r, ep.x, tau);
    let vb = qix_vertex(spec, r, ep.y, tau);

    let rib_off = h_rib.y * 0.37;
    let hue_pos = t * 0.22 + rib_off + age_frac * 0.52;
    var col_a = ribbon_palette(spec.pal_id, hue_pos + f32(ep.x) * 0.05) * spec.intensity;
    var col_b = ribbon_palette(spec.pal_id, hue_pos + 0.14 + f32(ep.y) * 0.05) * spec.intensity;

    if (age_idx == 0u) {
        let boost_a = 0.22 + 0.20 * va.impact;
        let boost_b = 0.22 + 0.20 * vb.impact;
        col_a = mix(col_a, vec3<f32>(1.0), boost_a);
        col_b = mix(col_b, vec3<f32>(1.0), boost_b);
    }

    let w_head = 0.0056;
    let w_tail = 0.0026;
    let w_base = mix(w_tail, w_head, pow(head_w, 0.75));
    let w_a = w_base * (1.0 + 0.12 * va.impact * head_w);
    let w_b = w_base * (1.0 + 0.12 * vb.impact * head_w);

    let alpha = (0.10 + 0.84 * pow(head_w, 1.35)) * spec.env;
    let glow_r = select(0.008 * head_w, 0.022, age_idx == 0u);
    let glow_s = select(0.18 * head_w, 0.48, age_idx == 0u);

    return shape_glow(
        shape_segment_taper(
            va.pos,
            vb.pos,
            w_a,
            w_b,
            vec4<f32>(col_a, alpha),
            vec4<f32>(col_b, alpha),
            glow_r,
        ),
        glow_r,
        glow_s,
    );
}

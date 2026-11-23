// Klein Fold: sculptural 3D manifolds drifting and morphing across the dark
// between superquadrics, figure-8 Klein bottles and 4D hypertori.
// After xscreensaver's Superquadrics (Ed Mackey, 2001), Klein (Carsten Steger,
// 2005) and Hypertorus (Carsten Steger, 2003).

const BAY_W: f32 = 2.52;
const R_BOUND: f32 = 1.00;
const SLAB_Z: f32 = 1.24;
const SLAB_Y: f32 = 1.28;

// Anti-aliased crisp stroke of world half-width `hw` with pixel filter half-width `aa`.
fn crisp_line(d: f32, hw: f32, aa: f32) -> f32 {
    let cov = clamp((hw + aa - d) / (2.0 * aa), 0.0, 1.0);
    return smoothstep(0.0, 1.0, cov) * min(1.0, hw / max(aa, 1e-5));
}

// Balanced 6-stop spectral wheel: cyan, cobalt, amethyst, rose, amber-coral, seafoam.
// Adjacent transitions stay vivid and channel shares remain balanced around 33%.
fn klein_palette(x: f32) -> vec3<f32> {
    let p = fract(x);
    let cyan = vec3<f32>(0.16, 0.84, 0.96);
    let cobalt = vec3<f32>(0.24, 0.48, 0.98);
    let amethyst = vec3<f32>(0.68, 0.28, 0.96);
    let rose = vec3<f32>(0.96, 0.24, 0.56);
    let amber = vec3<f32>(0.96, 0.56, 0.18);
    let seafoam = vec3<f32>(0.20, 0.92, 0.62);
    let s = p * 6.0;
    if (s < 1.0) {
        return mix(cyan, cobalt, smoothstep(0.0, 1.0, s));
    }
    if (s < 2.0) {
        return mix(cobalt, amethyst, smoothstep(0.0, 1.0, s - 1.0));
    }
    if (s < 3.0) {
        return mix(amethyst, rose, smoothstep(0.0, 1.0, s - 2.0));
    }
    if (s < 4.0) {
        return mix(rose, amber, smoothstep(0.0, 1.0, s - 3.0));
    }
    if (s < 5.0) {
        return mix(amber, seafoam, smoothstep(0.0, 1.0, s - 4.0));
    }
    return mix(seafoam, cyan, smoothstep(0.0, 1.0, s - 5.0));
}

// Smooth 3-mode shading cycle: (Dichroic Glass, Geodesic Wireframe, Prismatic Contours).
fn stage_weights(t: f32) -> vec3<f32> {
    let stage = t / 42.0 + g.seed * 3.0;
    let idx0 = u32(floor(stage)) % 3u;
    let blend = smoothstep(0.76, 1.0, fract(stage));
    let a = 1.0 - blend;
    if (idx0 == 0u) {
        return vec3<f32>(a, blend, 0.0);
    }
    if (idx0 == 1u) {
        return vec3<f32>(0.0, a, blend);
    }
    return vec3<f32>(blend, 0.0, a);
}

// Per-bay morph weights: (Superquadric, Klein Bottle, 4D Hypertorus).
// Adjacent bays offset by 1/3 cycle so 32:9 displays all three manifolds side by side.
fn morph_weights(cx: f32, t: f32) -> vec3<f32> {
    let stage = t / 28.0 + cx * 0.33333334 + g.seed * 3.0;
    let idx0 = u32(floor(stage)) % 3u;
    let blend = smoothstep(0.65, 1.0, fract(stage));
    let a = 1.0 - blend;
    if (idx0 == 0u) {
        return vec3<f32>(a, blend, 0.0);
    }
    if (idx0 == 1u) {
        return vec3<f32>(0.0, a, blend);
    }
    return vec3<f32>(blend, 0.0, a);
}

struct BayXform {
    q: vec3<f32>,
    sc: f32,
    h: vec2<f32>,
    h2: vec2<f32>,
};

// Transform world point `p` into bay `cx`'s drifting, gently tumbling local frame.
fn bay_xform(p: vec3<f32>, cx: f32, t: f32) -> BayXform {
    let h = hash22(vec2<f32>(cx * 11.3, g.seed * 31.7));
    let h2 = hash22(vec2<f32>(cx * 5.9 + 2.1, g.seed * 17.9 + 4.3));
    let drift_x = t * 0.34 + g.seed * 23.1;

    let x_sway = 0.09 * sin(t * (0.21 + 0.08 * h.x) + h.y * TAU);
    let bx = cx * BAY_W + x_sway - drift_x;
    let by = 0.20 * sin(t * (0.25 + 0.09 * h2.x) + h2.y * TAU);
    let bz = 0.22 * cos(t * (0.22 + 0.07 * h.y) + h.x * TAU);

    let sc = 1.0 + 0.05 * sin(t * (0.31 + 0.08 * h.x) + h2.x * TAU);
    var q = (p - vec3<f32>(bx, by, bz)) / sc;

    let ay = t * (0.30 + 0.10 * h.x) + h.y * TAU;
    let ax = t * (0.19 + 0.07 * h2.x) + h2.y * TAU;
    let xz = rot2(ay) * q.xz;
    q = vec3<f32>(xz.x, q.y, xz.y);
    let yz = rot2(ax) * q.yz;
    q = vec3<f32>(q.x, yz.x, yz.y);

    return BayXform(q, sc, h, h2);
}

// Form 0: Superquadric sweeping through concave star, octahedron, sphere, drum and cube.
// Uses smooth `sqrt((p/r)^2 + eps)` regularization so concave creases stay C-infinity smooth.
fn sd_superquadric(p: vec3<f32>, t: f32, h: vec2<f32>, h2: vec2<f32>) -> f32 {
    let u1 = 0.5 + 0.5 * sin(t * (0.24 + 0.05 * h.x) + h.y * TAU);
    let u2 = 0.5 + 0.5 * cos(t * (0.19 + 0.06 * h2.x) + h2.y * TAU);
    let e1 = mix(0.84, 4.10, u1 * u1 * (3.0 - 2.0 * u1));
    let e2 = mix(0.84, 4.10, u2 * u2 * (3.0 - 2.0 * u2));

    // Normalize bounding radius so diagonal cube corners never clip R_BOUND.
    let diag_norm = pow(pow(2.0, e2 / e1) + 1.0, -1.0 / e2);
    let fit = 1.0 / max(1.0, 1.7320508 * diag_norm);
    let r = vec3<f32>(1.03, 0.94, 1.03) * (0.74 * fit);

    let pr = p / r;
    let q = sqrt(pr * pr + vec3<f32>(0.0014));
    let ax = pow(q.x, e1);
    let ay = pow(q.y, e1);
    let sxy = max(ax + ay, 1e-6);
    let sxy_m = pow(sxy, e2 / e1);
    let az = pow(q.z, e2);
    let sum = max(sxy_m + az, 1e-6);
    let g_val = pow(sum, 1.0 / e2);

    let fac = g_val / sum;
    let fac_xy = fac * sxy_m / sxy;
    let dq_dp = pr / (r * q);
    let grad = vec3<f32>(fac_xy * ax / q.x, fac_xy * ay / q.y, fac * az / q.z) * dq_dp;
    let d_base = 0.85 * (g_val - 1.0) / max(length(grad), 0.72);

    let flute = 0.009 * sin(p.x * 7.5 + t * 0.8) * cos(p.y * 7.5 - t * 0.6) * sin(p.z * 7.5 + t * 0.5);
    return d_base + flute;
}

// Form 1: Figure-8 Klein bottle with saddle curvature and seamless Mobius spiral fluting.
fn sd_klein(p: vec3<f32>, t: f32) -> f32 {
    let r = length(p.xz);
    let safe_x = select(p.x, 1e-5, abs(p.x) + abs(p.z) < 1e-5);
    let phi = atan2(p.z, safe_x);

    let major_r = 0.44;
    let saddle = 0.16 * smoothstep(0.0, 0.22, r) * sin(phi);
    let uv = rot2(phi * 0.5) * vec2<f32>(r - major_r, p.y - saddle);

    let lobe_off = 0.162 * smoothstep(0.0, 0.14, r);
    let tube_r = 0.172;
    let d1 = length(uv - vec2<f32>(lobe_off, 0.0)) - tube_r;
    let d2 = length(uv + vec2<f32>(lobe_off, 0.0)) - tube_r;
    let d_base = smin(d1, d2, 0.052);

    // 4*theta_k - 2*phi shifts by 4*PI - 4*PI = 0 across the phi = +-PI cut.
    let theta_k = atan2(uv.y, select(uv.x, 1e-5, abs(uv.x) + abs(uv.y) < 1e-5));
    let flute = -0.008 * smoothstep(0.04, 0.12, length(uv)) * cos(4.0 * theta_k - 2.0 * phi - t * 0.90);
    return (d_base + flute) * 0.62;
}

// Form 2: 4D Clifford hypertorus stereographically projected as a breathing Dupin cyclide.
fn sd_hypertorus(p: vec3<f32>, t: f32, h: vec2<f32>, h2: vec2<f32>) -> f32 {
    let scale = 2.45;
    let q = p * scale;
    let r2 = dot(q, q);
    var p4 = vec4<f32>(2.0 * q, r2 - 1.0) / (r2 + 1.0);

    let a_xy = t * (0.35 + 0.08 * h.x) + h.y * TAU;
    let a_zw = t * (0.50 + 0.10 * h2.x) + h2.y * TAU;
    let a_xw = 0.24 * sin(t * (0.29 + 0.06 * h.y) + h2.x * TAU);

    let xy1 = rot2(a_xy) * p4.xy;
    let zw1 = rot2(a_zw) * p4.zw;
    let xw2 = rot2(a_xw) * vec2<f32>(xy1.x, zw1.y);
    p4 = vec4<f32>(xw2.x, xy1.y, zw1.x, xw2.y);

    let c1 = length(p4.xy);
    let c2 = length(p4.zw);
    let theta = atan2(c2, max(c1, 1e-5));
    let u = atan2(p4.y, select(p4.x, 1e-5, abs(p4.x) + abs(p4.y) < 1e-5));
    let v = atan2(p4.w, select(p4.z, 1e-5, abs(p4.z) + abs(p4.w) < 1e-5));

    let core_guard = smoothstep(0.05, 0.25, c1) * smoothstep(0.05, 0.25, c2);
    let tube_angle = 0.40 + 0.022 * core_guard * sin(4.0 * u - 3.0 * v);

    let conf = min(r2 + 1.0, 5.2);
    return 0.58 * (theta - tube_angle) * conf / (2.0 * scale);
}

fn morph_push(w: f32) -> f32 {
    let u = max(1.0 - w * 2.0, 0.0);
    return 1.10 * pow(u, 1.35);
}

// Local-space blended manifold SDF for bay `cx`.
// Uses a smooth-union topological bridge mid-morph so thin tubes never fragment into islands,
// and clamps superquadric core depth so no detached seed spawns inside a torus hole.
fn bay_sdf(bx: BayXform, cx: f32, t: f32) -> f32 {
    let mw = morph_weights(cx, t);
    var d = 1e6;
    if (mw.x > 0.999) {
        d = sd_superquadric(bx.q, t, bx.h, bx.h2);
    } else if (mw.y > 0.999) {
        d = sd_klein(bx.q, t);
    } else if (mw.z > 0.999) {
        d = sd_hypertorus(bx.q, t, bx.h, bx.h2);
    } else if (mw.x > 0.001 && mw.y > 0.001) {
        let da = max(sd_superquadric(bx.q, t, bx.h, bx.h2), -0.32) + morph_push(mw.x);
        let db = sd_klein(bx.q, t) + morph_push(mw.y);
        let k = 0.25 * sin(mw.y * PI) + 0.002;
        d = smin(da, db, k);
    } else if (mw.y > 0.001 && mw.z > 0.001) {
        let da = sd_klein(bx.q, t) + morph_push(mw.y);
        let db = sd_hypertorus(bx.q, t, bx.h, bx.h2) + morph_push(mw.z);
        let k = 0.25 * sin(mw.z * PI) + 0.002;
        d = smin(da, db, k);
    } else {
        let da = sd_hypertorus(bx.q, t, bx.h, bx.h2) + morph_push(mw.z);
        let db = max(sd_superquadric(bx.q, t, bx.h, bx.h2), -0.32) + morph_push(mw.x);
        let k = 0.25 * sin(mw.x * PI) + 0.002;
        d = smin(da, db, k);
    }
    return d * bx.sc;
}

// Conservative signed distance over the 2 nearest drifting gallery bays.
fn sdf(p: vec3<f32>, t: f32) -> f32 {
    let drift_x = t * 0.34 + g.seed * 23.1;
    let x_world = p.x + drift_x;
    let c0 = round(x_world / BAY_W);
    let c1 = c0 + select(-1.0, 1.0, x_world > c0 * BAY_W);

    var d = 1e6;
    for (var i: i32 = 0; i < 2; i = i + 1) {
        let cx = select(c1, c0, i == 0);
        let bx = bay_xform(p, cx, t);
        let d_sph = (length(bx.q) - R_BOUND) * bx.sc;
        if (d_sph > 0.08) {
            d = min(d, d_sph);
        } else {
            d = min(d, bay_sdf(bx, cx, t));
        }
    }
    return d;
}

// Parametric geodesic wireframe intensity specific to each manifold, blended across morphs.
fn manifold_wire(bx: BayXform, cx: f32, t: f32, px_w: f32) -> vec2<f32> {
    let mw = morph_weights(cx, t);
    let p = bx.q;
    let w_aa = px_w * 1.25 / max(bx.sc, 0.5);
    var major = 0.0;
    var minor = 0.0;

    if (mw.x > 0.001) {
        let r_xz = length(p.xz);
        let safe_x = select(p.x, 1e-5, abs(p.x) + abs(p.z) < 1e-5);
        let lon = atan2(p.z, safe_x) / TAU;
        let lat = atan2(p.y, max(r_xz, 1e-4)) / PI;
        let r_len = max(length(p), 0.2);

        let d_lon = abs(fract(lon * 12.0 + t * 0.04) - 0.5) * (TAU * max(r_xz, 0.06) / 12.0);
        let d_lat = abs(fract(lat * 8.0 + 0.5 - t * 0.03) - 0.5) * (PI * r_len / 8.0);
        let pole_fade = smoothstep(0.06, 0.22, r_xz / r_len);
        let w_lon = crisp_line(d_lon, 0.012, w_aa) * pole_fade;
        let w_lat = crisp_line(d_lat, 0.012, w_aa);
        major = major + mw.x * max(w_lon, w_lat);
        minor = minor + mw.x * min(w_lon, w_lat);
    }

    if (mw.y > 0.001) {
        let r = length(p.xz);
        let safe_x = select(p.x, 1e-5, abs(p.x) + abs(p.z) < 1e-5);
        let phi = atan2(p.z, safe_x);
        let saddle = 0.16 * smoothstep(0.0, 0.22, r) * sin(phi);
        let uv = rot2(phi * 0.5) * vec2<f32>(r - 0.44, p.y - saddle);
        let theta_k = atan2(uv.y, select(uv.x, 1e-5, abs(uv.x) + abs(uv.y) < 1e-5));

        let d_phi = abs(fract(phi * 10.0 / TAU - t * 0.04) - 0.5) * (TAU * max(r, 0.16) / 10.0);
        // Half-integer twist in phi matches theta_k -> theta_k + PI when phi -> phi + 2*PI.
        let d_th = abs(fract((6.0 * theta_k - 1.5 * phi) / PI + t * 0.06) - 0.5) * (PI * 0.165 / 6.0);
        let w_p = crisp_line(d_phi, 0.012, w_aa);
        let w_t = crisp_line(d_th, 0.012, w_aa);
        major = major + mw.y * max(w_p, w_t);
        minor = minor + mw.y * min(w_p, w_t);
    }

    if (mw.z > 0.001) {
        let scale = 2.45;
        let q = p * scale;
        let r2 = dot(q, q);
        var p4 = vec4<f32>(2.0 * q, r2 - 1.0) / (r2 + 1.0);
        let a_xy = t * (0.35 + 0.08 * bx.h.x) + bx.h.y * TAU;
        let a_zw = t * (0.50 + 0.10 * bx.h2.x) + bx.h2.y * TAU;
        let a_xw = 0.24 * sin(t * (0.29 + 0.06 * bx.h.y) + bx.h2.x * TAU);
        let xy1 = rot2(a_xy) * p4.xy;
        let zw1 = rot2(a_zw) * p4.zw;
        let xw2 = rot2(a_xw) * vec2<f32>(xy1.x, zw1.y);
        p4 = vec4<f32>(xw2.x, xy1.y, zw1.x, xw2.y);

        let c1 = max(length(p4.xy), 0.10);
        let c2 = max(length(p4.zw), 0.10);
        let u = atan2(p4.y, select(p4.x, 1e-5, abs(p4.x) + abs(p4.y) < 1e-5));
        let v = atan2(p4.w, select(p4.z, 1e-5, abs(p4.z) + abs(p4.w) < 1e-5));
        let metric = (r2 + 1.0) / (2.0 * scale);

        let h_a = (4.0 * u - 3.0 * v) / TAU + t * 0.05;
        let h_b = (3.0 * u + 4.0 * v) / TAU - t * 0.04;
        let d_a = abs(fract(h_a) - 0.5) * (TAU * metric * min(c1, c2) / 4.2);
        let d_b = abs(fract(h_b) - 0.5) * (TAU * metric * min(c1, c2) / 4.2);
        let w_a = crisp_line(d_a, 0.012, w_aa);
        let w_b = crisp_line(d_b, 0.012, w_aa);
        major = major + mw.z * max(w_a, w_b);
        minor = minor + mw.z * min(w_a, w_b);
    }

    return vec2<f32>(clamp(major, 0.0, 1.0), clamp(minor, 0.0, 1.0));
}

// Sparse twinkling background dust staying safely below LIT so background never dwells.
fn background_dust(p: vec2<f32>, t: f32) -> f32 {
    let uv = vec2<f32>(p.x * 4.2 + t * 0.11, p.y * 4.2 + sin(t * 0.07) * 0.4);
    let cid = floor(uv);
    let f = fract(uv);
    let h = hash22(cid + vec2<f32>(g.seed * 17.3, 9.1));
    if (h.x < 0.68) {
        return 0.0;
    }
    let center = vec2<f32>(0.25 + 0.5 * h.x, 0.25 + 0.5 * h.y)
        + 0.09 * vec2<f32>(cos(t * 1.2 + h.y * TAU), sin(t * 1.0 + h.x * TAU));
    let d = length(f - center);
    let twinkle = 0.45 + 0.55 * sin(t * 2.1 + h.x * TAU);
    return smoothstep(0.06, 0.010, d) * twinkle * 0.10;
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let ro = vec3<f32>(0.0, 0.07 * sin(t * 0.13 + g.seed * TAU), 3.55);
    let look_at = vec3<f32>(
        0.10 * sin(t * 0.09 + g.seed * 3.1),
        0.05 * cos(t * 0.11 + 1.4),
        0.0,
    );
    let roll = 0.03 * sin(t * 0.08 + g.seed * 4.1);
    let focal = 1.38;
    let rd = camera_ray(p, ro, look_at, roll, focal);

    // Analytical Z-slab and Y-slab rejection keep lavapipe fast and skip empty margins.
    let inv_z = 1.0 / min(rd.z, -0.05);
    let t_enter = max((SLAB_Z - ro.z) * inv_z, 0.0);
    let t_exit = max((-SLAB_Z - ro.z) * inv_z, t_enter + 0.01);
    let ro_slab = ro + rd * t_enter;
    let ro_exit = ro + rd * t_exit;

    let bg = vec3<f32>(0.001, 0.002, 0.004);
    let t_mid = -ro.z * inv_z;
    let p_mid = ro + rd * t_mid;
    let drift_x = t * 0.34 + g.seed * 23.1;
    let mid_hue = t * 0.022 + (p_mid.x + drift_x * 0.25) * 0.08 + p_mid.y * 0.07 + g.seed;
    let dust = klein_palette(mid_hue + 0.31) * background_dust(p, t);

    var h = Hit(0.0, 0.0, false);
    if (!(ro_slab.y > SLAB_Y && ro_exit.y > SLAB_Y) && !(ro_slab.y < -SLAB_Y && ro_exit.y < -SLAB_Y)) {
        h = rm_march(ro_slab, rd, t, t_exit - t_enter, 64, 0.80);
    }

    // Evaluate true manifold distance (no bounding-sphere discontinuity) for ring-free aura.
    let c_mid = round((p_mid.x + drift_x) / BAY_W);
    let bx_mid = bay_xform(p_mid, c_mid, t);
    let d_mid = bay_sdf(bx_mid, c_mid, t);
    let halo = klein_palette(mid_hue) * exp(-max(d_mid, 0.0) * 3.8) * 0.085;
    var col = bg + halo + dust;

    if (h.hit) {
        let total_d = t_enter + h.dist;
        let hp = ro + rd * total_d;
        let n = rm_normal(hp, t, 0.0020);
        let ao = rm_ao(hp, n, t);
        let v = -rd;

        let x_world = hp.x + drift_x;
        let c0 = round(x_world / BAY_W);
        let c1 = c0 + select(-1.0, 1.0, x_world > c0 * BAY_W);
        let bx0 = bay_xform(hp, c0, t);
        let bx1 = bay_xform(hp, c1, t);
        let use0 = bay_sdf(bx0, c0, t) <= bay_sdf(bx1, c1, t);
        let cx_hit = select(c1, c0, use0);
        var bx = bx1;
        if (use0) {
            bx = bx0;
        }

        // Two rotating lights + grazing Fresnel rims.
        let l0 = normalize(vec3<f32>(0.62 * cos(t * 0.27 + g.seed * TAU), 0.56, 0.55));
        let l1 = normalize(vec3<f32>(-0.58 * sin(t * 0.21 + 1.4), -0.62, 0.52));
        let diff0 = max(dot(n, l0), 0.0);
        let diff1 = max(dot(n, l1), 0.0);
        let spec0 = pow(max(dot(n, normalize(l0 + v)), 0.0), 28.0);
        let spec1 = pow(max(dot(n, normalize(l1 + v)), 0.0), 20.0);

        let ndv = max(dot(n, v), 0.0);
        let rim = fresnel(n, v, 1.75);
        let rim_sharp = fresnel(n, v, 3.6);

        let pearl = vec3<f32>(0.95, 0.96, 1.0);
        let base_h = t * 0.028 + cx_hit * 0.34 + dot(bx.q, vec3<f32>(0.26, 0.30, 0.22)) + g.seed;
        let tint = klein_palette(base_h + (1.0 - ndv) * 0.54);
        let accent = klein_palette(base_h + (1.0 - ndv) * 0.54 + 0.26);

        // Moving internal caustic wave keeps interior sheen below LIT while shifting continuously.
        let conv = 0.5 + 0.5 * sin(bx.q.x * 5.2 + bx.q.y * 4.4 - t * 1.15 + sin(bx.q.z * 4.8 + t * 0.6));
        let conv2 = 0.5 + 0.5 * cos(bx.q.y * 4.6 - bx.q.z * 5.1 + t * 0.92);
        let core_body = mix(tint, accent, 0.45 * conv)
            * (0.032 + 0.082 * diff0 * ao + 0.042 * diff1 + 0.055 * pow(conv, 2.0));

        // Mode 0: Dichroic Glass (thin-film interference bands, luminous rim, internal caustics).
        let thin_film = 0.5 + 0.5 * sin((1.0 - ndv) * 11.0 - t * 0.95 + dot(bx.q, vec3<f32>(2.4, 1.8, 2.1)));
        let film_tint = klein_palette(base_h + (1.0 - ndv) * 0.72 + 0.14 * thin_film);
        let crease = pow(1.0 - ao, 1.15) * (0.50 + 0.50 * conv2);
        let glass_rim = mix(film_tint, pearl, 0.20 + 0.14 * conv) * rim * (1.22 + 0.40 * conv)
            + mix(accent, pearl, 0.34) * rim_sharp * (0.78 + 0.30 * diff0);
        let glass_caustic = mix(film_tint, accent, 0.5) * pow(conv, 2.0) * (0.38 + 0.34 * diff0) * (0.35 + 0.65 * rim);
        let glass_sheen = mix(tint, accent, thin_film) * pow(thin_film, 3.0) * (0.18 + 0.36 * rim) * (0.4 + 0.6 * diff0);
        let glass_crease = mix(accent, pearl, 0.28) * crease * 0.72;
        let glass_spec = mix(film_tint, pearl, 0.48) * (spec0 * 1.05 + spec1 * 0.66);
        let glass_col = core_body + glass_rim + glass_caustic + glass_sheen + glass_crease + glass_spec;

        // Mode 1: Geodesic Wireframe (crisp parametric ribs over dark obsidian-glass hull).
        let px_w = total_d / (focal * max(g.target_size.y, 1.0));
        let wire = manifold_wire(bx, cx_hit, t, px_w);
        let wire_col = mix(accent, pearl, 0.30 + 0.22 * wire.y) * wire.x * (0.86 + 0.42 * (0.35 + 0.65 * rim))
            + mix(tint, pearl, 0.42) * wire.y * 0.36;
        let wire_rim = tint * rim * (0.94 + 0.28 * conv2);
        let wire_spec = mix(accent, pearl, 0.46) * (spec0 * 0.72 + spec1 * 0.44);
        let geodesic_col = core_body * 0.78 + wire_col + wire_rim + wire_spec;

        // Mode 2: Prismatic Contours (flowing 3D harmonic iso-contours + gyroid interference veins).
        let iso_ph = (bx.q.x + bx.q.y * 0.8 + bx.q.z * 0.6) * 3.4 - t * 0.72 + 0.38 * sin(bx.q.z * 3.5 + t * 0.5);
        let d_iso = abs(fract(iso_ph) - 0.5) / 3.4;
        let iso_line = crisp_line(d_iso, 0.015, px_w * 1.15);
        let gq = bx.q * 6.4 + vec3<f32>(t * 0.55, -t * 0.75, t * 0.35);
        let gy = abs(dot(sin(gq), cos(gq.yzx)));
        let gy_glow = exp(-gy * 6.4) * (0.78 + 0.42 * conv);
        let contour_col = core_body * 0.76
            + mix(tint, pearl, 0.18) * gy_glow
            + mix(accent, pearl, 0.36) * iso_line * (0.84 + 0.44 * rim)
            + mix(tint, pearl, 0.22) * rim * (0.92 + 0.32 * conv)
            + mix(accent, pearl, 0.44) * spec0 * 0.68;

        let sw = stage_weights(t);
        let surf_col = glass_col * sw.x + geodesic_col * sw.y + contour_col * sw.z;
        let edge_fade = exp(-max(total_d - 2.6, 0.0) * 0.14);
        col = mix(col, surf_col, edge_fade);
    }

    return col / (vec3<f32>(1.0) + col * 0.20);
}

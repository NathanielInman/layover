// Shared raymarch routines for hacks with `raymarch: true`.
// The hack defines `fn sdf(p: vec3<f32>, t: f32) -> f32` and calls these
// helpers for sphere tracing, tetrahedron normals, AO, and soft shadows.

struct Hit {
    dist: f32,
    steps: f32,
    hit: bool,
};

// Sphere trace `sdf(p, t)` from `ro` along normalized `rd`. `step_scale` (< 1)
// guards slightly non-Euclidean deformations like gentle corridor twists.
fn rm_march(
    ro: vec3<f32>,
    rd: vec3<f32>,
    t: f32,
    max_d: f32,
    max_steps: i32,
    step_scale: f32,
) -> Hit {
    var d = 0.0;
    for (var i = 0; i < max_steps; i = i + 1) {
        let h = sdf(ro + rd * d, t);
        let eps = max(0.0008, 0.0014 * d);
        if (h < eps) {
            return Hit(d, f32(i) / f32(max(max_steps, 1)), true);
        }
        d = d + h * step_scale;
        if (d > max_d) {
            return Hit(max_d, f32(i) / f32(max(max_steps, 1)), false);
        }
    }
    return Hit(d, 1.0, false);
}

// 4-tap tetrahedron gradient (cheaper than 6-tap central differences).
fn rm_normal(p: vec3<f32>, t: f32, eps: f32) -> vec3<f32> {
    let e = vec2<f32>(1.0, -1.0);
    let n = e.xyy * sdf(p + e.xyy * eps, t)
        + e.yyx * sdf(p + e.yyx * eps, t)
        + e.yxy * sdf(p + e.yxy * eps, t)
        + e.xxx * sdf(p + e.xxx * eps, t);
    return normalize(n);
}

// 4-tap local ambient occlusion along the surface normal.
fn rm_ao(p: vec3<f32>, n: vec3<f32>, t: f32) -> f32 {
    var occ = 0.0;
    var w = 0.5;
    for (var i = 1; i <= 4; i = i + 1) {
        let h = 0.045 * f32(i) * f32(i);
        let d = sdf(p + n * h, t);
        occ = occ + max(h - d, 0.0) * w;
        w = w * 0.55;
    }
    return clamp(1.0 - occ * 2.2, 0.08, 1.0);
}

// Bounded soft shadow from `ro` toward `rd` (max 16 taps to stay cheap).
fn rm_shadow(ro: vec3<f32>, rd: vec3<f32>, t: f32, tmin: f32, tmax: f32, k: f32) -> f32 {
    var res = 1.0;
    var d = tmin;
    for (var i = 0; i < 16; i = i + 1) {
        let h = sdf(ro + rd * d, t);
        if (h < 0.001) {
            return 0.0;
        }
        res = min(res, k * h / max(d, 1e-4));
        d = d + clamp(h, 0.02, 0.35);
        if (d > tmax) {
            break;
        }
    }
    return clamp(res, 0.0, 1.0);
}

// Shared compute particle & atomic splat helpers for Tier P hacks (`particles: Some(...)`).
//
// A Tier P hack runs on top of Tier S ping-pong `rgba16f` feedback state textures and
// defines two compute hooks in addition to `fn hack(p: vec2<f32>, t: f32) -> vec3<f32>`:
//
//   fn step_particle(idx: u32, t: f32)
//     Updates `particles[idx]` and splats energy into `splat_buf` via `splat_*` helpers.
//
//   fn resolve_state(uv: vec2<f32>, p: vec2<f32>, t: f32, splat: vec4<f32>) -> vec4<f32>
//     Combines `state_faded(uv)` (or neighbors) with the accumulated `splat` and writes the
//     new `state_out` texel. `splat_buf` is cleared to zero automatically during resolve.

struct Particle {
    p: vec4<f32>,
    v: vec4<f32>,
    c: vec4<f32>,
};

@group(2) @binding(0) var<storage, read_write> particles: array<Particle>;
@group(2) @binding(1) var<storage, read_write> splat_buf: array<atomic<u32>>;
@group(3) @binding(0) var state_out: texture_storage_2d<rgba16float, write>;

// Fixed-point quantization scale for atomic u32 splat accumulation (gives ~131k
// headroom per channel per texel per substep before wrapping u32).
const SPLAT_SCALE: f32 = 32768.0;

fn particle_count() -> u32 {
    return arrayLength(&particles);
}

fn splat_dims() -> vec2<i32> {
    return vec2<i32>(textureDimensions(state_tex));
}

// Fast PCG-style 32-bit step (bijective on u32, no zero-lockup state).
fn rng_step(s: u32) -> u32 {
    let state = s * 747796405u + 2891336453u;
    let word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

fn rng_f32(state: ptr<function, u32>) -> f32 {
    *state = rng_step(*state);
    return f32(*state & 0x00ffffffu) / 16777216.0;
}

fn splat_pixel(coord: vec2<i32>, val: vec4<f32>) {
    let dims = splat_dims();
    if (coord.x < 0 || coord.y < 0 || coord.x >= dims.x || coord.y >= dims.y) {
        return;
    }
    let base = (u32(coord.y) * u32(dims.x) + u32(coord.x)) * 4u;
    let scaled = clamp(val * SPLAT_SCALE, vec4<f32>(0.0), vec4<f32>(16777216.0));
    let u = vec4<u32>(round(scaled));
    if (u.x > 0u) {
        atomicAdd(&splat_buf[base + 0u], u.x);
    }
    if (u.y > 0u) {
        atomicAdd(&splat_buf[base + 1u], u.y);
    }
    if (u.z > 0u) {
        atomicAdd(&splat_buf[base + 2u], u.z);
    }
    if (u.w > 0u) {
        atomicAdd(&splat_buf[base + 3u], u.w);
    }
}

fn splat_pixel_wrap(coord: vec2<i32>, val: vec4<f32>) {
    let dims = splat_dims();
    let wcoord = ((coord % dims) + dims) % dims;
    splat_pixel(wcoord, val);
}

fn splat_point_ex(p: vec2<f32>, rgb: vec3<f32>, w: f32, wrap: bool) {
    let dims = splat_dims();
    let uv = state_uv(p);
    let fc = uv * vec2<f32>(dims) - 0.5;
    let base = vec2<i32>(floor(fc));
    let f = fc - vec2<f32>(base);
    let val = vec4<f32>(max(rgb, vec3<f32>(0.0)), max(w, 0.0));
    let k00 = (1.0 - f.x) * (1.0 - f.y);
    let k10 = f.x * (1.0 - f.y);
    let k01 = (1.0 - f.x) * f.y;
    let k11 = f.x * f.y;
    if (wrap) {
        splat_pixel_wrap(base + vec2<i32>(0, 0), val * k00);
        splat_pixel_wrap(base + vec2<i32>(1, 0), val * k10);
        splat_pixel_wrap(base + vec2<i32>(0, 1), val * k01);
        splat_pixel_wrap(base + vec2<i32>(1, 1), val * k11);
    } else {
        splat_pixel(base + vec2<i32>(0, 0), val * k00);
        splat_pixel(base + vec2<i32>(1, 0), val * k10);
        splat_pixel(base + vec2<i32>(0, 1), val * k01);
        splat_pixel(base + vec2<i32>(1, 1), val * k11);
    }
}

fn splat_point(p: vec2<f32>, rgb: vec3<f32>, w: f32) {
    splat_point_ex(p, rgb, w, false);
}

fn splat_point_wrap(p: vec2<f32>, rgb: vec3<f32>, w: f32) {
    splat_point_ex(p, rgb, w, true);
}

// Soft circular splat in canvas-height radius, normalized so total splatted energy matches `(rgb, w)`.
fn splat_disc(p: vec2<f32>, radius: f32, rgb: vec3<f32>, w: f32, wrap: bool) {
    let dims = splat_dims();
    let px_r = radius * f32(dims.y);
    if (px_r <= 0.65) {
        splat_point_ex(p, rgb, w, wrap);
        return;
    }
    let ir = clamp(i32(ceil(px_r)), 1, 6);
    let center_px = state_uv(p) * vec2<f32>(dims) - 0.5;
    let base = vec2<i32>(round(center_px));
    let r_eff = max(px_r, 0.75);

    var total = 0.0;
    for (var dy = -ir; dy <= ir; dy = dy + 1) {
        for (var dx = -ir; dx <= ir; dx = dx + 1) {
            let d = length(vec2<f32>(base + vec2<i32>(dx, dy)) - center_px);
            let t = clamp(1.0 - d / r_eff, 0.0, 1.0);
            total = total + t * t * (3.0 - 2.0 * t);
        }
    }
    if (total <= 1e-5) {
        splat_point_ex(p, rgb, w, wrap);
        return;
    }
    let val = vec4<f32>(max(rgb, vec3<f32>(0.0)), max(w, 0.0)) / total;
    for (var dy = -ir; dy <= ir; dy = dy + 1) {
        for (var dx = -ir; dx <= ir; dx = dx + 1) {
            let c = base + vec2<i32>(dx, dy);
            let d = length(vec2<f32>(c) - center_px);
            let t = clamp(1.0 - d / r_eff, 0.0, 1.0);
            let k = t * t * (3.0 - 2.0 * t);
            if (k > 0.001) {
                if (wrap) {
                    splat_pixel_wrap(c, val * k);
                } else {
                    splat_pixel(c, val * k);
                }
            }
        }
    }
}

fn splat_segment(p0: vec2<f32>, p1: vec2<f32>, rgb: vec3<f32>, w: f32, wrap: bool) {
    let dims = splat_dims();
    let dp = (p1 - p0) * f32(dims.y);
    let n = clamp(i32(ceil(length(dp) * 1.25)), 1, 24);
    let inv = 1.0 / f32(n);
    let seg_rgb = rgb * inv;
    let seg_w = w * inv;
    for (var i = 0; i < n; i = i + 1) {
        let u = (f32(i) + 0.5) * inv;
        splat_point_ex(mix(p0, p1, u), seg_rgb, seg_w, wrap);
    }
}

// Shared by every hack. A hack defines `fn hack(p: vec2<f32>, t: f32) -> vec3<f32>`:
// `p` is the canvas position in canvas heights (y from 0 at the bottom to 1
// at the top, x from 0 to aspect()), `t` is seconds. Return 0..1 color; the
// care pass applies drive, hue turn, white cap and the limiter afterwards,
// so design for the full range and let rule one scale it.

struct Globals {
    canvas: vec2<f32>,
    target_size: vec2<f32>,
    orbit: vec2<f32>,
    time: f32,
    seed: f32,
    dt: f32,
    fade: f32,
    frame: f32,
    _pad: f32,
};

@group(0) @binding(0) var<uniform> g: Globals;

struct VsOut {
    @builtin(position) pos: vec4<f32>,
};

@vertex
fn vs(@builtin(vertex_index) i: u32) -> VsOut {
    let x = f32((i << 1u) & 2u);
    let y = f32(i & 2u);
    var o: VsOut;
    o.pos = vec4<f32>(x * 2.0 - 1.0, 1.0 - y * 2.0, 0.0, 1.0);
    return o;
}

const PI: f32 = 3.14159265;
const TAU: f32 = 6.28318531;

fn aspect() -> f32 {
    return g.canvas.x / g.canvas.y;
}

fn hash11(p: f32) -> f32 {
    var x = fract(p * 0.1031);
    x = x * (x + 33.33);
    x = x * (x + x);
    return fract(x);
}

fn hash21(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    p3 = p3 + dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn hash22(p: vec2<f32>) -> vec2<f32> {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
    p3 = p3 + dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash21(i);
    let b = hash21(i + vec2<f32>(1.0, 0.0));
    let c = hash21(i + vec2<f32>(0.0, 1.0));
    let d = hash21(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn fbm(p: vec2<f32>) -> f32 {
    var sum = 0.0;
    var amp = 0.5;
    var q = p;
    for (var i = 0; i < 4; i = i + 1) {
        sum = sum + amp * noise(q);
        q = q * 2.03 + vec2<f32>(1.7, 9.2);
        amp = amp * 0.5;
    }
    return sum;
}

// Soft disc: 1 inside radius r, fading over `edge`.
fn disc(d: f32, r: f32, edge: f32) -> f32 {
    return 1.0 - smoothstep(r - edge, r, d);
}

// --- Raymarching & 3D SDF helpers (Tier R) ---------------------------------

fn rot2(a: f32) -> mat2x2<f32> {
    let c = cos(a);
    let s = sin(a);
    return mat2x2<f32>(c, -s, s, c);
}

// World-space ray for canvas coordinate `p` (y in 0..1, x in 0..aspect()).
// `focal` is the vertical focal length in canvas heights (e.g. 1.1..1.4).
fn camera_ray(p: vec2<f32>, ro: vec3<f32>, look_at: vec3<f32>, roll: f32, focal: f32) -> vec3<f32> {
    let uv = p - vec2<f32>(aspect() * 0.5, 0.5);
    let fwd = normalize(look_at - ro);
    let up0 = vec3<f32>(sin(roll), cos(roll), 0.0);
    let ref_up = select(up0, vec3<f32>(0.0, 0.0, 1.0), abs(dot(fwd, up0)) > 0.99);
    let right = normalize(cross(fwd, ref_up));
    let up = cross(right, fwd);
    return normalize(right * uv.x + up * uv.y + fwd * focal);
}

fn sd_sphere(p: vec3<f32>, r: f32) -> f32 {
    return length(p) - r;
}

fn sd_box(p: vec3<f32>, b: vec3<f32>) -> f32 {
    let q = abs(p) - b;
    return length(max(q, vec3<f32>(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
}

fn sd_round_box(p: vec3<f32>, b: vec3<f32>, r: f32) -> f32 {
    return sd_box(p, b - vec3<f32>(r)) - r;
}

fn sd_torus(p: vec3<f32>, r: vec2<f32>) -> f32 {
    let q = vec2<f32>(length(p.xz) - r.x, p.y);
    return length(q) - r.y;
}

fn sd_capsule(p: vec3<f32>, a: vec3<f32>, b: vec3<f32>, r: f32) -> f32 {
    let pa = p - a;
    let ba = b - a;
    let h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

fn sd_octahedron(p: vec3<f32>, s: f32) -> f32 {
    let a = abs(p);
    return (a.x + a.y + a.z - s) * 0.57735027;
}

// Infinite three-axis square cross of half-width `w` (Menger carving primitive).
fn sd_cross(p: vec3<f32>, w: f32) -> f32 {
    let a = abs(p);
    let d_xy = max(a.x, a.y);
    let d_yz = max(a.y, a.z);
    let d_zx = max(a.z, a.x);
    return min(d_xy, min(d_yz, d_zx)) - w;
}

// Polynomial smooth union and smooth intersection.
fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (b - a) / max(k, 1e-5), 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

fn smax(a: f32, b: f32, k: f32) -> f32 {
    return -smin(-a, -b, k);
}

// Infinite domain repetition centered on [-period/2, period/2].
fn op_rep(p: vec3<f32>, period: vec3<f32>) -> vec3<f32> {
    return p - period * round(p / period);
}

// Grazing-angle rim factor (keeps interiors dim and edges readable on OLEDs).
fn fresnel(n: vec3<f32>, v: vec3<f32>, power: f32) -> f32 {
    return pow(clamp(1.0 - max(dot(n, v), 0.0), 0.0, 1.0), power);
}

// Exponential squared distance fog toward `fog`.
fn fog_exp(col: vec3<f32>, fog: vec3<f32>, dist: f32, density: f32) -> vec3<f32> {
    return mix(fog, col, exp(-dist * dist * density));
}


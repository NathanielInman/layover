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

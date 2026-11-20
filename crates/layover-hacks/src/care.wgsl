// The care pass: rule one, applied to every output of every frame. See
// "Hacks" in docs/design.md.

struct Care {
    rect: vec4<f32>,
    canvas: vec2<f32>,
    px_to_canvas: vec2<f32>,
    drive: f32,
    white: f32,
    hue: f32,
    hue_on: f32,
    fade: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
};

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var src_sampler: sampler;
@group(0) @binding(2) var<uniform> care: Care;
@group(0) @binding(3) var<storage, read> gain_in: array<f32, 2>;

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

// Turn the hue about the grey axis. This keeps r + g + b, so the average
// level and the limiter don't change with it.
fn hue_turn(c: vec3<f32>, a: f32) -> vec3<f32> {
    let k = vec3<f32>(0.57735027);
    let ca = cos(a);
    return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
}

@fragment
fn fs(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let canvas_px = care.rect.xy + pos.xy * care.px_to_canvas;
    var c = textureSample(src, src_sampler, canvas_px / care.canvas).rgb;
    if (care.hue_on > 0.5) {
        c = hue_turn(c, care.hue);
    }
    var g = gain_in[0];
    if (g <= 0.0) {
        g = 1.0;
    }
    c = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0)) * care.drive * g;
    let w = min(c.r, min(c.g, c.b));
    if (w > care.white) {
        c = c - vec3<f32>(w - care.white);
    }
    return vec4<f32>(c * care.fade, 1.0);
}

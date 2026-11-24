// Shared feedback helpers for Tier S stateful hacks (`feedback: Some(...)`).
// The hack defines `fn step_state(uv: vec2<f32>, p: vec2<f32>, t: f32) -> vec4<f32>`
// in addition to `fn hack(p: vec2<f32>, t: f32) -> vec3<f32>`.

@group(1) @binding(0) var state_tex: texture_2d<f32>;
@group(1) @binding(1) var state_sampler: sampler;

fn state_uv(p: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(p.x / aspect(), 1.0 - p.y);
}

fn state_texel() -> vec2<f32> {
    return 1.0 / max(vec2<f32>(textureDimensions(state_tex)), vec2<f32>(1.0));
}

fn state_sample(uv: vec2<f32>) -> vec4<f32> {
    return textureSampleLevel(state_tex, state_sampler, uv, 0.0);
}

fn state_faded(uv: vec2<f32>) -> vec4<f32> {
    return state_sample(uv) * g.fade;
}

fn state_offset(uv: vec2<f32>, dx: f32, dy: f32) -> vec4<f32> {
    return state_sample(uv + vec2<f32>(dx, dy) * state_texel());
}

fn state_laplacian(uv: vec2<f32>) -> vec4<f32> {
    let d = state_texel();
    let center = state_sample(uv);
    let card = state_sample(uv + vec2<f32>(d.x, 0.0))
        + state_sample(uv + vec2<f32>(-d.x, 0.0))
        + state_sample(uv + vec2<f32>(0.0, d.y))
        + state_sample(uv + vec2<f32>(0.0, -d.y));
    let diag = state_sample(uv + vec2<f32>(d.x, d.y))
        + state_sample(uv + vec2<f32>(-d.x, d.y))
        + state_sample(uv + vec2<f32>(d.x, -d.y))
        + state_sample(uv + vec2<f32>(-d.x, -d.y));
    return card * 0.2 + diag * 0.05 - center;
}

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
    aa_on: f32,
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

// Perceptual luma weighted to stay responsive to blue and violet OLED rims.
fn fxaa_luma(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.26, 0.52, 0.22));
}

// Lightweight FXAA 3.11 Quality pass over the offscreen hack texture.
// Uses output-pixel UV spacing (`px_step`) so bilinear upscaling from
// `render_scale < 1` is smoothed smoothly at native resolution without
// quantizing edges to coarse texel blocks or crossing neighbors.
fn sample_aa(uv: vec2<f32>) -> vec3<f32> {
    let rgb_m = textureSampleLevel(src, src_sampler, uv, 0.0).rgb;
    if (care.aa_on < 0.5) {
        return rgb_m;
    }

    let tex_size = vec2<f32>(textureDimensions(src));
    let inv_tex = 1.0 / max(tex_size, vec2<f32>(1.0));
    let px_step = min(care.px_to_canvas / max(care.canvas, vec2<f32>(1.0)), inv_tex);

    let luma_m = fxaa_luma(rgb_m);
    let luma_n = fxaa_luma(textureSampleLevel(src, src_sampler, uv + vec2<f32>(0.0, -px_step.y), 0.0).rgb);
    let luma_s = fxaa_luma(textureSampleLevel(src, src_sampler, uv + vec2<f32>(0.0, px_step.y), 0.0).rgb);
    let luma_w = fxaa_luma(textureSampleLevel(src, src_sampler, uv + vec2<f32>(-px_step.x, 0.0), 0.0).rgb);
    let luma_e = fxaa_luma(textureSampleLevel(src, src_sampler, uv + vec2<f32>(px_step.x, 0.0), 0.0).rgb);

    let luma_min = min(luma_m, min(min(luma_n, luma_s), min(luma_w, luma_e)));
    let luma_max = max(luma_m, max(max(luma_n, luma_s), max(luma_w, luma_e)));
    let range = luma_max - luma_min;
    if (range < max(0.020, luma_max * 0.08)) {
        return rgb_m;
    }

    let luma_nw = fxaa_luma(textureSampleLevel(src, src_sampler, uv + vec2<f32>(-px_step.x, -px_step.y), 0.0).rgb);
    let luma_ne = fxaa_luma(textureSampleLevel(src, src_sampler, uv + vec2<f32>(px_step.x, -px_step.y), 0.0).rgb);
    let luma_sw = fxaa_luma(textureSampleLevel(src, src_sampler, uv + vec2<f32>(-px_step.x, px_step.y), 0.0).rgb);
    let luma_se = fxaa_luma(textureSampleLevel(src, src_sampler, uv + vec2<f32>(px_step.x, px_step.y), 0.0).rgb);

    let luma_ns = luma_n + luma_s;
    let luma_we = luma_w + luma_e;
    let luma_nw_sw = luma_nw + luma_sw;
    let luma_ne_se = luma_ne + luma_se;
    let luma_nw_ne = luma_nw + luma_ne;
    let luma_sw_se = luma_sw + luma_se;

    let edge_h = abs(luma_nw_sw - 2.0 * luma_w)
        + 2.0 * abs(luma_ns - 2.0 * luma_m)
        + abs(luma_ne_se - 2.0 * luma_e);
    let edge_v = abs(luma_nw_ne - 2.0 * luma_n)
        + 2.0 * abs(luma_we - 2.0 * luma_m)
        + abs(luma_sw_se - 2.0 * luma_s);
    let is_horiz = edge_h >= edge_v;

    let luma1 = select(luma_w, luma_n, is_horiz);
    let luma2 = select(luma_e, luma_s, is_horiz);
    let grad1 = luma1 - luma_m;
    let grad2 = luma2 - luma_m;
    let is_1_steepest = abs(grad1) >= abs(grad2);
    let grad_scaled = 0.25 * max(abs(grad1), abs(grad2));

    var step_len = select(px_step.x, px_step.y, is_horiz);
    var luma_avg = 0.5 * (luma2 + luma_m);
    if (is_1_steepest) {
        step_len = -step_len;
        luma_avg = 0.5 * (luma1 + luma_m);
    }

    var cur_uv = uv;
    if (is_horiz) {
        cur_uv.y = cur_uv.y + step_len * 0.5;
    } else {
        cur_uv.x = cur_uv.x + step_len * 0.5;
    }

    let off = select(vec2<f32>(0.0, px_step.y), vec2<f32>(px_step.x, 0.0), is_horiz);
    var uv1 = cur_uv - off;
    var uv2 = cur_uv + off;
    var end1 = fxaa_luma(textureSampleLevel(src, src_sampler, uv1, 0.0).rgb) - luma_avg;
    var end2 = fxaa_luma(textureSampleLevel(src, src_sampler, uv2, 0.0).rgb) - luma_avg;
    var done1 = abs(end1) >= grad_scaled;
    var done2 = abs(end2) >= grad_scaled;
    if (!done1) {
        uv1 = uv1 - off;
    }
    if (!done2) {
        uv2 = uv2 + off;
    }

    let steps = array<f32, 7>(1.5, 2.0, 2.0, 3.0, 4.0, 6.0, 8.0);
    for (var i = 0; i < 7; i = i + 1) {
        if (done1 && done2) {
            break;
        }
        if (!done1) {
            end1 = fxaa_luma(textureSampleLevel(src, src_sampler, uv1, 0.0).rgb) - luma_avg;
            done1 = abs(end1) >= grad_scaled;
        }
        if (!done2) {
            end2 = fxaa_luma(textureSampleLevel(src, src_sampler, uv2, 0.0).rgb) - luma_avg;
            done2 = abs(end2) >= grad_scaled;
        }
        if (!done1) {
            uv1 = uv1 - off * steps[i];
        }
        if (!done2) {
            uv2 = uv2 + off * steps[i];
        }
    }

    let dist1 = select(uv.y - uv1.y, uv.x - uv1.x, is_horiz);
    let dist2 = select(uv2.y - uv.y, uv2.x - uv.x, is_horiz);
    let is_dir1 = dist1 < dist2;
    let dist_min = min(dist1, dist2);
    let edge_len = max(dist1 + dist2, 1e-6);
    let end_luma = select(end2, end1, is_dir1);
    let good_span = (end_luma < 0.0) != (luma_m < luma_avg);
    let edge_offset = select(0.0, -dist_min / edge_len + 0.5, good_span);

    let subpix_sum = (2.0 * (luma_ns + luma_we) + luma_nw_sw + luma_ne_se) / 12.0;
    let subpix_a = clamp(abs(subpix_sum - luma_m) / max(range, 1e-5), 0.0, 1.0);
    let subpix_b = (-2.0 * subpix_a + 3.0) * subpix_a * subpix_a;
    let subpix_offset = subpix_b * subpix_b * 0.65;
    let final_offset = max(edge_offset, subpix_offset);

    var final_uv = uv;
    if (is_horiz) {
        final_uv.y = final_uv.y + final_offset * step_len;
    } else {
        final_uv.x = final_uv.x + final_offset * step_len;
    }
    return textureSampleLevel(src, src_sampler, final_uv, 0.0).rgb;
}

@fragment
fn fs(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let canvas_px = care.rect.xy + pos.xy * care.px_to_canvas;
    var c = sample_aa(canvas_px / care.canvas);
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

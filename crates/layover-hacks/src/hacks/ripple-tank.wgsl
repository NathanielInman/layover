// Ripple Tank: rings spread from a handful of drifting sources across dark
// water and cross into shifting interference bands, drawn as thin contour
// lines on the crests with a faint glow where the waves add up.
// After xscreensaver's Interference (Hannu Mallat, 1998).

const RT_SOURCES: i32 = 7;

// Where source `i` sits at time `t`. Each source keeps to its own stretch of
// the panorama and wanders well past it on slow, unequal periods, so every
// part of the canvas sees a nearby source in turn.
fn rt_source(i: i32, t: f32) -> vec2<f32> {
    let a = aspect();
    let fi = f32(i);
    let h = hash11(fi * 7.31 + 1.7 + g.seed * 13.0);
    let k = hash11(fi * 3.17 + 5.3 + g.seed * 29.0);
    let home = a * (fi + 0.5) / f32(RT_SOURCES);
    let x = home
        + 0.62 * sin(t * (0.019 + 0.013 * h) + fi * 2.1 + g.seed * TAU)
        + 0.31 * sin(t * (0.041 + 0.017 * k) + fi * 0.7);
    let y = 0.5
        + 0.34 * sin(t * (0.027 + 0.015 * k) + fi * 1.3 + g.seed * 4.0)
        + 0.12 * cos(t * (0.061 + 0.011 * h) + fi * 2.9);
    return vec2<f32>(x, y);
}

// Seven-stop night palette walked by contour level: deep teal at the outer
// crests, through frost and violet, to amber at the strongest ones.
fn rt_palette(x: f32) -> vec3<f32> {
    let c0 = vec3<f32>(0.10, 0.52, 0.62);
    let c1 = vec3<f32>(0.30, 0.74, 0.92);
    let c2 = vec3<f32>(0.56, 0.48, 0.94);
    let c3 = vec3<f32>(0.90, 0.46, 0.70);
    let c4 = vec3<f32>(0.98, 0.70, 0.36);
    let s = clamp(x, 0.0, 1.0) * 4.0;
    if (s < 1.0) {
        return mix(c0, c1, s);
    }
    if (s < 2.0) {
        return mix(c1, c2, s - 1.0);
    }
    if (s < 3.0) {
        return mix(c2, c3, s - 2.0);
    }
    return mix(c3, c4, s - 3.0);
}

// Anti-aliased line of half-width `hw` at distance `d`, both in canvas
// heights. Thinner than a pixel, it keeps its total light instead of
// vanishing, so low render scales and the wear test see the same picture.
fn rt_line(d: f32, hw: f32, aa: f32) -> f32 {
    let cov = clamp((hw + aa - d) / (2.0 * aa), 0.0, 1.0);
    return smoothstep(0.0, 1.0, cov) * min(1.0, hw / aa);
}

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let px = 1.0 / max(g.target_size.y, 1.0);
    let aa = px * 0.9;

    // Sum the circular waves and their gradient. Each source has its own
    // wavelength and speed, so the bands between them never settle, and each
    // swells and ebbs on its own slow breath so the pattern keeps changing
    // shape. Amplitude falls off softly with distance.
    var f = 0.0;
    var grad = vec2<f32>(0.0);
    var norm = 0.0;
    for (var i = 0; i < RT_SOURCES; i = i + 1) {
        let fi = f32(i);
        let h = hash11(fi * 11.7 + 0.3 + g.seed * 17.0);
        let s = rt_source(i, t);
        let d = p - s;
        let r = max(length(d), 1e-4);
        let k = 34.0 + 16.0 * h;
        let w = 1.25 + 0.55 * hash11(fi * 5.9 + 2.2 + g.seed * 7.0);
        let breath = 0.55 + 0.45 * sin(t * (0.031 + 0.019 * h) + fi * 2.4 + g.seed * 9.0);
        let amp = breath / (1.0 + r * r * 14.0);
        let u = k * r - w * t + fi * 1.9;
        f = f + amp * cos(u);
        grad = grad - (amp * k * sin(u)) * (d / r);
        norm = norm + amp * amp;
    }
    let inv = inverseSqrt(max(norm, 1e-4));
    f = f * inv;
    grad = grad * inv;
    let gl = max(length(grad), 6.0);

    // Contours on the crests only: troughs stay black. Higher levels are the
    // places where several waves arrive in step.
    let levels = array<f32, 4>(0.45, 0.95, 1.45, 1.95);
    var col = vec3<f32>(0.0);
    let drift = 0.08 * sin(t * 0.013 + g.seed * TAU);
    for (var j = 0; j < 4; j = j + 1) {
        let lv = levels[j];
        let sd = abs(f - lv) / gl;
        let fj = f32(j);
        let line = rt_line(sd, 0.0016 - 0.00018 * fj, aa);
        let tint = rt_palette(fj / 3.0 + drift);
        col = col + tint * line * (0.80 + 0.10 * fj);
    }

    // The crests carry a faint sheen and the strongest of them glow, like
    // light caught in the water where the waves pile up. Troughs stay black.
    let sheen = smoothstep(0.0, 1.1, f);
    col = col + rt_palette(0.15 + drift) * sheen * sheen * 0.07;
    let glow = smoothstep(0.9, 2.3, f);
    col = col + rt_palette(0.55 + 0.45 * glow + drift) * glow * glow * 0.32;

    return col;
}

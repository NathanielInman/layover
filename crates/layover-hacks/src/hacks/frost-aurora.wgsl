// Frost Aurora: three curtains of frost, green and purple over black
// mountains. The curtains wander, their rays run along them, and nothing
// is lit for long in one place.

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    var col = mix(vec3<f32>(0.02, 0.035, 0.06), vec3<f32>(0.005, 0.008, 0.018), p.y);

    let sp = (p + vec2<f32>(t * 0.002, 0.0)) * 70.0;
    let cell = floor(sp);
    if (hash21(cell + 3.7) > 0.985) {
        let d = length(fract(sp) - 0.5);
        col = col + vec3<f32>(0.5) * disc(d, 0.08, 0.05) * (0.5 + 0.3 * sin(t + hash21(cell) * 40.0));
    }

    var tint = array<vec3<f32>, 3>(
        vec3<f32>(0.53, 0.75, 0.82),
        vec3<f32>(0.64, 0.75, 0.55),
        vec3<f32>(0.71, 0.56, 0.68),
    );
    for (var i = 0; i < 3; i = i + 1) {
        let fi = f32(i);
        let x = p.x * 0.55 + fi * 1.7 + g.seed;
        let center = 0.5 + 0.1 * fi
            + 0.12 * sin(x * 1.3 + t * 0.14 + fi)
            + 0.07 * (fbm(vec2<f32>(x * 1.6, t * 0.06 + fi * 4.0)) - 0.5);
        let d = p.y - center;
        let curtain = smoothstep(-0.07, 0.0, d) * exp(-max(d, 0.0) * 5.5);
        let rays = 0.3 + 0.7 * fbm(vec2<f32>(p.x * 16.0 + fi * 3.0 - t * 0.4, t * 0.25 + fi));
        let breathe = 0.5 + 0.5 * sin(p.x * 2.3 + t * 0.6 + fi * 2.1);
        col = col + tint[i] * curtain * rays * breathe * 0.75;
    }

    let ridge = 0.13 + 0.07 * abs(sin(p.x * 1.9 + 0.6)) + 0.03 * abs(sin(p.x * 7.3 + 1.1)) + 0.012 * fbm(vec2<f32>(p.x * 12.0, 0.0));
    if (p.y < ridge) {
        col = vec3<f32>(0.006, 0.008, 0.012);
    }
    return col;
}

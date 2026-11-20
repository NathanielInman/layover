// Signal Lamps: red, green, amber and frost lamps out of focus, drifting
// across a yard at night. A few blink. Every lamp keeps moving.

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = aspect();
    var col = vec3<f32>(0.008, 0.01, 0.016);
    var tints = array<vec3<f32>, 4>(
        vec3<f32>(0.75, 0.38, 0.42),
        vec3<f32>(0.64, 0.75, 0.55),
        vec3<f32>(0.92, 0.8, 0.55),
        vec3<f32>(0.53, 0.75, 0.82),
    );
    for (var i = 0; i < 44; i = i + 1) {
        let fi = f32(i) + g.seed * 13.0;
        let h = hash22(vec2<f32>(fi, fi * 1.7 + 3.0));
        let v = (hash22(vec2<f32>(fi * 2.3, 9.1)) - 0.5) * vec2<f32>(0.02, 0.012);
        let v2 = v + sign(v) * vec2<f32>(0.008, 0.004);
        let pos = vec2<f32>(
            fract(h.x + t * v2.x / (a + 0.6)) * (a + 0.6) - 0.3,
            fract(h.y + t * v2.y / 1.6) * 1.6 - 0.3,
        );
        let r = 0.04 + 0.11 * hash11(fi * 5.3);
        let d = length(p - pos);
        if (d > r) {
            continue;
        }
        let tint = tints[u32(hash11(fi * 7.7) * 4.0) % 4u];
        var level = 0.16 + 0.09 * sin(t * 1.1 + fi * 3.0);
        if (hash11(fi * 1.9) > 0.85) {
            level = level * select(0.15, 1.5, sin(t * 2.6 + fi) > 0.0);
        }
        let body = smoothstep(r, r * 0.8, d);
        let rim = smoothstep(r * 0.75, r * 0.95, d) * body * 0.35;
        col = col + tint * level * (body + rim);
    }
    return col;
}

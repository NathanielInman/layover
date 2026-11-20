// Starfield: the classic flight through the stars, drawn for 32:9. Layers
// of stars rush out from a vanishing point that wanders, so even the stars
// near the middle keep moving.

fn hack(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = aspect();
    let c = vec2<f32>(a * 0.5 + a * 0.18 * sin(t * 0.031 + g.seed), 0.5 + 0.12 * sin(t * 0.023 + 1.0));
    let q = p - c;
    var col = vec3<f32>(0.0);
    for (var i = 0; i < 6; i = i + 1) {
        let fi = f32(i);
        let z = fract(fi / 6.0 + t * 0.045);
        let scale = mix(26.0, 0.9, z);
        let fade = smoothstep(0.0, 0.35, z) * (1.0 - smoothstep(0.8, 1.0, z));
        let uv = q * scale + vec2<f32>(fi * 13.1, fi * 7.7);
        let cell = floor(uv);
        let h = hash21(cell + fi * 31.0);
        if (h > 0.86) {
            let o = (hash22(cell) - 0.5) * 0.6;
            let d = length(fract(uv) - 0.5 - o);
            let size = 0.035 + 0.05 * z;
            let warm = hash11(h * 91.0);
            let tint = mix(vec3<f32>(0.75, 0.82, 0.95), vec3<f32>(0.95, 0.85, 0.7), warm);
            col = col + tint * disc(d, size, size * 0.8) * fade;
        }
    }
    return col;
}
